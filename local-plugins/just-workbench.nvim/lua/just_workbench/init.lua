local closure = require("just_workbench.closure")

local M = {}

local dependencies
local catalogs = {}
local requests = {}
local executions = {}

local function copy(value)
	return vim.deepcopy(value)
end

local function valid_string(value)
	return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
end

local function canonical_directory(path, label)
	if not valid_string(path) or path:sub(1, 1) ~= "/" then
		return nil, label .. " must be an absolute path"
	end
	local canonical = vim.uv.fs_realpath(vim.fs.normalize(path))
	local stat = canonical and vim.uv.fs_stat(canonical) or nil
	if not stat or stat.type ~= "directory" then
		return nil, label .. " must be an existing directory"
	end
	return canonical
end

local function canonical_file(path, label)
	if not valid_string(path) or path:sub(1, 1) ~= "/" then
		return nil, label .. " must be an absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local lexical = vim.uv.fs_lstat(normalized)
	if not lexical or lexical.type ~= "file" then
		return nil, label .. " must be a regular non-symlink file"
	end
	return vim.uv.fs_realpath(normalized) or normalized
end

local function normalize_context(spec)
	if type(spec) ~= "table" then
		return nil, "catalog specification must be a table"
	end
	if not valid_string(spec.runtime) then
		return nil, "runtime must be a non-empty string without NUL bytes"
	end
	local task_root, root_err = canonical_directory(spec.task_root, "task_root")
	if not task_root then
		return nil, root_err
	end
	local justfile, file_err = canonical_file(spec.justfile, "justfile")
	if not justfile then
		return nil, file_err
	end
	if not valid_string(spec.just_bin) then
		return nil, "just_bin must be a non-empty argv entry"
	end
	return { runtime = spec.runtime, task_root = task_root, justfile = justfile, just_bin = spec.just_bin }
end

local function workspace_key(context)
	return vim.json.encode({ context.runtime, context.task_root })
end

local function action_name(prefix, name)
	return prefix == "" and name or (prefix .. "::" .. name)
end

local function private_item(value)
	if value.private == true then
		return true
	end
	for _, attribute in ipairs(type(value.attributes) == "table" and value.attributes or {}) do
		if attribute == "private" or (type(attribute) == "table" and attribute.private ~= nil) then
			return true
		end
	end
	return false
end

local function normalize_parameters(parameters, action)
	parameters = parameters or {}
	if type(parameters) ~= "table" or not vim.islist(parameters) then
		return nil, "parameters are not an array: " .. action
	end
	local result = {}
	for index, parameter in ipairs(parameters) do
		if type(parameter) ~= "table" or not valid_string(parameter.name) then
			return nil, ("invalid parameter %d: %s"):format(index, action)
		end
		local kind = parameter.kind or "singular"
		if kind ~= "singular" and kind ~= "plus" and kind ~= "star" and kind ~= "variadic" then
			return nil, ("unsupported parameter kind %s: %s"):format(tostring(kind), action)
		end
		result[index] = {
			name = parameter.name,
			kind = kind,
			default = copy(parameter.default),
		}
	end
	return result
end

