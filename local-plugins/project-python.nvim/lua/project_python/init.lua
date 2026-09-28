local M = {}

local uv = vim.uv
local configured = {}
local is_configured = false
local selected = {}
local snapshots = {}
local generations = {}

local DEFAULT_REPL = {
	readiness_timeout_ms = 5000,
	poll_interval_ms = 50,
}

local SETUP_KEYS = {
	environment = true,
	event = true,
	explicit = true,
	fallback = true,
	on_change = true,
	repl = true,
	root_markers = true,
	terminal = true,
	test_runner = true,
}

local TERMINAL_KEYS = {
	focus = true,
	open = true,
	restart = true,
	send = true,
	status = true,
	toggle = true,
}

local DEFAULT_MARKERS = {
	"ty.toml",
	"pyrightconfig.json",
	"pyproject.toml",
	"setup.py",
	"setup.cfg",
	"requirements.txt",
	"Pipfile",
}

local function public_defaults()
	return {
		repl = vim.deepcopy(DEFAULT_REPL),
		root_markers = vim.deepcopy(DEFAULT_MARKERS),
		test_runner = "pytest",
	}
end

local function copy(value)
	return vim.deepcopy(value)
end

local function reject_unknown(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key: " .. tostring(key)
		end
	end
	return true
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, label .. " must be a positive integer"
	end
	return value
end

local function emit(kind, details)
	if type(configured.event) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(configured.event, event)
end

local function lexical(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then
		return nil
	end
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function canonical(path)
	local value = lexical(path)
	return value and (uv.fs_realpath(value) or value) or nil
end

local function executable(path)
	local value = lexical(path)
	local stat = value and uv.fs_stat(value) or nil
	return stat and stat.type == "file" and uv.fs_access(value, "X") and value or nil
end

local function contained(root, path)
	root = canonical(root)
	path = lexical(path)
	return root ~= nil and path ~= nil and (path == root or vim.fs.relpath(root, path) ~= nil)
end

local function environment_python(path)
	local environment = lexical(path)
	if not environment then
		return nil
	end
	for _, relative in ipairs({ "bin/python", "bin/python3", "Scripts/python.exe", "python.exe" }) do
		local path_value = executable(vim.fs.joinpath(environment, relative))
		if path_value then
			return path_value
		end
	end
	return nil
end

local function environment()
	if type(configured.environment) == "function" then
		return copy(configured.environment())
	end
	return vim.env
end

local function absolute_from(root, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	path = path:gsub("%${workspaceFolder}", root)
	if vim.fs.abspath(path) ~= vim.fs.normalize(path) then
		path = vim.fs.joinpath(root, path)
	end
	return lexical(path)
end

local function explicit_value(value)
	if type(value) ~= "table" then
		return value
	end
	if type(value.python) == "table" then
		return value.python
	end
	return value
end

local function explicit_candidate(root, raw)
	local value = explicit_value(raw)
	if type(value) == "string" and value ~= "" then
		local path = absolute_from(root, value)
		local info = path and uv.fs_stat(path) or nil
		local python = executable(path)
		if not python and info and info.type == "directory" then
			python = environment_python(path)
		end
		return true, python, path
	end
	if type(value) ~= "table" then
		return false
	end
	local python_path = type(value.defaultInterpreterPath) == "string" and value.defaultInterpreterPath
		or type(value.pythonPath) == "string" and value.pythonPath
		or nil
	local venv_path = type(value.venvPath) == "string" and value.venvPath or nil
	local venv = type(value.venv) == "string" and value.venv or nil
	if python_path and python_path ~= "" then
		local path = absolute_from(root, python_path)
		return true, executable(path), path
	end
	if (venv_path and venv_path ~= "") or (venv and venv ~= "") then
		if not venv or venv == "" then
			return true, nil, venv_path and absolute_from(root, venv_path) or nil
		end
		local base = venv_path and venv_path ~= "" and absolute_from(root, venv_path) or root
		local environment_path = base and vim.fs.joinpath(base, venv) or nil
		return true, environment_path and environment_python(environment_path) or nil, environment_path
	end
	return false
end

local function explicit_for(root, override)
	if override ~= nil then
		return override
	end
	if type(configured.explicit) == "function" then
		return configured.explicit(root)
	end
	return nil
end

local function automatic(root)
	local values = environment()
	local uv_environment = values.UV_PROJECT_ENVIRONMENT
	if type(uv_environment) == "string" and uv_environment ~= "" then
		local path = absolute_from(root, uv_environment)
		if contained(root, path) then
			local python = environment_python(path)
			if python then
				return "uv-project-environment", python
			end
		end
	end

	for _, relative in ipairs({ ".venv", ".pixi/envs/default", "venv", "env", ".conda" }) do
		local python = environment_python(vim.fs.joinpath(root, relative))
		if python then
			return "local:" .. relative, python
		end
	end

	for _, name in ipairs({ "VIRTUAL_ENV", "CONDA_PREFIX" }) do
		local path = values[name]
		if type(path) == "string" and path ~= "" and contained(root, path) then
			local python = environment_python(path)
			if python then
				return "environment:" .. name, python
			end
		end
	end

	local fallback = type(configured.fallback) == "function" and configured.fallback(root) or nil
	fallback = executable(fallback)
	if fallback then
		return "fallback", fallback
	end
	return "none", nil
end

local function public_snapshot(snapshot)
	local result = copy(snapshot)
	result._fingerprint = nil
	return result
end

local function ephemeral(root, source, validity, interpreter)
	return {
		generation = generations[root] or 0,
		source = source,
		validity = validity,
		value = { root = root, interpreter = interpreter },
	}
end

local function publish(root, source, validity, interpreter)
	local value = { root = root, interpreter = interpreter }
	local fingerprint = vim.json.encode({ source = source, validity = validity, value = value })
	local previous = snapshots[root]
	if not previous or previous._fingerprint ~= fingerprint then
		generations[root] = (generations[root] or 0) + 1
		previous = {
			generation = generations[root],
			source = source,
			validity = validity,
			value = value,
			_fingerprint = fingerprint,
		}
		snapshots[root] = previous
		local public = public_snapshot(previous)
		emit("status", { root = root, status = public })
	end
	return public_snapshot(previous)
end

local function nearest_marker(start)
	local found = vim.fs.find(configured.root_markers or DEFAULT_MARKERS, {
		path = start,
		upward = true,
		limit = 1,
	})[1]
	return found and canonical(vim.fs.dirname(found)) or nil
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local valid, setup_err = reject_unknown(opts, SETUP_KEYS, "project_python.setup options")
	if not valid then
		error(setup_err)
	end
	for _, name in ipairs({ "environment", "event", "explicit", "fallback", "on_change" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("project_python.setup " .. name .. " must be a function")
		end
	end
	local markers = opts.root_markers
	if markers == nil then
		markers = DEFAULT_MARKERS
	end
	if type(markers) ~= "table" or not vim.islist(markers) then
		error("project_python.setup root_markers must be an array")
	end
	for index, marker in ipairs(markers) do
		if type(marker) ~= "string" or marker == "" or marker:find("%z") then
			error(("project_python.setup root_markers[%d] is invalid"):format(index))
		end
	end
	local runner = opts.test_runner
	if runner == nil then
		runner = "pytest"
	end
	if runner ~= "pytest" and runner ~= "unittest" then
		error("project_python.setup test_runner must be pytest or unittest")
	end
	local repl = opts.repl
	if repl == nil then
		repl = {}
	end
	valid, setup_err = reject_unknown(repl, {
		readiness_timeout_ms = true,
		poll_interval_ms = true,
	}, "project_python.setup repl")
	if not valid then
		error(setup_err)
	end
	local readiness_value = repl.readiness_timeout_ms
	if readiness_value == nil then
		readiness_value = DEFAULT_REPL.readiness_timeout_ms
	end
	local readiness_timeout_ms, timeout_err = positive_integer(readiness_value, "repl.readiness_timeout_ms")
	if not readiness_timeout_ms then
		error(timeout_err)
	end
	local poll_value = repl.poll_interval_ms
	if poll_value == nil then
		poll_value = DEFAULT_REPL.poll_interval_ms
	end
	local poll_interval_ms, interval_err = positive_integer(poll_value, "repl.poll_interval_ms")
	if not poll_interval_ms then
		error(interval_err)
	end
	if poll_interval_ms > readiness_timeout_ms then
		error("repl.poll_interval_ms must not exceed repl.readiness_timeout_ms")
	end
	if opts.terminal ~= nil then
		valid, setup_err = reject_unknown(opts.terminal, TERMINAL_KEYS, "project_python.setup terminal")
		if not valid then
			error(setup_err)
		end
		for name in pairs(TERMINAL_KEYS) do
			if type(opts.terminal[name]) ~= "function" then
				error("project_python.setup terminal." .. name .. " must be a function")
			end
		end
	end
	if is_configured then
		M.teardown()
	end
	configured = {
		environment = opts.environment,
		event = opts.event,
		explicit = opts.explicit,
		fallback = opts.fallback,
		on_change = opts.on_change,
		repl = {
			readiness_timeout_ms = readiness_timeout_ms,
			poll_interval_ms = poll_interval_ms,
		},
		root_markers = copy(markers),
		terminal = opts.terminal and copy(opts.terminal) or nil,
		test_runner = runner,
	}
	selected = {}
	snapshots = {}
	generations = {}
	is_configured = true
	emit("setup", { config = M.effective_config() })
	return M
end

function M.effective_config()
	if not is_configured then
		return public_defaults()
	end
	return copy({
		repl = configured.repl,
		root_markers = configured.root_markers,
		test_runner = configured.test_runner,
	})
end

function M.teardown()
	if not is_configured then
		return true
	end
	emit("teardown", {})
	configured = {}
	selected = {}
	snapshots = {}
	generations = {}
	is_configured = false
	return true
end

function M.resolve_root(input)
	input = type(input) == "table" and input or { start = input }
	local start = lexical(input.start or uv.cwd())
	if not start then
		return nil
	end
	local stat = uv.fs_stat(start)
	if stat and stat.type ~= "directory" then
		start = vim.fs.dirname(start)
	end
	local attached = canonical(input.attached_root)
	if attached and contained(attached, start) then
		return attached
	end
	local repo = canonical(input.repo_root)
	local marker = nearest_marker(start)
	if marker and (not repo or contained(repo, marker)) then
		return marker
	end
	return repo or marker or canonical(start)
end

local function resolve_snapshot(root, raw_explicit, publish_result)
	local present, explicit = explicit_candidate(root, raw_explicit)
	if present then
		local validity = explicit and "valid" or "invalid"
		return publish_result and publish(root, "explicit", validity, explicit)
			or ephemeral(root, "explicit", validity, explicit)
	end
	local manual = selected[root]
	if manual then
		local valid = executable(manual)
		if valid then
			if publish_result then
				selected[root] = valid
			end
			return publish_result and publish(root, "manual", "valid", valid)
				or ephemeral(root, "manual", "valid", valid)
		end
		if publish_result then
			selected[root] = nil
		end
	end
	local source, python = automatic(root)
	local validity = python and "valid" or "invalid"
	return publish_result and publish(root, source, validity, python) or ephemeral(root, source, validity, python)
end

function M.snapshot(root, options)
	options = options or {}
	local caller_explicit = options.explicit ~= nil
	if not caller_explicit and snapshots[root] then
		return public_snapshot(snapshots[root])
	end
	root = canonical(root)
	if not root then
		return { generation = 0, source = "none", validity = "invalid", value = { root = nil, interpreter = nil } }
	end
	if not caller_explicit and snapshots[root] then
		return public_snapshot(snapshots[root])
	end
	return resolve_snapshot(root, explicit_for(root, options.explicit), not caller_explicit)
end

-- Re-evaluate explicit input and publish the effective root snapshot. Unlike
-- snapshot(root, { explicit = ... }), this is a synchronization boundary for
-- host adapters whose trusted project settings may have changed.
function M.sync(root, explicit)
	root = canonical(root)
	if not root then
		return nil, "project root is invalid"
	end
	return resolve_snapshot(root, explicit_for(root, explicit), true)
end

function M.resolve(input, options)
	local root = M.resolve_root(input)
	return M.snapshot(root, options)
end

function M.select(root, path)
	root = canonical(root)
	local python = root and executable(path) or nil
	if not root or not python then
		return nil, "manual interpreter is not executable"
	end
	selected[root] = python
	snapshots[root] = nil
	local result = M.snapshot(root)
	if type(configured.on_change) == "function" then
		configured.on_change(copy(result))
	end
	emit("changed", { root = root, status = result })
	return result
end

function M.clear(root)
	root = canonical(root)
	if not root then
		return nil, "project root is invalid"
	end
	selected[root] = nil
	snapshots[root] = nil
	local result = M.snapshot(root)
	if type(configured.on_change) == "function" then
		configured.on_change(copy(result))
	end
	emit("changed", { root = root, status = result })
	return result
end

function M.refresh(root)
	root = canonical(root)
	if not root then
		return nil, "project root is invalid"
	end
	snapshots[root] = nil
	local result = M.snapshot(root)
	if type(configured.on_change) == "function" then
		configured.on_change(copy(result))
	end
	emit("changed", { root = root, status = result })
	return result
end

function M.neotest_python(root)
	local snapshot = M.snapshot(root)
	return snapshot.validity == "valid" and { snapshot.value.interpreter } or nil
end

function M.neotest_runner()
	return configured.test_runner or "pytest"
end

local function diagnostic_candidate(result, source, path)
	local interpreter = executable(path)
	result[#result + 1] = {
		source = source,
		path = path,
		interpreter = interpreter,
		validity = interpreter and "valid" or "invalid",
	}
end

function M.diagnostics(root, options)
	root = canonical(root)
	if not root then
		return { root = nil, candidates = {} }
	end
	local candidates = {}
	local present, explicit, attempted = explicit_candidate(root, explicit_for(root, options and options.explicit))
	if present then
		candidates[#candidates + 1] = {
			source = "explicit",
			path = attempted,
			interpreter = explicit,
			validity = explicit and "valid" or "invalid",
		}
	end
	if selected[root] then
		diagnostic_candidate(candidates, "manual", selected[root])
	end
	local values = environment()
	local uv_environment = values.UV_PROJECT_ENVIRONMENT
	if type(uv_environment) == "string" and uv_environment ~= "" then
		local path = absolute_from(root, uv_environment)
		local python = path and contained(root, path) and environment_python(path) or nil
		candidates[#candidates + 1] = {
			source = "uv-project-environment",
			path = path,
			interpreter = python,
			validity = python and "valid" or "invalid",
		}
	end
	for _, relative in ipairs({ ".venv", ".pixi/envs/default", "venv", "env", ".conda" }) do
		local path = vim.fs.joinpath(root, relative)
		local python = environment_python(path)
		candidates[#candidates + 1] = {
			source = "local:" .. relative,
			path = path,
			interpreter = python,
			validity = python and "valid" or "missing",
		}
	end
	for _, name in ipairs({ "VIRTUAL_ENV", "CONDA_PREFIX" }) do
		local path = values[name]
		if type(path) == "string" and path ~= "" then
			local python = contained(root, path) and environment_python(path) or nil
			candidates[#candidates + 1] = {
				source = "environment:" .. name,
				path = lexical(path),
				interpreter = python,
				validity = python and "valid" or "invalid",
			}
		end
	end
	local fallback = type(configured.fallback) == "function" and configured.fallback(root) or nil
	if fallback then
		diagnostic_candidate(candidates, "fallback", fallback)
	end
	return copy({ root = root, candidates = candidates })
end

function M.status(root)
	if root == nil then
		local public_snapshots = copy(snapshots)
		for _, snapshot in pairs(public_snapshots) do
			snapshot._fingerprint = nil
		end
		return copy({
			configured = is_configured,
			generations = generations,
			selected = selected,
			snapshots = public_snapshots,
		})
	end
	root = canonical(root)
	local snapshot = root and snapshots[root] or nil
	if snapshot then
		snapshot = copy(snapshot)
		snapshot._fingerprint = nil
	end
	return copy({
		configured = is_configured,
		root = root,
		selected = root and selected[root] or nil,
		snapshot = snapshot,
	})
end

function M.apply_dap(config, root)
	if type(config) ~= "table" or config.type ~= "python" then
		return copy(config)
	end
	local resolved = copy(config)
	local explicit = type(config.pythonPath) == "string" and config.pythonPath ~= "" and config.pythonPath or nil
	local snapshot = M.snapshot(root, { explicit = explicit })
	if not explicit and snapshot.validity == "valid" then
		resolved.pythonPath = snapshot.value.interpreter
	end
	return resolved, snapshot
end

function M.venv_name(root)
	local snapshot = M.snapshot(root)
	local python = snapshot.value.interpreter
	if not python or (snapshot.source ~= "manual" and not contained(root, python)) then
		return ""
	end
	local directory = vim.fs.dirname(python)
	local leaf = vim.fs.basename(directory)
	local environment_root = (leaf == "bin" or leaf == "Scripts") and vim.fs.dirname(directory) or directory
	return vim.fs.basename(environment_root)
end

function M.repl_identity(root)
	root = canonical(root)
	return root and vim.json.encode({ "host", root, "python-repl" }) or nil
end

function M.repl_spec(root, interpreter)
	root = canonical(root)
	local snapshot = root and M.snapshot(root) or nil
	local python = executable(interpreter) or (snapshot and executable(snapshot.value.interpreter))
	if not root or not python then
		return nil, "project Python is unavailable"
	end
	return {
		key = M.repl_identity(root),
		launch = { argv = { python, "-i" }, cwd = root, env = {} },
		policy = { dispose_on_success = true, dispose_on_stop = false },
		view = { layout = "bottom", title = "Python REPL" },
		metadata = { kind = "python-repl", interpreter = python },
	}
end

function M.repl(action, root, options)
	local terminal = configured.terminal
	if type(terminal) ~= "table" or type(terminal[action]) ~= "function" then
		return nil, "terminal lifecycle is unavailable"
	end
	options = options or {}
	local repl_root = canonical(root)
	if not repl_root then
		return nil, "project root is invalid"
	end
	if action == "status" then
		return terminal.status(M.repl_identity(repl_root))
	elseif action == "send" then
		return terminal.send(M.repl_identity(repl_root), options.text, repl_root)
	end
	local spec, err = M.repl_spec(repl_root, options.interpreter)
	if not spec then
		return nil, err
	end
	return terminal[action](spec)
end

function M._reset_for_tests()
	configured = {}
	is_configured = false
	selected = {}
	snapshots = {}
	generations = {}
end

return M
