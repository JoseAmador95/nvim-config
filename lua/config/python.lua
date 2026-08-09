-- Per-project Python selection shared by LSP, Neotest, DAP, and the REPL.
-- venv-selector remains the owner of discovery; this module consumes only its
-- public python() result and never mutates vim.env.
local M = {}

local uv = vim.uv
local selected = {}
local runners = {}
local repl_interpreters = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Python" })
end

local function canonical(path)
	local value = path and vim.fn.fnamemodify(path, ":p") or nil
	return value and (uv.fs_realpath(value) or vim.fs.normalize(value)) or nil
end

function M.root(buf)
	buf = buf or 0
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or (uv.cwd() or vim.fn.getcwd())
	local git_root = require("config.repo").root(start)
	if git_root then
		return git_root
	end
	local marker_root = vim.fs.root(start, { "pyproject.toml", "setup.cfg", "setup.py", ".git" })
	return canonical(
		marker_root or (uv.fs_stat(start) and uv.fs_stat(start).type == "directory" and start or vim.fs.dirname(start))
	) or canonical(uv.cwd())
end

local function fallback_python()
	for _, name in ipairs({ "python3", "python" }) do
		local path = vim.fn.exepath(name)
		if path ~= "" then
			return canonical(path) or path
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
	local resolved = canonical(path)
	local stat = resolved and uv.fs_stat(resolved) or nil
	return stat and stat.type == "file" and resolved or nil
end

function M.for_root(root)
	root = canonical(root)
	if not root then
		return fallback_python()
	end
	if selected[root] then
		return selected[root]
	end
	return fallback_python()
end

function M.current()
	return M.for_root(M.root(0))
end

local function root_matches(client, root)
	local client_root = client.config and client.config.root_dir
	client_root = type(client_root) == "string" and canonical(client_root) or nil
	return client_root == root
end

local function restart_pyright(root)
	local buffers = {}
	for _, client in ipairs(vim.lsp.get_clients({ name = "pyright" })) do
		if root_matches(client, root) then
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
				config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
					python = { pythonPath = M.for_root(root) },
				})
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

function M.refresh_current()
	local root = M.root(0)
	local python = public_python()
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

function M.before_init(params, config)
	local root = canonical(config and config.root_dir) or M.root(0)
	if not root then
		return
	end
	config.settings = vim.tbl_deep_extend("force", config.settings or {}, {
		python = { pythonPath = M.for_root(root) },
	})
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
	root = canonical(root) or M.root(0)
	local python = root and selected[root] or nil
	if not python then
		return ""
	end
	local env_root = vim.fs.dirname(vim.fs.dirname(python))
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