local function alias_target(alias)
	if valid_string(alias) then
		return alias
	end
	if type(alias) ~= "table" then
		return nil
	end
	if valid_string(alias.target) then
		return alias.target
	end
	if type(alias.target) == "table" and vim.islist(alias.target) then
		local parts = {}
		for _, part in ipairs(alias.target) do
			if not valid_string(part) then
				return nil
			end
			parts[#parts + 1] = part
		end
		return table.concat(parts, "::")
	end
	return nil
end

local function decode_dump(result)
	if not result or result.code ~= 0 then
		local stderr = result and result.stderr or ""
		local detail = valid_string(stderr) and vim.trim(stderr) or "just --dump failed"
		return nil, detail ~= "" and detail or "just --dump failed"
	end
	local ok, decoded = pcall(vim.json.decode, result.stdout or "")
	if not ok or type(decoded) ~= "table" or type(decoded.recipes) ~= "table" then
		return nil, "just --dump returned invalid JSON"
	end

	local actions = {}
	local modules = {}
	local function walk(node, prefix)
		if type(node) ~= "table" then
			return nil, "just --dump contains an invalid module"
		end
		for _, field in ipairs({ "recipes", "aliases", "modules" }) do
			if node[field] ~= nil and type(node[field]) ~= "table" then
				return nil, "just --dump contains invalid " .. field
			end
		end
		for name, recipe in pairs(node.recipes or {}) do
			if not valid_string(name) or type(recipe) ~= "table" then
				return nil, "just --dump contains an invalid recipe"
			end
			if not private_item(recipe) then
				local invocation = action_name(prefix, name)
				local parameters, parameters_err = normalize_parameters(recipe.parameters, invocation)
				if not parameters then
					return nil, parameters_err
				end
				actions[#actions + 1] = {
					kind = "recipe",
					name = invocation,
					text = invocation,
					description = type(recipe.doc) == "string" and recipe.doc or "",
					parameters = parameters,
				}
			end
		end
		for name, alias in pairs(node.aliases or {}) do
			if not valid_string(name) or private_item(type(alias) == "table" and alias or {}) then
				if not valid_string(name) then
					return nil, "just --dump contains an invalid alias"
				end
			else
				local target = alias_target(alias)
				if not target then
					return nil, "just --dump contains an invalid alias: " .. name
				end
				local invocation = action_name(prefix, name)
				actions[#actions + 1] = {
					kind = "alias",
					name = invocation,
					text = invocation,
					description = type(alias) == "table" and type(alias.doc) == "string" and alias.doc or "",
					target = target,
					parameters = {},
					module_prefix = prefix,
				}
			end
		end
		for name, child in pairs(node.modules or {}) do
			if not valid_string(name) or type(child) ~= "table" then
				return nil, "just --dump contains an invalid module"
			end
			local path = action_name(prefix, name)
			modules[#modules + 1] = {
				name = path,
				description = type(child.doc) == "string" and child.doc or "",
			}
			local walked, walk_err = walk(child, path)
			if not walked then
				return nil, walk_err
			end
		end
		return true
	end
	local walked, walk_err = walk(decoded, "")
	if not walked then
		return nil, walk_err
	end
	local by_name = {}
	for _, action in ipairs(actions) do
		by_name[action.name] = action
	end
	local function resolve_parameters(action, active)
		if action.kind == "recipe" then
			return action.parameters
		end
		active = active or {}
		if active[action] then
			return nil
		end
		active[action] = true
		local target = action.target
		if action.module_prefix ~= "" and not target:find("::", 1, true) then
			target = action_name(action.module_prefix, target)
		end
		local target_action = by_name[target]
		local parameters = target_action and resolve_parameters(target_action, active) or nil
		active[action] = nil
		return parameters
	end
	for _, action in ipairs(actions) do
		if action.kind == "alias" then
			local parameters = resolve_parameters(action)
			if parameters then
				action.parameters = copy(parameters)
			end
			action.module_prefix = nil
		end
	end
	table.sort(actions, function(left, right)
		return left.name < right.name
	end)
	table.sort(modules, function(left, right)
		return left.name < right.name
	end)
	return { actions = actions, modules = modules }
end

local function scan(context, authorize, deps)
	return closure.scan(context.justfile, {
		hash = deps.hash,
		trust = deps.trust,
		home = deps.home,
		authorize = authorize,
	})
end

local function dump_argv(context)
	return {
		context.just_bin,
		"--dump",
		"--dump-format",
		"json",
		"--justfile",
		context.justfile,
		"--working-directory",
		context.task_root,
	}
end

local function system(deps, argv, callback)
	local ok, handle_or_err = pcall(deps.system, copy(argv), { text = true }, function(result)
		deps.schedule(function()
			callback(result)
		end)
	end)
	if not ok or handle_or_err == nil or handle_or_err == false then
		return nil, tostring(ok and "could not start just" or handle_or_err)
	end
	return handle_or_err
end

local function public_catalog(record)
	return copy({
		id = record.id,
		runtime = record.context.runtime,
		task_root = record.context.task_root,
		justfile = record.context.justfile,
		fingerprint = record.closure.fingerprint,
		actions = record.actions,
		modules = record.modules,
		closure = record.closure,
	})
end

function M.setup(opts)
	opts = opts or {}
	if type(opts.system) ~= "function" then
		error("just_workbench.setup requires system(argv, opts, callback)")
	end
	if type(opts.trust) ~= "function" then
		error("just_workbench.setup requires trust(path, contents, digest)")
	end
	if opts.hash ~= nil and type(opts.hash) ~= "function" then
		error("just_workbench.setup hash must be a function")
	end
	if opts.now ~= nil and type(opts.now) ~= "function" then
		error("just_workbench.setup now must be a function")
	end
	if opts.schedule ~= nil and type(opts.schedule) ~= "function" then
		error("just_workbench.setup schedule must be a function")
	end
	if type(opts.terminal) ~= "table" then
		error("just_workbench.setup requires terminal callbacks")
	end
	for _, name in ipairs({ "status", "open", "focus", "replace", "lines" }) do
		if type(opts.terminal[name]) ~= "function" then
			error("just_workbench.setup terminal." .. name .. " must be a function")
		end
	end
	dependencies = {
		system = opts.system,
		trust = opts.trust,
		hash = opts.hash or vim.fn.sha256,
		home = opts.home,
		now = opts.now or os.time,
		schedule = opts.schedule or vim.schedule,
		terminal = opts.terminal,
	}
	return M
end

function M.catalog(spec, callback)
	if not dependencies then
		return nil, "just_workbench.setup must be called first"
	end
	if type(callback) ~= "function" then
		return nil, "catalog callback must be a function"
	end
	local context, context_err = normalize_context(spec)
	if not context then
		return nil, context_err
	end
	local deps = dependencies
	local trusted_closure, closure_err = scan(context, true, deps)
	if not trusted_closure then
		return nil, closure_err
	end
	local key = workspace_key(context)
	requests[key] = (requests[key] or 0) + 1
	local request = requests[key]
	return system(deps, dump_argv(context), function(result)
		if requests[key] ~= request then
			callback(nil, "catalog request was superseded")
			return
		end
		local current_closure, current_err = scan(context, false, deps)
		if not current_closure or not closure.equal(trusted_closure, current_closure) then
			callback(nil, current_err or "justfile closure changed while it was cataloged")
			return
		end
		local decoded, decode_err = decode_dump(result)
		if not decoded then
			callback(nil, decode_err)
			return
		end
		local id =
			deps.hash(table.concat({ key, context.justfile, trusted_closure.fingerprint, tostring(request) }, "\0"))
		local record = {
			id = id,
			context = context,
			closure = trusted_closure,
			actions = decoded.actions,
			modules = decoded.modules,
			dependencies = deps,
		}
		catalogs[id] = record
		callback(public_catalog(record))
	end)
end

local function record_for(catalog)
	if type(catalog) ~= "table" or not valid_string(catalog.id) then
		return nil, "catalog must be returned by just_workbench.catalog"
	end
	local record = catalogs[catalog.id]
	if not record then
		return nil, "catalog is unknown or expired"
	end
	return record
end

local function revalidate(record)
	local current, err = scan(record.context, false, record.dependencies)
	if not current then
		return nil, err
	end
	if not closure.equal(record.closure, current) then
		return nil, "justfile closure changed; refresh the recipe catalog before execution"
	end
	return true
end

local function find_action(record, name)
	for _, action in ipairs(record.actions) do
		if action.name == name then
			return action
		end
	end
	return nil
end

local function normalize_values(values)
	if type(values) ~= "table" or not vim.islist(values) then
		return nil, "recipe values must be an array"
	end
	local result = {}
	for index, value in ipairs(values) do
		if type(value) ~= "string" or value:find("\0", 1, true) then
			return nil, ("recipe value %d must be a string without NUL bytes"):format(index)
		end
		result[index] = value
	end
	return result
end

local function terminal_spec(record, action, values)
	local context = record.context
	local deps = record.dependencies
	local argv = {
		context.just_bin,
		"--justfile",
		context.justfile,
		"--working-directory",
		context.task_root,
		action.name,
	}
	vim.list_extend(argv, values)
	local key = "just-workbench:" .. deps.hash(workspace_key(context))
	return {
		key = key,
		launch = { argv = argv, cwd = context.task_root, env = {} },
		policy = { dispose_on_success = false, dispose_on_stop = false },
		view = { layout = "bottom", title = "just " .. action.name },
		metadata = {
			product = "just-workbench.nvim",
			runtime = context.runtime,
			task_root = context.task_root,
			recipe = action.name,
		},
	}
end

local function conflict(key, record, action)
	return {
		kind = "conflict",
		key = key,
		runtime = record.context.runtime,
		task_root = record.context.task_root,
		recipe = action.name,
		choices = { "focus", "replace", "cancel" },
	}
end

function M.run(catalog, name, values, opts)
	if not dependencies then
		return nil, "just_workbench.setup must be called first"
	end
	local record, record_err = record_for(catalog)
	if not record then
		return nil, record_err
	end
	if not valid_string(name) then
		return nil, "recipe name must be a non-empty string"
	end
	local action = find_action(record, name)
	if not action then
		return nil, "unknown recipe or alias: " .. name
	end
	local normalized_values, values_err = normalize_values(values or {})
	if not normalized_values then
		return nil, values_err
	end
	local spec = terminal_spec(record, action, normalized_values)
	local deps = record.dependencies
	local key = spec.key
	local terminal_status = deps.terminal.status(key) or {}
	local existing = terminal_status.exists == true
		or terminal_status.state == "starting"
		or terminal_status.state == "running"
		or terminal_status.state == "exited-retained"
	local decision = opts and opts.decision or nil
	if existing then
		if decision == nil then
			return nil, conflict(key, record, action)
		elseif decision == "cancel" then
			return { outcome = "cancelled", key = key }
		elseif decision == "focus" then
			local focused, focus_err = deps.terminal.focus(key)
			return focused and { outcome = "focused", key = key } or nil, focus_err
		elseif decision ~= "replace" then
			return nil, "decision must be focus, replace, or cancel"
		end
	elseif decision ~= nil and decision ~= "replace" then
		return nil, "there is no existing execution to " .. tostring(decision)
	end
	local valid, valid_err = revalidate(record)
	if not valid then
		return nil, valid_err
	end

	local launched, launch_err
	if existing then
		launched, launch_err = deps.terminal.replace(spec)
	else
		launched, launch_err = deps.terminal.open(spec)
	end
	if not launched then
		return nil, launch_err
	end
	executions[workspace_key(record.context)] = {
		key = key,
		context = copy(record.context),
		recipe = action.name,
		argv = copy(spec.launch.argv),
		started_at = deps.now(),
		spec = copy(spec),
		dependencies = deps,
	}
	return { outcome = existing and "replaced" or "started", key = key, spec = copy(spec) }
end

function M.transcript(identity)
	if not dependencies then
		return nil, "just_workbench.setup must be called first"
	end
	if type(identity) ~= "table" or not valid_string(identity.runtime) then
		return nil, "transcript identity requires runtime and task_root"
	end
	local root, root_err = canonical_directory(identity.task_root, "task_root")
	if not root then
		return nil, root_err
	end
	local execution = executions[vim.json.encode({ identity.runtime, root })]
	if not execution then
		return nil, "no Just execution exists for this runtime and task root"
	end
	local key = execution.key
	local lines, lines_err = execution.dependencies.terminal.lines(key)
	if not lines then
		return nil, lines_err
	end
	return copy({
		key = key,
		runtime = identity.runtime,
		task_root = root,
		recipe = execution.recipe,
		argv = execution.argv,
		started_at = execution.started_at,
		status = execution.dependencies.terminal.status(key),
		lines = lines,
	})
end

function M.format(catalog, mode, callback)
	local record, record_err = record_for(catalog)
	if not record then
		return nil, record_err
	end
	if mode ~= "check" and mode ~= "dump" then
		return nil, "format mode must be check or dump"
	end
	if type(callback) ~= "function" then
		return nil, "format callback must be a function"
	end
	local valid, valid_err = revalidate(record)
	if not valid then
		return nil, valid_err
	end
	local argv = {
		record.context.just_bin,
		"--justfile",
		record.context.justfile,
		"--working-directory",
		record.context.task_root,
		mode == "check" and "--fmt" or "--dump",
	}
	if mode == "check" then
		argv[#argv + 1] = "--check"
	end
	return system(record.dependencies, argv, function(result)
		local current, current_err = revalidate(record)
		if not current then
			callback(nil, current_err)
			return
		end
		callback(copy(result))
	end)
end

function M.status(identity)
	if not dependencies then
		return nil, "just_workbench.setup must be called first"
	end
	if type(identity) ~= "table" or not valid_string(identity.runtime) then
		return nil, "status identity requires runtime and task_root"
	end
	local root, err = canonical_directory(identity.task_root, "task_root")
	if not root then
		return nil, err
	end
	local workspace = vim.json.encode({ identity.runtime, root })
	local execution = executions[workspace]
	local deps = execution and execution.dependencies or dependencies
	local key = execution and execution.key or ("just-workbench:" .. deps.hash(workspace))
	return copy(deps.terminal.status(key) or { state = "disposed", exists = false })
end

function M._reset()
	catalogs = {}
	requests = {}
	executions = {}
end

M._decode_dump = decode_dump
M._closure = closure

return M
