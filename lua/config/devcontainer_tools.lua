local M = {}
local devcontainer_shell_term

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Devcontainer" })
end

local function find_workspace(start_dir)
	if vim.env.NVIM_DEVCONTAINER_WORKSPACE and vim.env.NVIM_DEVCONTAINER_WORKSPACE ~= "" then
		return vim.fn.fnamemodify(vim.env.NVIM_DEVCONTAINER_WORKSPACE, ":p")
	end

	local dir = vim.fn.fnamemodify(start_dir or vim.loop.cwd(), ":p")
	while dir and dir ~= "/" do
		local has_dir_config = vim.loop.fs_stat(dir .. "/.devcontainer/devcontainer.json") ~= nil
		local has_file_config = vim.loop.fs_stat(dir .. "/.devcontainer.json") ~= nil
		if has_dir_config or has_file_config then
			return dir
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end

	return vim.fn.fnamemodify(start_dir or vim.loop.cwd(), ":p")
end

function M.wrapper(tool)
	return vim.fn.stdpath("config") .. "/bin/" .. tool .. "-wrapper"
end

function M.clangd_cmd(extra_args)
	local cmd = { M.wrapper("clangd") }
	if extra_args and #extra_args > 0 then
		vim.list_extend(cmd, extra_args)
	end
	return cmd
end

function M.setup()
	local bin_dir = vim.fn.stdpath("config") .. "/bin"
	if not string.find(vim.env.PATH or "", bin_dir, 1, true) then
		vim.env.PATH = bin_dir .. ":" .. (vim.env.PATH or "")
	end

	vim.api.nvim_create_user_command("DevcontainerMode", function(opts)
		local mode = opts.args ~= "" and opts.args or "auto"
		if mode ~= "auto" and mode ~= "on" and mode ~= "off" then
			notify("Invalid mode. Use: auto | on | off", vim.log.levels.ERROR)
			return
		end

		vim.env.NVIM_DEVCONTAINER_MODE = mode
		notify("Mode set to: " .. mode)
	end, {
		nargs = "?",
		complete = function()
			return { "auto", "on", "off" }
		end,
		desc = "Set devcontainer wrapper mode",
	})

	vim.api.nvim_create_user_command("DevcontainerModeStatus", function()
		notify("Current mode: " .. (vim.env.NVIM_DEVCONTAINER_MODE or "auto"))
	end, {
		nargs = 0,
		desc = "Show devcontainer wrapper mode",
	})

	vim.api.nvim_create_user_command("DevcontainerWorkspace", function(opts)
		if opts.args == "" then
			vim.env.NVIM_DEVCONTAINER_WORKSPACE = nil
			notify("Workspace override cleared")
			return
		end

		local path = vim.fn.fnamemodify(opts.args, ":p")
		vim.env.NVIM_DEVCONTAINER_WORKSPACE = path
		notify("Workspace override: " .. path)
	end, {
		nargs = "?",
		complete = "dir",
		desc = "Set or clear devcontainer workspace override",
	})

	vim.api.nvim_create_user_command("DevcontainerShell", function()
		if vim.fn.executable("devcontainer") ~= 1 then
			notify("devcontainer CLI not found in PATH", vim.log.levels.ERROR)
			return
		end

		local ok, terminal_mod = pcall(require, "toggleterm.terminal")
		if not ok then
			notify("toggleterm.nvim is required for :DevcontainerShell", vim.log.levels.ERROR)
			return
		end

		local workspace = find_workspace(vim.loop.cwd())
		local shell_bootstrap = [[if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then exec "$SHELL" -l; elif command -v bash >/dev/null 2>&1; then exec bash -l; elif command -v zsh >/dev/null 2>&1; then exec zsh -l; else exec sh; fi]]
		local cmd = "devcontainer exec --workspace-folder "
			.. vim.fn.shellescape(workspace)
			.. " -- sh -lc "
			.. vim.fn.shellescape(shell_bootstrap)

		if not devcontainer_shell_term then
			devcontainer_shell_term = terminal_mod.Terminal:new({
				cmd = cmd,
				direction = "horizontal",
				close_on_exit = false,
				hidden = true,
			})
		end

		devcontainer_shell_term.cmd = cmd
		devcontainer_shell_term:toggle()
	end, {
		nargs = 0,
		desc = "Open interactive shell inside devcontainer",
	})
end

return M
