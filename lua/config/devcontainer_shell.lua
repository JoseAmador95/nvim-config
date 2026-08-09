local M = {}
local uv = vim.uv

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Devcontainer" })
end

local function find_workspace(start_dir)
	if vim.env.NVIM_DEVCONTAINER_WORKSPACE and vim.env.NVIM_DEVCONTAINER_WORKSPACE ~= "" then
		return vim.fn.fnamemodify(vim.env.NVIM_DEVCONTAINER_WORKSPACE, ":p")
	end

	local dir = vim.fn.fnamemodify(start_dir or uv.cwd(), ":p")
	while dir and dir ~= "/" do
		if uv.fs_stat(dir .. "/.devcontainer/devcontainer.json") ~= nil then
			return dir
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end

	return uv.cwd()
end

function M.setup()
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

		local workspace = find_workspace(uv.cwd())
		local shell_bootstrap =
			[[if [ -n "$SHELL" ] && [ -x "$SHELL" ]; then exec "$SHELL" -l; elif command -v bash >/dev/null 2>&1; then exec bash -l; elif command -v zsh >/dev/null 2>&1; then exec zsh -l; else exec sh; fi]]
		local record, err = require("config.terminal").toggle({
			runtime = "devcontainer",
			root = workspace,
			id = "shell",
			argv = {
				"devcontainer",
				"exec",
				"--workspace-folder",
				workspace,
				"--",
				"sh",
				"-lc",
				shell_bootstrap,
			},
			cwd = workspace,
			env = {},
			layout = "bottom",
			title = "Devcontainer shell",
		})
		if not record then
			notify("Could not open shell: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, {
		nargs = 0,
		desc = "Open interactive shell inside devcontainer",
	})
end

return M
