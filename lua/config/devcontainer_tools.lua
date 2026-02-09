local M = {}
local devcontainer_shell_term
local container_workspace_cache = {}

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

local function read_devcontainer_json(workspace)
	local function strip_jsonc(content)
		content = content:gsub("/%*.-%*/", "")

		local cleaned = {}
		for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
			local chars = {}
			local in_string = false
			local escape = false
			local i = 1
			while i <= #line do
				local ch = line:sub(i, i)
				local next_ch = i < #line and line:sub(i + 1, i + 1) or ""

				if not in_string and ch == "/" and next_ch == "/" then
					break
				end

				table.insert(chars, ch)

				if in_string then
					if escape then
						escape = false
					elseif ch == "\\" then
						escape = true
					elseif ch == '"' then
						in_string = false
					end
				elseif ch == '"' then
					in_string = true
				end

				i = i + 1
			end

			table.insert(cleaned, table.concat(chars))
		end

		local out = table.concat(cleaned, "\n")
		out = out:gsub(",(%s*[}%]])", "%1")
		return out
	end

	local paths = {
		workspace .. "/.devcontainer/devcontainer.json",
		workspace .. "/.devcontainer.json",
	}

	for _, path in ipairs(paths) do
		if vim.loop.fs_stat(path) then
			local ok, lines = pcall(vim.fn.readfile, path)
			if ok and lines then
				local content = table.concat(lines, "\n")
				local decoded_ok, decoded = pcall(vim.json.decode, content)
				if not decoded_ok then
					decoded_ok, decoded = pcall(vim.json.decode, strip_jsonc(content))
				end
				if decoded_ok and type(decoded) == "table" then
					return decoded
				end
			end
		end
	end

	return nil
end

local function get_container_workspace(host_workspace)
	if vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE and vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE ~= "" then
		return vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE
	end

	if container_workspace_cache[host_workspace] ~= nil then
		return container_workspace_cache[host_workspace]
	end

	local decoded = read_devcontainer_json(host_workspace)
	if decoded and type(decoded.workspaceFolder) == "string" and decoded.workspaceFolder ~= "" then
		container_workspace_cache[host_workspace] = decoded.workspaceFolder
		return decoded.workspaceFolder
	end

	container_workspace_cache[host_workspace] = nil
	return nil
end

local function expand_container_prefix(prefix, host_workspace)
	if not prefix or prefix == "" then
		return nil
	end

	local basename = vim.fn.fnamemodify(host_workspace, ":t")
	local expanded = prefix
	expanded = expanded:gsub("${localWorkspaceFolderBasename}", basename)
	expanded = expanded:gsub("${localWorkspaceFolder}", host_workspace)
	return expanded
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

function M.find_workspace(start_dir)
	return find_workspace(start_dir)
end

function M.clear_cache()
	container_workspace_cache = {}
end

function M.container_path_to_host(path, start_dir)
	if not path or path == "" then
		return path
	end

	if vim.loop.fs_stat(path) then
		return path
	end

	local host_workspace = find_workspace(start_dir)
	local basename = vim.fn.fnamemodify(host_workspace, ":t")
	local configured_prefix = expand_container_prefix(get_container_workspace(host_workspace), host_workspace)
	local override_prefix = expand_container_prefix(vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE, host_workspace)
	local prefixes = {
		override_prefix,
		configured_prefix,
		"/workspace",
		"/workspaces",
		"/workspaces/" .. basename,
	}

	local first_candidate = nil

	for _, prefix in ipairs(prefixes) do
		if prefix and prefix ~= "" then
			if path == prefix then
				return host_workspace
			end
			if vim.startswith(path, prefix .. "/") then
				local rel = path:sub(#prefix + 2)
				local first_slash = rel:find("/", 1, true)
				local rel_head = first_slash and rel:sub(1, first_slash - 1) or rel
				local rel_tail = first_slash and rel:sub(first_slash + 1) or nil

				local candidates = { vim.fs.joinpath(host_workspace, rel) }
				if rel_tail and rel_tail ~= "" then
					table.insert(candidates, vim.fs.joinpath(host_workspace, rel_tail))
				end

				if rel_head and rel_head ~= "" and string.lower(rel_head) == string.lower(basename) and rel_tail and rel_tail ~= "" then
					table.insert(candidates, vim.fs.joinpath(host_workspace, rel_tail))
				end

				if rel == basename then
					table.insert(candidates, host_workspace)
				elseif vim.startswith(rel, basename .. "/") then
					table.insert(candidates, vim.fs.joinpath(host_workspace, rel:sub(#basename + 2)))
				end

				for _, candidate in ipairs(candidates) do
					if not first_candidate then
						first_candidate = candidate
					end
					if vim.loop.fs_stat(candidate) then
						return candidate
					end
				end
			end
		end
	end

	if first_candidate then
		return first_candidate
	end

	local marker = "/" .. basename .. "/"
	local marker_pos = path:find(marker, 1, true)
	if marker_pos then
		local rel = path:sub(marker_pos + #marker)
		if rel ~= "" then
			local candidate = vim.fs.joinpath(host_workspace, rel)
			if vim.loop.fs_stat(candidate) then
				return candidate
			end
			return candidate
		end
	end

	if vim.endswith(path, "/" .. basename) then
		return host_workspace
	end

	return path
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
		container_workspace_cache = {}
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

	vim.api.nvim_create_user_command("DevcontainerWorkspaceOverride", function(opts)
		container_workspace_cache = {}
		if opts.args == "" then
			vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE = nil
			notify("Container workspace override cleared")
			return
		end

		vim.env.NVIM_DEVCONTAINER_CONTAINER_WORKSPACE = opts.args
		notify("Container workspace override: " .. opts.args)
	end, {
		nargs = "?",
		desc = "Set or clear container workspace path override",
	})

	vim.api.nvim_create_user_command("DevcontainerMapPath", function(opts)
		local mapped = M.container_path_to_host(opts.args, vim.loop.cwd())
		notify("Mapped path: " .. mapped)
	end, {
		nargs = 1,
		desc = "Map a container path to host path",
	})

	vim.api.nvim_create_user_command("DevcontainerClearCache", function()
		M.clear_cache()
		notify("Devcontainer cache cleared")
	end, {
		nargs = 0,
		desc = "Clear devcontainer path mapping cache",
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
