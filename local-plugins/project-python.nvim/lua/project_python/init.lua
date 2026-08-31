local M = {}

local uv = vim.uv
local configured = {}
local selected = {}
local snapshots = {}
local generations = {}

local DEFAULT_MARKERS = {
	"pyrightconfig.json",
	"pyproject.toml",
	"setup.py",
	"setup.cfg",
	"requirements.txt",
	"Pipfile",
}

local function copy(value)
	return vim.deepcopy(value)
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
		return true, executable(absolute_from(root, value))
	end
	if type(value) ~= "table" then
		return false
	end
	local python_path = type(value.pythonPath) == "string" and value.pythonPath or nil
	local venv_path = type(value.venvPath) == "string" and value.venvPath or nil
	local venv = type(value.venv) == "string" and value.venv or nil
	if python_path and python_path ~= "" then
		return true, executable(absolute_from(root, python_path))
	end
	if (venv_path and venv_path ~= "") or (venv and venv ~= "") then
		if not venv or venv == "" then
			return true, nil
		end
		local base = venv_path and venv_path ~= "" and absolute_from(root, venv_path) or root
		return true, base and environment_python(vim.fs.joinpath(base, venv)) or nil
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
	end
	local result = copy(previous)
	result._fingerprint = nil
	return result
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
	configured = vim.tbl_extend("force", {}, opts or {})
	return M
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

function M.snapshot(root, options)
	root = canonical(root)
	if not root then
		return { generation = 0, source = "none", validity = "invalid", value = { root = nil, interpreter = nil } }
	end
	options = options or {}
	local present, explicit = explicit_candidate(root, explicit_for(root, options.explicit))
	if present then
		return publish(root, "explicit", explicit and "valid" or "invalid", explicit)
	end
	local manual = selected[root]
	if manual then
		local valid = executable(manual)
		if valid then
			selected[root] = valid
			return publish(root, "manual", "valid", valid)
		end
		selected[root] = nil
	end
	local source, python = automatic(root)
	return publish(root, source, python and "valid" or "invalid", python)
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
	return result
end

local function settings_explicit(settings)
	local python = type(settings) == "table" and settings.python or nil
	if type(python) ~= "table" then
		return nil
	end
	for _, key in ipairs({ "pythonPath", "venvPath", "venv" }) do
		if type(python[key]) == "string" and python[key] ~= "" then
			return python
		end
	end
	return nil
end

function M.apply_pyright(config, root)
	if type(config) ~= "table" then
		return nil, "Pyright config is invalid"
	end
	root = canonical(root or config.root_dir)
	local explicit = settings_explicit(config.settings)
	local snapshot = M.snapshot(root, { explicit = explicit })
	if explicit or snapshot.validity ~= "valid" then
		return snapshot
	end
	local settings = config.settings or {}
	local merged = vim.tbl_deep_extend("force", {}, settings, {
		python = { pythonPath = snapshot.value.interpreter },
	})
	for key in pairs(settings) do
		settings[key] = nil
	end
	for key, value in pairs(merged) do
		settings[key] = value
	end
	config.settings = settings
	return snapshot
end

function M.neotest_python(root)
	local snapshot = M.snapshot(root)
	return snapshot.validity == "valid" and { snapshot.value.interpreter } or nil
end

function M.neotest_runner()
	return configured.neotest_runner or "pytest"
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
	local python = executable(interpreter) or (snapshot and snapshot.value.interpreter)
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
	if action == "status" then
		return terminal.status(M.repl_identity(root))
	elseif action == "send" then
		return terminal.send(M.repl_identity(root), options.text)
	end
	local spec, err = M.repl_spec(root, options.interpreter)
	if not spec then
		return nil, err
	end
	return terminal[action](spec)
end

function M._reset_for_tests()
	configured = {}
	selected = {}
	snapshots = {}
	generations = {}
end

return M
