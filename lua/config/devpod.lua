-- Host/DevPod bridge. The Python launcher owns provisioning, tmux and tunnels;
-- this module owns only the editor-side, schema-checked RPC endpoint.
local M = {}

local uv = vim.uv
local MAX_OUTPUT = 1024 * 1024
local MAX_REQUEST = 64 * 1024

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.devpod source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local launcher = vim.fs.joinpath(config_root, "scripts", "devpod-nvim")

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "DevPod" })
end

local function exact_keys(value, allowed)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, "request contains an unknown field"
		end
	end
	return true
end

local function decode_hex(encoded)
	if type(encoded) ~= "string" or #encoded == 0 or #encoded > MAX_REQUEST * 2 or #encoded % 2 ~= 0 then
		return nil, "request hex is invalid"
	end
	if encoded:find("[^0-9a-f]") then
		return nil, "request hex is invalid"
	end
	return (encoded:gsub("..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

local function contained(root, path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function relative_path(root, relative, kind)
	if type(relative) ~= "string" or relative == "" or relative:find("%z") or relative:sub(1, 1) == "/" then
		return nil, "path must be a non-empty relative string"
	end
	for part in relative:gmatch("[^/]+") do
		if part == ".." then
			return nil, "path traversal is not allowed"
		end
	end
	local lexical = vim.fs.normalize(vim.fs.joinpath(root, relative))
	local resolved = uv.fs_realpath(lexical)
	local canonical_root = uv.fs_realpath(root)
	if not resolved or not canonical_root or not contained(canonical_root, resolved) then
		return nil, "path resolves outside the registered workspace"
	end
	local stat = uv.fs_stat(resolved)
	if not stat or stat.type ~= kind then
		return nil, "path is not a " .. kind
	end
	return lexical
end

local function positive_integer(value)
	return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function valid_argv(argv)
	if type(argv) ~= "table" or not vim.islist(argv) or #argv == 0 or #argv > 256 then
		return false
	end
	for _, value in ipairs(argv) do
		if type(value) ~= "string" or value == "" or value:find("%z") then
			return false
		end
	end
	return true
end

local function execute(request)
	local root = vim.env.NVIM_DEVPOD_CONTAINER_ROOT
	if type(root) ~= "string" or root == "" then
		return nil, "container root is not registered"
	end
	if request.action == "open_location" then
		local ok, err = exact_keys(request, {
			version = true,
			token = true,
			action = true,
			path = true,
			line = true,
			column = true,
		})
		if not ok then
			return nil, err
		end
		if not positive_integer(request.line) or not positive_integer(request.column) then
			return nil, "line and column must be positive integers"
		end
		local path, path_err = relative_path(root, request.path, "file")
		if not path then
			return nil, path_err
		end
		require("config.editor").open_file_in_tab(path, { lnum = request.line, col = request.column })
		return { ok = true, action = request.action }
	end
	if request.action == "exec" then
		local ok, err = exact_keys(request, {
			version = true,
			token = true,
			action = true,
			argv = true,
			cwd = true,
		})
		if not ok then
			return nil, err
		end
		if not valid_argv(request.argv) then
			return nil, "argv must be a non-empty string array"
		end
		local cwd, cwd_err = relative_path(root, request.cwd == "." and "" or request.cwd, "directory")
		if request.cwd == "." then
			cwd = uv.fs_realpath(root)
			cwd_err = nil
		end
		if not cwd then
			return nil, cwd_err
		end
		local result = vim.system(request.argv, { cwd = cwd, text = false }):wait()
		local stdout = result.stdout or ""
		local stderr = result.stderr or ""
		if #stdout + #stderr > MAX_OUTPUT then
			return nil, "command output exceeds 1 MiB"
		end
		return {
			ok = true,
			action = request.action,
			code = result.code,
			signal = result.signal,
			stdout_hex = (stdout:gsub(".", function(byte)
				return string.format("%02x", string.byte(byte))
			end)),
			stderr_hex = (stderr:gsub(".", function(byte)
				return string.format("%02x", string.byte(byte))
			end)),
		}
	end
	return nil, "unsupported RPC action"
end

function M.rpc_hex(encoded)
	local payload, decode_err = decode_hex(encoded)
	if not payload then
		return vim.json.encode({ ok = false, error = decode_err })
	end
	local decoded, value = pcall(vim.json.decode, payload)
	if not decoded or type(value) ~= "table" or vim.islist(value) then
		return vim.json.encode({ ok = false, error = "request must be one JSON object" })
	end
	if value.version ~= 1 or value.token ~= vim.env.NVIM_DEVPOD_TOKEN or value.token == "" then
		return vim.json.encode({ ok = false, error = "RPC authentication failed" })
	end
	local ok, result, err = pcall(function()
		local response, response_err = execute(value)
		if not response then
			return nil, response_err
		end
		return response
	end)
	if not ok then
		return vim.json.encode({ ok = false, error = tostring(result) })
	end
	if not result then
		return vim.json.encode({ ok = false, error = err })
	end
	return vim.json.encode(result)
end

function M.in_workspace()
	return vim.env.NVIM_DEVPOD == "1"
end

function M.request_host(action, dependencies)
	if not M.in_workspace() then
		return nil, "not running inside a DevPod editor"
	end
	if action ~= "tuicr" and action ~= "host_editor" and action ~= "lazygit" then
		return nil, "unsupported host action"
	end
	local socket_path = vim.env.NVIM_DEVPOD_CONTROLLER_SOCKET
	local token = vim.env.NVIM_DEVPOD_TOKEN
	if not socket_path or socket_path == "" or not token or token == "" then
		return nil, "host controller is not registered"
	end
	local deps = dependencies or {}
	local report = deps.notify or notify
	local pipe = (deps.new_pipe or uv.new_pipe)(false)
	local payload = vim.json.encode({ version = 1, token = token, action = action }) .. "\n"
	local received = ""
	pipe:connect(socket_path, function(connect_err)
		if connect_err then
			pipe:close()
			report("Host controller is unreachable: " .. tostring(connect_err), vim.log.levels.ERROR)
			return
		end
		pipe:write(payload)
		pipe:read_start(function(read_err, chunk)
			if read_err then
				pipe:read_stop()
				pipe:close()
				report("Host controller read failed: " .. tostring(read_err), vim.log.levels.ERROR)
				return
			end
			if not chunk then
				return
			end
			received = received .. chunk
			if #received > MAX_REQUEST then
				pipe:read_stop()
				pipe:close()
				report("Host controller response exceeds 64 KiB", vim.log.levels.ERROR)
				return
			end
			local line = received:match("^(.-)\n")
			if line then
				pipe:read_stop()
				pipe:close()
				local decoded, response = pcall(vim.json.decode, line)
				if not decoded or type(response) ~= "table" or response.ok ~= true then
					local detail = decoded and type(response) == "table" and response.error or "invalid response"
					report("Host controller rejected request: " .. tostring(detail), vim.log.levels.ERROR)
				end
			end
		end)
	end)
	return true
end

local function root()
	return require("config.repo").current_root(0) or uv.cwd()
end

local function replace_editor(recreate, allow_network)
	if M.in_workspace() then
		return nil, "already running inside DevPod"
	end
	if not vim.env.TMUX_PANE or vim.env.TMUX_PANE == "" then
		return nil, "DevPodUp requires tmux's single-pane editor window"
	end
	local pane = vim.system(
		{ "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE, "#{window_name}\t#{window_panes}" },
		{ text = true }
	):wait()
	if pane.code ~= 0 or vim.trim(pane.stdout or "") ~= "editor\t1" then
		return nil, "DevPodUp requires tmux's single-pane editor window"
	end
	local shell_command = "exec " .. vim.fn.shellescape(launcher) .. " up"
	if recreate then
		shell_command = shell_command .. " --recreate"
	end
	if allow_network then
		shell_command = shell_command .. " --allow-network"
	end
	vim.system({ "tmux", "set-option", "-p", "-t", vim.env.TMUX_PANE, "remain-on-exit", "on" }):wait()
	local result = vim.system({ "tmux", "respawn-pane", "-k", "-t", vim.env.TMUX_PANE, "-c", root(), shell_command }, {
		text = true,
	}):wait()
	if result.code ~= 0 then
		return nil, vim.trim(result.stderr or "tmux rejected the editor replacement")
	end
	return true
end

function M.setup()
	if M.in_workspace() then
		vim.g.nvim_devpod_status = {
			provider = vim.env.NVIM_DEVPOD_PROVIDER,
			project = vim.env.NVIM_DEVPOD_PROJECT,
		}
		vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigDevPodChanged" })
	end

	vim.api.nvim_create_user_command("DevPodUp", function(command)
		local ok, err = replace_editor(false, command.bang)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, { bang = true, desc = "Replace the tmux editor pane with DevPod Neovim (! permits first network bootstrap)" })

	vim.api.nvim_create_user_command("DevPodRecreate", function(command)
		local ok, err = replace_editor(true, command.bang)
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, { bang = true, desc = "Recreate DevPod and reapply the read-only config snapshot" })

	vim.api.nvim_create_user_command("DevPodStatus", function()
		vim.system({ launcher, "status", "--json", "--repo", root() }, { text = true }, function(result)
			vim.schedule(function()
				if result.code == 0 then
					notify(vim.trim(result.stdout or ""))
				else
					notify(vim.trim(result.stderr or "DevPod status failed"), vim.log.levels.ERROR)
				end
			end)
		end)
	end, { desc = "Show private DevPod workspace state" })

	vim.api.nvim_create_user_command("HostEditor", function()
		local ok, err = M.request_host("host_editor")
		if not ok then
			notify(err, vim.log.levels.ERROR)
		end
	end, { desc = "Explicitly return the tmux editor pane to host Neovim" })
end

M._execute = execute
M._decode_hex = decode_hex
M._launcher = launcher
M._replace_editor = replace_editor

return M
