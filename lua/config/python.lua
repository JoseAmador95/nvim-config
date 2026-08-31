-- Host adapters for project-python.nvim. Commands, mappings, prompts, LSP
-- restarts, and upstream plugin integration remain configuration policy.
local M = {}
local engine = require("project_python")
local repo = require("config.repo")
local terminal = require("config.terminal")
local uv = vim.uv
local repl_interpreters = {}
local dap_python_module

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Python" })
end

local function canonical(path)
	local value = type(path) == "string" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or nil
	return value and (uv.fs_realpath(value) or value) or nil
end

local function contained(root, path)
	root = canonical(root)
	path = type(path) == "string" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or nil
	return root ~= nil and path ~= nil and (path == root or vim.fs.relpath(root, path) ~= nil)
end

local function attached_pyright_root(buf, start)
	local best
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "pyright" })) do
		local candidate = client.name == "pyright" and client.config and client.config.root_dir or nil
		candidate = canonical(candidate)
		if candidate and contained(candidate, start) and (not best or #candidate > #best) then
			best = candidate
		end
	end
	return best
end

local function explicit_from_neoconf(root)
	local neoconf = package.loaded.neoconf
	if type(neoconf) ~= "table" or type(neoconf.get) ~= "function" then
		return nil
	end
	for _, key in ipairs({ "vscode", "lspconfig.pyright" }) do
		local ok, settings = pcall(neoconf.get, key, {}, { file = root })
		if ok and type(settings) == "table" then
			local direct = type(settings.python) == "table" and settings.python or nil
			local nested = type(settings.settings) == "table" and settings.settings.python or nil
			for _, python in pairs({ direct = direct, nested = nested }) do
				if type(python) == "table" then
					for _, field in ipairs({ "pythonPath", "venvPath", "venv" }) do
						if type(python[field]) == "string" and python[field] ~= "" then
							return vim.deepcopy(python)
						end
					end
				end
			end
		end
	end
	return nil
end

local function fallback_python()
	for _, name in ipairs({ "python3", "python" }) do
		local path = vim.fn.exepath(name)
		if path ~= "" then
			return path
		end
	end
	return nil
end

local terminal_bridge = {
	status = function(identity)
		return terminal.status(identity)
	end,
	open = function(spec)
		return terminal.open(spec)
	end,
	toggle = function(spec)
		return terminal.toggle(spec)
	end,
	focus = function(spec)
		return terminal.focus(spec)
	end,
	restart = function(spec)
		return terminal.restart(spec)
	end,
	send = function(identity, text)
		return terminal.send(identity, text)
	end,
}

engine.setup({
	explicit = explicit_from_neoconf,
	fallback = fallback_python,
	terminal = terminal_bridge,
	neotest_runner = "pytest",
})

function M.root(buf)
	buf = buf or 0
	if buf ~= 0 and not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or (uv.cwd() or vim.fn.getcwd())
	return engine.resolve_root({
		start = start,
		attached_root = attached_pyright_root(buf, start),
		repo_root = repo.root(start),
	})
end

function M.snapshot(root)
	return engine.snapshot(root or M.root(0))
end

function M.for_root(root)
	local snapshot = engine.snapshot(root)
	return snapshot.value.interpreter, snapshot
end

function M.current()
	return M.for_root(M.root(0))
end

local function root_matches(client, root)
	return canonical(client.config and client.config.root_dir) == canonical(root)
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

local function install_dap_resolver()
	if type(dap_python_module) == "table" then
		dap_python_module.resolve_python = M.current
	end
end

local function public_python()
	local selector = package.loaded["venv-selector"]
	if type(selector) ~= "table" or type(selector.python) ~= "function" then
		return nil
	end
	local ok, path = pcall(selector.python)
	return ok and path or nil
end

local function repl_status(root)
	return engine.repl("status", root) or { exists = false, running = false }
end

local function restart_repl(root, python)
	local record, err = engine.repl("restart", root, { interpreter = python })
	if not record then
		notify("Could not restart REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	repl_interpreters[root] = python
end

local function confirm_repl_restart(root, python)
	local status = repl_status(root)
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

function M.refresh_current(buf, python)
	local root = M.root(buf or 0)
	python = python or public_python()
	if not root or type(python) ~= "string" then
		return nil, "Python selection is unavailable"
	end
	local before = engine.snapshot(root)
	local snapshot, err = engine.select(root, python)
	if not snapshot then
		return nil, err
	end
	if before.value.interpreter ~= snapshot.value.interpreter or before.source ~= snapshot.source then
		install_dap_resolver()
		restart_pyright(root)
		confirm_repl_restart(root, snapshot.value.interpreter)
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigPythonChanged", modeline = false })
	end
	return snapshot
end

function M.before_init(_, config)
	return engine.apply_pyright(config, config and config.root_dir or M.root(0))
end

function M.on_new_config(config, root)
	return engine.apply_pyright(config, root or (config and config.root_dir) or M.root(0))
end

function M.neotest_python(root)
	return engine.neotest_python(root)
end

function M.neotest_runner()
	return engine.neotest_runner()
end

function M.setup_dap(dap, dap_python)
	dap_python_module = dap_python or package.loaded["dap-python"]
	install_dap_resolver()
	dap.listeners.on_config.nvim_config_python = function(config)
		return engine.apply_dap(config, M.root(0))
	end
end

function M.open_repl()
	local root = M.root(0)
	local python = M.for_root(root)
	if not root or not python then
		notify("Could not open REPL: project Python is unavailable", vim.log.levels.ERROR)
		return
	end
	local status = repl_status(root)
	if status.running and repl_interpreters[root] and repl_interpreters[root] ~= python then
		vim.ui.select({ "Restart REPL", "Keep current REPL" }, {
			prompt = "The selected Python differs from the live REPL",
		}, function(choice)
			if choice == "Restart REPL" then
				restart_repl(root, python)
			elseif choice == "Keep current REPL" then
				engine.repl("focus", root, { interpreter = repl_interpreters[root] })
			end
		end)
		return
	end
	local record, err = engine.repl("toggle", root, { interpreter = python })
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
	local text = selection and visual_text() or vim.api.nvim_get_current_line()
	if not root or not text or text == "" then
		return
	end
	local status = repl_status(root)
	local python = repl_interpreters[root] or M.for_root(root)
	local record, err
	if not status.running then
		if status.exists then
			record, err = engine.repl("restart", root, { interpreter = python })
		else
			record, err = engine.repl("open", root, { interpreter = python })
		end
		repl_interpreters[root] = python
	else
		record, err = engine.repl("focus", root, { interpreter = python })
	end
	if not record then
		notify("Could not prepare REPL: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	local ok, send_err = engine.repl("send", root, { text = "exec(" .. vim.json.encode(text) .. ")" })
	if not ok then
		notify(send_err, vim.log.levels.ERROR)
	end
end

function M.venv_name(root)
	return engine.venv_name(root or M.root(0))
end

function M.setup()
	vim.keymap.set("n", "<leader>pr", M.open_repl, { desc = "Python REPL" })
	vim.keymap.set("n", "<leader>ps", function()
		M.send(false)
	end, { desc = "Send line to Python REPL" })
	vim.keymap.set("x", "<leader>ps", function()
		M.send(true)
	end, { desc = "Send selection to Python REPL" })
end

M._engine = engine

return M
