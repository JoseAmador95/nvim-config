-- Host adapter for just-workbench.nvim. Commands, prompts, picker presentation,
-- terminal UI, repository resolution, and quickfix integration remain here.
local M = {}
local deferred = require("config.deferred")

local workbench
local DEFAULT_POLICY = {
	binary = "just",
	root_mode = "repo",
	justfile_names = { "justfile", "Justfile", ".justfile" },
	conflict = "prompt",
}
local last_identity
local configured = false

local function policy()
	return require("config.local_config").plugin("just_workbench", DEFAULT_POLICY)
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Just" })
end

local function find_justfile(root, names)
	for _, name in ipairs(names or policy().justfile_names) do
		local path = vim.fs.joinpath(root, name)
		local stat = vim.uv.fs_lstat(path)
		if stat and stat.type == "file" then
			return path
		end
	end
	return nil
end

local function just_binary(options)
	local path = vim.fn.exepath(options.binary)
	if path == "" and options.binary:sub(1, 1) == "/" and vim.fn.executable(options.binary) == 1 then
		path = options.binary
	end
	return path ~= "" and vim.fs.normalize(path) or nil
end

local function contained(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function nearest_justfile(root, names)
	local current = vim.api.nvim_buf_get_name(0)
	if current == "" then
		current = vim.uv.cwd()
	end
	current = vim.uv.fs_realpath(current) or vim.fs.normalize(vim.fn.fnamemodify(current, ":p"))
	local stat = vim.uv.fs_lstat(current)
	local directory = stat and stat.type == "directory" and current or vim.fs.dirname(current)
	if not contained(root, directory) then
		directory = root
	end
	while contained(root, directory) do
		local justfile = find_justfile(directory, names)
		if justfile then
			return directory, justfile
		end
		if directory == root then
			break
		end
		directory = vim.fs.dirname(directory)
	end
	return nil
end

local function context()
	local options = policy()
	local binary = just_binary(options)
	if not binary then
		return nil, ("host %s was not found in PATH (it is never installed automatically)"):format(options.binary)
	end
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		return nil, root_err
	end
	local task_root = root
	local justfile
	if options.root_mode == "nearest" then
		task_root, justfile = nearest_justfile(root, options.justfile_names)
	else
		justfile = find_justfile(root, options.justfile_names)
	end
	if not justfile then
		return nil,
			options.root_mode == "nearest" and "no justfile exists between the current buffer and repository root"
				or "no justfile exists at the repository root"
	end
	return { runtime = "host", task_root = task_root, justfile = justfile, just_bin = binary }
end

local function terminal_adapter()
	return {
		status = function(key)
			return require("config.terminal").status(key)
		end,
		open = function(spec)
			return require("config.terminal").open(spec)
		end,
		focus = function(spec)
			return require("config.terminal").focus(spec)
		end,
		replace = function(spec)
			return require("config.terminal").restart(spec)
		end,
		lines = function(key)
			return require("config.terminal").lines(key)
		end,
		stop = function(key)
			return require("config.terminal").stop(key)
		end,
	}
end

local function supports_one(binary)
	local ok, process = pcall(vim.system, { binary, "--help" }, { text = true })
	if not ok then
		error(process)
	end
	local result = process:wait()
	if result.code ~= 0 then
		error(vim.trim(result.stderr or "just --help failed"))
	end
	local help = (result.stdout or "") .. "\n" .. (result.stderr or "")
	return help:find("--one", 1, true) ~= nil
end

local function load_workbench()
	if workbench then
		return workbench
	end
	local ok, result = deferred.try("just_workbench")
	if not ok then
		return nil, result
	end
	workbench = result
	return workbench
end

local function configure(overrides)
	if configured then
		return workbench
	end
	local core, load_err = load_workbench()
	if not core then
		return nil, load_err
	end
	overrides = overrides or {}
	local ok, setup_result, setup_err = pcall(core.setup, {
		system = overrides.system or vim.system,
		trust = overrides.trust or function(path, contents)
			local approved = vim.secure.read(path)
			return approved == contents, "source was not trusted: " .. path
		end,
		hash = overrides.hash or vim.fn.sha256,
		home = overrides.home or vim.env.HOME,
		now = overrides.now,
		schedule = overrides.schedule or vim.schedule,
		supports_one = overrides.supports_one or supports_one,
		terminal = overrides.terminal or terminal_adapter(),
	})
	if not ok then
		return nil, setup_result
	end
	if not setup_result then
		return nil, setup_err or "setup failed"
	end
	configured = true
	return core
end

local function execute(catalog, action, values, decision)
	local result, err = workbench.run(catalog, action.name, values, decision and { decision = decision } or nil)
	if result then
		if result.outcome == "started" or result.outcome == "replaced" then
			last_identity = { runtime = catalog.runtime, task_root = catalog.task_root }
		end
		return
	end
	if type(err) ~= "table" or err.kind ~= "conflict" then
		notify("Could not run recipe: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	local configured_decision = policy().conflict
	if decision == nil and configured_decision ~= "prompt" then
		execute(catalog, action, values, configured_decision)
		return
	end
	local choices = {
		{ value = "focus", label = "Focus existing run" },
		{ value = "replace", label = "Replace existing run" },
		{ value = "cancel", label = "Cancel" },
	}
	vim.ui.select(choices, {
		prompt = ("Just is already active for %s"):format(catalog.task_root),
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		local selected = choice and choice.value or "cancel"
		execute(catalog, action, values, selected)
	end)
end

local function prompt_parameters(catalog, action, index, values)
	index = index or 1
	values = values or {}
	local parameter = action.parameters[index]
	if not parameter then
		execute(catalog, action, values)
		return
	end
	local variadic = parameter.kind == "plus" or parameter.kind == "star" or parameter.kind == "variadic"
	local default = type(parameter.default) == "string" and parameter.default or ""
	vim.ui.input({
		prompt = ("just %s: %s%s: "):format(action.name, parameter.name, variadic and " (literal value)" or ""),
		default = default,
	}, function(value)
		if value == nil then
			return
		end
		local optional = parameter.default ~= nil or parameter.kind == "star"
		if value == "" and not optional then
			notify("A value is required for " .. parameter.name, vim.log.levels.WARN)
			return
		end
		if value == "" then
			prompt_parameters(catalog, action, index + 1, values)
		elseif variadic then
			values[#values + 1] = value
			prompt_parameters(catalog, action, index + 1, values)
		else
			values[#values + 1] = value
			prompt_parameters(catalog, action, index + 1, values)
		end
	end)
end

local function choose(catalog, requested)
	if requested and requested ~= "" then
		for _, action in ipairs(catalog.actions) do
			if action.name == requested then
				prompt_parameters(catalog, action)
				return
			end
		end
		notify("Unknown recipe or alias: " .. requested, vim.log.levels.ERROR)
		return
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		notify("Snacks picker is unavailable", vim.log.levels.ERROR)
		return
	end
	snacks.picker.pick({
		source = "just_recipes",
		title = "Just recipes",
		items = catalog.actions,
		format = "text",
		preview = false,
		layout = { preset = "select" },
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.schedule(function()
					prompt_parameters(catalog, item)
				end)
			end
		end,
	})
end

function M.run(requested, overrides)
	local ctx, ctx_err = context()
	if not ctx then
		notify(ctx_err, vim.log.levels.ERROR)
		return
	end
	local core, setup_err = configure(overrides)
	if not core then
		notify("Could not initialize Just workbench: " .. tostring(setup_err), vim.log.levels.ERROR)
		return
	end
	local handle, catalog_err = core.catalog(ctx, function(catalog, err)
		vim.schedule(function()
			if not catalog then
				notify("Could not list recipes: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			choose(catalog, requested)
		end)
	end)
	if not handle then
		notify("Could not list recipes: " .. tostring(catalog_err), vim.log.levels.ERROR)
	end
end

local function strip_ansi(line)
	return line:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

function M.parse_locations(root, lines)
	local items = {}
	local seen = {}
	for _, raw in ipairs(lines or {}) do
		if #items >= 2000 then
			break
		end
		local line = strip_ansi(raw)
		if #line <= 8192 and not line:find("[%z\1-\8\11\12\14-\31]") then
			local file, lnum, col, message = line:match("^([^:]+):(%d+):(%d+):%s*(.+)$")
			if not file then
				file, lnum, message = line:match("^([^:]+):(%d+):%s*(.+)$")
			end
			if file then
				local relative, absolute = require("config.repo").relative_existing(root, file)
				if not relative then
					relative, absolute = require("config.repo").relative_existing(root, vim.fs.joinpath(root, file))
				end
				if not relative then
					absolute = nil
				end
				local key = absolute and table.concat({ absolute, lnum, col or "1", message }, "\0") or nil
				if key and not seen[key] then
					seen[key] = true
					items[#items + 1] = {
						filename = absolute,
						lnum = tonumber(lnum),
						col = tonumber(col) or 1,
						text = message,
						type = "E",
					}
				end
			end
		end
	end
	return items
end

function M.import_last()
	if not last_identity then
		notify("No Just run exists in this Neovim instance", vim.log.levels.WARN)
		return
	end
	local transcript, err = workbench.transcript(last_identity)
	if not transcript then
		notify(err, vim.log.levels.ERROR)
		return
	end
	local items = M.parse_locations(last_identity.task_root, transcript.lines)
	if #items == 0 then
		notify("No conservative file:line[:col] locations found", vim.log.levels.WARN)
		return
	end
	vim.fn.setqflist({}, " ", { title = "Just output", items = items })
	vim.cmd("Trouble qflist open")
end

function M.show_transcript()
	if not last_identity then
		notify("No Just run exists in this Neovim instance", vim.log.levels.WARN)
		return
	end
	local transcript, err = workbench.transcript(last_identity)
	if not transcript then
		notify(err, vim.log.levels.ERROR)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_name(buf, "just://" .. transcript.recipe)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, transcript.lines)
	vim.bo[buf].modifiable = false
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, buf)
end

function M.stop()
	if not last_identity then
		notify("No Just run exists in this Neovim instance", vim.log.levels.WARN)
		return false
	end
	local stopped, err = workbench.stop(last_identity)
	if not stopped then
		notify("Could not stop Just run: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	notify("Just run stopped")
	return true
end

function M.setup()
	vim.api.nvim_create_user_command("JustRun", function(opts)
		M.run(opts.args)
	end, { nargs = "?", desc = "Choose and run a trusted Just recipe", force = true })
	vim.api.nvim_create_user_command("JustImportLast", M.import_last, {
		nargs = 0,
		desc = "Import conservative locations from the last Just terminal",
		force = true,
	})
	vim.api.nvim_create_user_command("JustRefresh", function()
		M.run()
	end, { nargs = 0, desc = "Refresh the trusted Just recipe catalog", force = true })
	vim.api.nvim_create_user_command("JustTranscript", M.show_transcript, {
		nargs = 0,
		desc = "Show the last Just run transcript",
		force = true,
	})
	vim.api.nvim_create_user_command("JustStop", M.stop, {
		nargs = 0,
		desc = "Stop the active Just run for this repository",
		force = true,
	})
	return true
end

function M._decode_dump(...)
	local core, err = load_workbench()
	if not core then
		error("could not load Just workbench: " .. tostring(err), 2)
	end
	return core._decode_dump(...)
end

M._find_justfile = find_justfile
M._workbench = setmetatable({}, {
	__index = function(_, key)
		local core, err = load_workbench()
		if not core then
			error("could not load Just workbench: " .. tostring(err), 2)
		end
		return core[key]
	end,
})
M._configure = configure

return M
