local M = {}

local helper = vim.fs.normalize(vim.fn.expand("~/.config/tmux/scripts/dev-session-refresh.sh"))

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Dev Session Refresh" })
end

local function valid_pane(pane)
	return type(pane) == "string" and pane:match("^%%%d+$") ~= nil
end

local function modified_buffer()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			return name ~= "" and name or "[No Name]"
		end
	end
end

local function save_session()
	local loaded, auto_session = pcall(require, "auto-session")
	if not loaded then
		notify("auto-session is not available; the dev session was not refreshed", vim.log.levels.ERROR)
		return false
	end

	local saved, result = pcall(auto_session.save_session, nil, {
		show_message = false,
		is_autosave = true,
	})
	if not saved then
		notify("Could not save the Neovim session: " .. tostring(result), vim.log.levels.ERROR)
		return false
	end
	if result ~= true then
		notify("auto-session declined to save; the dev session was not refreshed", vim.log.levels.ERROR)
		return false
	end
	return true
end

local function prepare_refresh()
	local modified = modified_buffer()
	if modified then
		notify("Save or discard modified buffer before refreshing: " .. modified, vim.log.levels.ERROR)
		return false
	end
	return save_session()
end

local function quit_neovim()
	vim.api.nvim_cmd({ cmd = "quitall" }, {})
end

local function result_error(result, fallback)
	local message = vim.trim(result.stderr or "")
	if message == "" then
		message = vim.trim(result.stdout or "")
	end
	return message ~= "" and message or fallback
end

local function run_helper(action, pane, callback)
	local started, process = pcall(vim.system, { helper, action, pane }, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				notify(result_error(result, "tmux dev-session helper failed"), vim.log.levels.ERROR)
				return
			end
			callback()
		end)
	end)
	if not started then
		notify("Could not start tmux dev-session helper: " .. tostring(process), vim.log.levels.ERROR)
		return false
	end
	return true
end

local function request_host(devpod, action, callback)
	local ok, err = devpod.request_host(action, callback)
	if not ok then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	return true
end

local function refresh_devpod(devpod)
	return request_host(devpod, "tmux_dev_refresh_check", function()
		if not prepare_refresh() then
			return
		end
		request_host(devpod, "tmux_dev_refresh", quit_neovim)
	end)
end

local function refresh_host(pane)
	if vim.fn.executable(helper) ~= 1 then
		notify("tmux dev-session helper is not executable: " .. helper, vim.log.levels.ERROR)
		return false
	end
	return run_helper("check", pane, function()
		if not prepare_refresh() then
			return
		end
		run_helper("schedule", pane, quit_neovim)
	end)
end

function M.refresh()
	local loaded, devpod = pcall(require, "config.devpod")
	if loaded and devpod.in_workspace() then
		return refresh_devpod(devpod)
	end

	local pane = vim.env.TMUX_PANE
	if not valid_pane(pane) then
		notify("Refresh Dev Session requires a valid TMUX_PANE", vim.log.levels.ERROR)
		return false
	end
	return refresh_host(pane)
end

M._helper = helper
M._modified_buffer = modified_buffer

return M
