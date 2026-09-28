-- Host adapter for log-workbench.nvim. Commands, local configuration,
-- notifications, and window placement remain configuration concerns.
local follow = require("log_workbench.follow")
local local_config = require("config.local_config")

local M = {}

local DEFAULT_MAX_LINES = 100000
local DEFAULT_MAX_BYTES = 64 * 1024 * 1024
local DEFAULT_CONTINUITY_BYTES = 64 * 1024

local configured = false
local setup_options = {}
local suspended
local presentations = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LogWatch" })
end

local function positive_integer(value, fallback)
	value = tonumber(value)
	if not value or value < 1 then
		return fallback
	end
	return math.floor(value)
end

local function settings()
	local value = local_config.plugin("log_workbench", {
		poll_interval_ms = 500,
		max_lines = DEFAULT_MAX_LINES,
		max_bytes = DEFAULT_MAX_BYTES,
		continuity_bytes = DEFAULT_CONTINUITY_BYTES,
	})
	if type(value) ~= "table" then
		value = {}
	end
	return {
		poll_interval_ms = positive_integer(value.poll_interval_ms, 500),
		max_lines = positive_integer(value.max_lines, DEFAULT_MAX_LINES),
		max_bytes = positive_integer(value.max_bytes, DEFAULT_MAX_BYTES),
		continuity_bytes = positive_integer(value.continuity_bytes, DEFAULT_CONTINUITY_BYTES),
	}
end

function M.setup(opts)
	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	local limits = settings()
	local ok, err = follow.setup({
		max_lines = limits.max_lines,
		max_bytes = limits.max_bytes,
		continuity_bytes = limits.continuity_bytes,
		poll_interval_ms = opts.poll_interval_ms or limits.poll_interval_ms,
		uv = opts.uv,
		new_fs_poll = opts.new_fs_poll,
		new_fs_event = opts.new_fs_event,
		schedule = opts.schedule,
		notify = opts.notify or notify,
		event = opts.event,
	})
	if not ok then
		return nil, err
	end
	setup_options = opts
	configured = true
	suspended = nil
	return true
end

local function ensure_setup()
	if configured then
		return true
	end
	local ok, err = M.setup(setup_options)
	if not ok then
		notify("Could not initialize log following: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

local function source_session(buf)
	local session = follow.session(buf)
	if session then
		return session
	end
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= "" and follow.find(name) or nil
end

local function source_buffer(session)
	local metadata = session:status().metadata
	local buf = metadata and metadata.source_buf
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and buf or nil
end

local function replace_tail_windows(session)
	local source = source_buffer(session)
	if not source then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(session:buffer())) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_set_buf, win, source)
		end
	end
end

local function stop_session(session)
	if not session then
		return false
	end
	replace_tail_windows(session)
	follow.stop(session)
	return true
end

local function valid_window_for_buffer(win, buf)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
end

local function effective_width(configured_width)
	local columns = math.max(1, tonumber(vim.o.columns) or 1)
	local half = math.floor(columns / 2)
	return math.max(20, math.min(positive_integer(configured_width, 72), half))
end

local function presentation_window(session)
	local status = session:status()
	local remembered = presentations[status.path]
	if remembered and valid_window_for_buffer(remembered.winid, status.bufnr) then
		return remembered.winid
	end
	for _, win in ipairs(vim.fn.win_findbuf(status.bufnr)) do
		if valid_window_for_buffer(win, status.bufnr) then
			return win
		end
	end
	return nil
end

local function close_presentation(session, win)
	local status = session and session:status() or nil
	if valid_window_for_buffer(win, status and status.bufnr or -1) then
		local tab = vim.api.nvim_win_get_tabpage(win)
		if #vim.api.nvim_tabpage_list_wins(tab) > 1 then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	if status then
		presentations[status.path] = nil
	end
	stop_session(session)
end

local function configure_presentation(session, win, opts)
	local status = session:status()
	local buf = status.bufnr
	local title = opts.title or "Dev Container Log"
	for name, value in pairs({
		wrap = false,
		number = false,
		relativenumber = false,
		signcolumn = "no",
		winfixwidth = true,
		winbar = " " .. title,
	}) do
		pcall(vim.api.nvim_set_option_value, name, value, { win = win })
	end
	pcall(vim.api.nvim_win_set_width, win, effective_width(opts.width))
	vim.b[buf].log_watch_presenter = opts.presenter or "devcontainer-log"
	vim.keymap.set("n", "q", function()
		local session_now = follow.session(buf)
		local current = vim.api.nvim_get_current_win()
		local target = valid_window_for_buffer(current, buf) and current or presentation_window(session_now)
		close_presentation(session_now, target)
	end, { buffer = buf, nowait = true, silent = true, desc = "Close live log" })
	presentations[status.path] = { bufnr = buf, winid = win }
end

