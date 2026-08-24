-- Per-project Python selection shared by LSP, Neotest, DAP, and the REPL.
-- Local environments are discovered without running a manager; venv-selector
-- provides explicit overrides. Neither path mutates vim.env.
local M = {}

local uv = vim.uv
local selected = {}
local runners = {}
local repl_interpreters = {}
local ROOT_MARKERS = {
	"pyrightconfig.json",
	"pyproject.toml",
	"setup.py",
	"setup.cfg",
	"requirements.txt",
	"Pipfile",
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Python" })
end

local function canonical_root(path)
	local value = path and vim.fn.fnamemodify(path, ":p") or nil
	return value and (uv.fs_realpath(value) or vim.fs.normalize(value)) or nil
end

local function lexical_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function executable(path)
	local value = lexical_path(path)
	local stat = value and uv.fs_stat(value) or nil
	return stat and stat.type == "file" and uv.fs_access(value, "X") and value or nil
end

local function environment_python(path)
	local environment = lexical_path(path)
	if not environment then
		return nil
	end
	for _, relative in ipairs({ "bin/python", "bin/python3", "Scripts/python.exe", "python.exe" }) do
		local python = executable(vim.fs.joinpath(environment, relative))
		if python then
			return python
		end
	end
end

local function root_contains(root, path)
	root = canonical_root(root)
	path = lexical_path(path)
	if not root or not path then
		return false
	end
	return path == root or vim.fs.relpath(root, path) ~= nil
end

local function environment_from_value(root, value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	local path = value
	if vim.fs.abspath(path) ~= vim.fs.normalize(path) then
		path = vim.fs.joinpath(root, path)
	end
	path = lexical_path(path)
	return root_contains(root, path) and path or nil
end

local function attached_pyright_root(buf, start)
	local best
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "pyright" })) do
		local candidate = client.name == "pyright" and client.config and client.config.root_dir or nil
		candidate = type(candidate) == "string" and canonical_root(candidate) or nil
		if candidate and root_contains(candidate, start) and (not best or #candidate > #best) then
			best = candidate
		end
	end
	return best
end

function M.root(buf)
	buf = buf or 0
	if buf ~= 0 and not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or (uv.cwd() or vim.fn.getcwd())
	local lsp_root = attached_pyright_root(buf, start)
	if lsp_root then
		return lsp_root
	end

	local git_root = require("config.repo").root(start)
	local marker_root = canonical_root(vim.fs.root(start, ROOT_MARKERS))
	if marker_root and (not git_root or root_contains(git_root, marker_root)) then
		return marker_root
	end
	if git_root then
		return git_root
	end
	return canonical_root(
		marker_root or (uv.fs_stat(start) and uv.fs_stat(start).type == "directory" and start or vim.fs.dirname(start))
	) or canonical_root(uv.cwd())
end

local function fallback_python()
	for _, name in ipairs({ "python3", "python" }) do
		local path = vim.fn.exepath(name)
		local python = path ~= "" and executable(path) or nil
		if python then
			return python
		end
	end
	return "python3"
end

local function public_python()
	local ok, selector = pcall(require, "venv-selector")
	if not ok or type(selector.python) ~= "function" then
		return nil
	end
	local call_ok, path = pcall(selector.python)
	if not call_ok or type(path) ~= "string" or path == "" then
		return nil
	end
	return executable(path)
end

local function automatic_python(root)
	local uv_environment = environment_from_value(root, vim.env.UV_PROJECT_ENVIRONMENT)
	if uv_environment then
		local python = environment_python(uv_environment)
		if python then
			return python
		end
	end

	for _, relative in ipairs({ ".venv", ".pixi/envs/default", "venv", "env", ".conda" }) do
		local python = environment_python(vim.fs.joinpath(root, relative))
		if python then
			return python
		end
	end

	for _, name in ipairs({ "VIRTUAL_ENV", "CONDA_PREFIX" }) do
		local value = vim.env[name]
		local environment = environment_from_value(root, value)
		if environment then
			local python = environment_python(environment)
			if python then
				return python
			end
		end
	end

	return fallback_python()
end

function M.for_root(root)
	root = canonical_root(root)
	if not root then
		return fallback_python()
	end
	if selected[root] then
		local python = executable(selected[root])
		if python then
			selected[root] = python
			return python
		end
		selected[root] = nil
	end
	return automatic_python(root)
end

function M.current()
	return M.for_root(M.root(0))
end

local function root_matches(client, root)
	local client_root = client.config and client.config.root_dir
	client_root = type(client_root) == "string" and canonical_root(client_root) or nil
	return client_root == root
end

local function restart_pyright(root)
	local buffers = {}
	for _, client in ipairs(vim.lsp.get_clients({ name = "pyright" })) do
		if client.name == "pyright" and root_matches(client, root) then
			for buf in pairs(client.attached_buffers or {}) do
				buffers[buf] = true
			end
			client:stop()
		end
	end
	if not next(buffers) then
		return
	end
	vim.defer_fn(function()
		for buf in pairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then
				local config = vim.deepcopy(vim.lsp.config.pyright or {})
				config.root_dir = root
				vim.lsp.start(config, {
					bufnr = buf,
					reuse_client = function()
						return false
					end,
				})
			end
		end
	end, 100)
end

local function repl_identity(root)
	return { runtime = "host", root = root, id = "python-repl" }
end

local function has_module(python, module)
	local result = vim.system({
		python,
		"-c",
		("import importlib.util,sys;sys.exit(0 if importlib.util.find_spec(%q) else 1)"):format(module),
	}, { text = true }):wait()
	return result.code == 0
end

local function repl_spec(root, python)
	local argv
	if has_module(python, "IPython") then
		argv = { python, "-m", "IPython", "--no-autoindent" }
	else
		argv = { python, "-i" }
	end
	return {
		runtime = "host",
		root = root,
		id = "python-repl",
		argv = argv,
		cwd = root,
		env = {},
		layout = "bottom",
		title = "Python REPL",
		close_on_success = true,
	}
end

local function restart_repl(root, python)
	local record, err = require("config.terminal").restart(repl_spec(root, python))
	if not record then
		notify("Could not restart REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	repl_interpreters[root] = python
end

local function confirm_repl_restart(root, python)
	local status = require("config.terminal").status(repl_identity(root))
	if not status.running or repl_interpreters[root] == python then
		return
	end
	vim.ui.select({ "Restart REPL", "Keep current REPL" }, {
		prompt = "Python environment changed for a live REPL",
	}, function(choice)
		if choice == "Restart REPL" then
			restart_repl(root, python)
		end
	end)
end

local function install_dap_resolver()
	local ok, dap_python = pcall(require, "dap-python")
	if ok then
		dap_python.resolve_python = M.current
	end
end

function M.refresh_current(buf, python)
	local root = M.root(buf or 0)
	if python ~= nil then
		python = executable(python)
	else
		python = public_python()
	end
	if not root or not python then
		return
	end
	local changed = selected[root] ~= python
	selected[root] = python
	if changed then
		runners[python] = nil
		install_dap_resolver()
		restart_pyright(root)
		confirm_repl_restart(root, python)
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigPythonChanged", modeline = false })
	end
end

local function has_explicit_environment(settings)
	local python = type(settings) == "table" and settings.python or nil
	if type(python) ~= "table" then
		return false
	end
	for _, key in ipairs({ "pythonPath", "venvPath", "venv" }) do
		if type(python[key]) == "string" and python[key] ~= "" then
			return true
		end
	end
	return false
end

local function project_has_explicit_environment(root)
	local ok, neoconf = pcall(require, "neoconf")
	if not ok or type(neoconf.get) ~= "function" then
		return false
	end
	for _, key in ipairs({ "vscode", "lspconfig.pyright" }) do
		local success, settings = pcall(neoconf.get, key, {}, { file = root })
		local nested = type(settings) == "table" and settings.settings or nil
		if success and (has_explicit_environment(settings) or has_explicit_environment(nested)) then
			return true
		end
	end
	return false
end

local function apply_lsp_python(config, root)
	if not config or has_explicit_environment(config.settings) then
		return
	end
	root = canonical_root(root)
	if not root then
		return
	end
	local settings = config.settings or {}
	local merged = vim.tbl_deep_extend("force", {}, settings, {
		python = { pythonPath = M.for_root(root) },
	})
	for key in pairs(settings) do
		settings[key] = nil
	end
	for key, value in pairs(merged) do
		settings[key] = value
	end
	config.settings = settings
end

function M.before_init(_, config)
	apply_lsp_python(config, config and config.root_dir or M.root(0))
end

function M.on_new_config(config, root)
	root = root or (config and config.root_dir) or M.root(0)
	if project_has_explicit_environment(root) then
		return
	end
	apply_lsp_python(config, root)
end

function M.neotest_python(root)
	return { M.for_root(root) }
end

function M.neotest_runner(python_command)
	local python = type(python_command) == "table" and python_command[1] or python_command
	if type(python) ~= "string" or python == "" then
		python = fallback_python()
	end
	if runners[python] == nil then
		runners[python] = has_module(python, "pytest") and "pytest" or "unittest"
	end
	return runners[python]
end

function M.setup_dap(dap)
	install_dap_resolver()
	dap.listeners.on_config["nvim_config_python"] = function(config)
		if config.type ~= "python" then
			return config
		end
		local resolved = vim.deepcopy(config)
		resolved.pythonPath = M.current()
		return resolved
	end
end

function M.open_repl()
	local root = M.root(0)
	local python = M.for_root(root)
	local status = require("config.terminal").status(repl_identity(root))
	if status.running and repl_interpreters[root] and repl_interpreters[root] ~= python then
		vim.ui.select({ "Restart REPL", "Keep current REPL" }, {
			prompt = "The selected Python differs from the live REPL",
		}, function(choice)
			if choice == "Restart REPL" then
				restart_repl(root, python)
			elseif choice == "Keep current REPL" then
				require("config.terminal").focus(repl_spec(root, repl_interpreters[root]))
			end
		end)
		return
	end
	local record, err = require("config.terminal").toggle(repl_spec(root, python))
	if not record then
		notify("Could not open REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	repl_interpreters[root] = python
end

local function visual_text()
	local start = vim.api.nvim_buf_get_mark(0, "<")
	local finish = vim.api.nvim_buf_get_mark(0, ">")
	if start[1] == 0 or finish[1] == 0 then
		return nil
	end
	local lines = vim.api.nvim_buf_get_text(0, start[1] - 1, start[2], finish[1] - 1, finish[2] + 1, {})
	return table.concat(lines, "\n")
end

function M.send(selection)
	local root = M.root(0)
	local source = selection and visual_text() or vim.api.nvim_get_current_line()
	if not source or source == "" then
		return
	end
	local terminal = require("config.terminal")
	local status = terminal.status(repl_identity(root))
	if not status.running then
		local python = M.for_root(root)
		local spec = repl_spec(root, python)
		local record, open_err
		if status.exists then
			record, open_err = terminal.restart(spec)
		else
			record, open_err = terminal.open(spec)
		end
		if not record then
			notify("Could not open REPL: " .. tostring(open_err), vim.log.levels.ERROR)
			return
		end
		repl_interpreters[root] = python
	else
		local python = repl_interpreters[root] or M.for_root(root)
		local record, focus_err = terminal.focus(repl_spec(root, python))
		if not record then
			notify("Could not focus REPL: " .. tostring(focus_err), vim.log.levels.ERROR)
			return
		end
	end
	local ok, err = terminal.send(repl_identity(root), "exec(" .. vim.json.encode(source) .. ")")
	if not ok then
		notify(err, vim.log.levels.ERROR)
	end
end

function M.venv_name(root)
	root = canonical_root(root) or M.root(0)
	local python = root and executable(selected[root]) or nil
	local manually_selected = python ~= nil
	python = python or (root and automatic_python(root) or nil)
	if not python then
		return ""
	end
	if not manually_selected and not root_contains(root, python) then
		return ""
	end
	local directory = vim.fs.dirname(python)
	local leaf = vim.fs.basename(directory)
	local env_root = (leaf == "bin" or leaf == "Scripts") and vim.fs.dirname(directory) or directory
	return vim.fs.basename(env_root)
end

function M.setup()
	vim.keymap.set("n", "<leader>rp", M.open_repl, { desc = "Python REPL" })
	vim.keymap.set("n", "<leader>rs", function()
		M.send(false)
	end, { desc = "Send line to Python REPL" })
	vim.keymap.set("x", "<leader>rs", function()
		M.send(true)
	end, { desc = "Send selection to Python REPL" })
end

M._selected = selected
M._has_module = has_module

return M