---Open or focus one live, read-only tail presentation for an absolute path.
---@param path string
---@param opts? {width?: integer, title?: string, presenter?: string}
---@return table|nil descriptor
---@return string|nil error
function M.follow_path(path, opts)
	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, "follow_path options must be a table"
	end
	if not ensure_setup() then
		return nil, "could not initialize log following"
	end
	local session = follow.find(path)
	local created = false
	if not session then
		local source_buf = vim.api.nvim_get_current_buf()
		local opened, open_err = follow.open(path, {
			metadata = {
				source_buf = source_buf,
				presenter = opts.presenter or "devcontainer-log",
				width = positive_integer(opts.width, 72),
				title = opts.title or "Dev Container Log",
			},
		})
		if not opened then
			return nil, open_err
		end
		session = opened
		created = true
	end

	local win = presentation_window(session)
	if not win then
		local split_ok, split_err = pcall(vim.cmd, "botright vsplit")
		if not split_ok then
			if created then
				follow.stop(session)
			end
			return nil, "could not open live log split: " .. tostring(split_err)
		end
		win = vim.api.nvim_get_current_win()
		local placed, place_err = pcall(vim.api.nvim_win_set_buf, win, session:buffer())
		if not placed then
			pcall(vim.api.nvim_win_close, win, true)
			if created then
				follow.stop(session)
			end
			return nil, "could not place live log buffer: " .. tostring(place_err)
		end
	else
		local focused, focus_err = pcall(vim.api.nvim_set_current_win, win)
		if not focused then
			return nil, "could not focus live log split: " .. tostring(focus_err)
		end
	end
	configure_presentation(session, win, opts)
	return { bufnr = session:buffer(), winid = win, path = session:path() }
end

local function start(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" or vim.bo[buf].buftype ~= "" then
		notify("Current buffer is not backed by a file", vim.log.levels.ERROR)
		return false
	end
	if vim.fn.filereadable(name) ~= 1 then
		notify("File is not readable: " .. name, vim.log.levels.ERROR)
		return false
	end
	if vim.bo[buf].modified then
		notify("Buffer has unsaved changes; save or discard them before following", vim.log.levels.ERROR)
		return false
	end
	if follow.find(name) then
		notify("Already following this file")
		return false
	end
	local session, err = follow.open(name, { metadata = { source_buf = buf } })
	if not session then
		notify("Could not follow file: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	local placed, place_err = pcall(vim.api.nvim_win_set_buf, vim.api.nvim_get_current_win(), session:buffer())
	if not placed then
		follow.stop(session)
		notify("Could not open followed buffer: " .. tostring(place_err), vim.log.levels.ERROR)
		return false
	end
	notify("Following " .. vim.fn.fnamemodify(name, ":t") .. " (read-only)")
	return true
end

function M.command(opts)
	if not ensure_setup() then
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	local session = source_session(buf)
	local arg = vim.trim((opts.args or "")):lower()
	if arg == "" then
		if session then
			stop_session(session)
			notify("Stopped following")
		else
			start(buf)
		end
		return
	end
	if arg == "on" then
		if session then
			notify("Already following this file")
		else
			start(buf)
		end
	elseif arg == "off" then
		if session then
			stop_session(session)
			notify("Stopped following")
		else
			notify("This file is not being followed", vim.log.levels.WARN)
		end
	elseif arg == "pause" then
		if session and follow.pause(session) then
			notify("Paused log following")
		else
			notify("This file is not actively being followed", vim.log.levels.WARN)
		end
	elseif arg == "resume" then
		if session then
			local resumed, resume_err = follow.resume(session)
			if resumed then
				notify("Resumed log following")
			elseif resume_err then
				notify("Could not resume log following: " .. tostring(resume_err), vim.log.levels.ERROR)
			else
				notify("Log following is not paused", vim.log.levels.WARN)
			end
		else
			notify("This file is not being followed", vim.log.levels.WARN)
		end
	else
		notify("Argument must be 'on', 'off', 'pause', or 'resume'", vim.log.levels.ERROR)
	end
end

function M.complete()
	return { "on", "off", "pause", "resume" }
end

-- Temporarily replace ephemeral tail windows with their ordinary source
-- buffers. auto-session invokes this synchronously before :mksession.
function M.suspend_for_session()
	if not configured or #follow.status() == 0 then
		return true
	end
	if suspended then
		return nil, "log following is already suspended"
	end
	suspended = {}
	local sessions = {}
	for _, item in ipairs(follow.status()) do
		local session = follow.session(item.bufnr)
		if session then
			sessions[#sessions + 1] = session
		end
	end
	for _, session in ipairs(sessions) do
		local status = session:status()
		local windows = vim.fn.win_findbuf(status.bufnr)
		suspended[#suspended + 1] = {
			path = status.path,
			metadata = status.metadata,
			max_lines = status.max_lines,
			max_bytes = status.max_bytes,
			windows = windows,
		}
		stop_session(session)
	end
	return true
end

function M.restore_after_session()
	if not suspended then
		return true
	end
	local descriptors = suspended
	suspended = nil
	local restored = true
	for _, descriptor in ipairs(descriptors) do
		local session, err = follow.open(descriptor.path, {
			metadata = descriptor.metadata,
			max_lines = descriptor.max_lines,
			max_bytes = descriptor.max_bytes,
		})
		if not session then
			restored = false
			notify("Could not restore log following: " .. tostring(err), vim.log.levels.ERROR)
		else
			local source = source_buffer(session)
			for _, win in ipairs(descriptor.windows) do
				if vim.api.nvim_win_is_valid(win) and (not source or vim.api.nvim_win_get_buf(win) == source) then
					pcall(vim.api.nvim_win_set_buf, win, session:buffer())
					if descriptor.metadata and descriptor.metadata.presenter == "devcontainer-log" then
						configure_presentation(session, win, {
							presenter = descriptor.metadata.presenter,
							width = descriptor.metadata.width,
							title = descriptor.metadata.title,
						})
					end
				end
			end
		end
	end
	return restored, restored and nil or "one or more tails could not be restored"
end

function M.status()
	return follow.status()
end

function M.teardown()
	follow.teardown()
	configured = false
	suspended = nil
	presentations = {}
end

return M
