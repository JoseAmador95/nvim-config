local M = {}

local uv = vim.uv

local watchers = {}

local POLL_INTERVAL_MS = 500
local DEFAULT_MAX_LINES = 100000
local DEFAULT_MAX_BYTES = 64 * 1024 * 1024

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "LogWatch" })
end

local function positive_integer(value, fallback)
	value = tonumber(value)
	if not value or value < 1 then
		return fallback
	end
	return math.floor(value)
end

local function settings()
	local configured = require("config.local_config").get("log_watch", {})
	if type(configured) ~= "table" then
		configured = {}
	end
	return {
		max_lines = positive_integer(configured.max_lines, DEFAULT_MAX_LINES),
		max_bytes = positive_integer(configured.max_bytes, DEFAULT_MAX_BYTES),
	}
end

local function is_watching(buf)
	return watchers[buf] ~= nil
end

local function live(watcher)
	return watchers[watcher.buf] == watcher and vim.api.nvim_buf_is_valid(watcher.buf)
end

local function file_identity(stat)
	if not stat then
		return nil
	end
	return tostring(stat.dev or "") .. ":" .. tostring(stat.ino or "")
end

local function time_identity(value)
	if type(value) == "table" then
		return tostring(value.sec or "") .. ":" .. tostring(value.nsec or "")
	end
	return tostring(value or "")
end

local function mtime_identity(stat)
	return stat and time_identity(stat.mtime) or nil
end

local function restore_buffer(watcher)
	local buf = watcher.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local original = watcher.original
	vim.bo[buf].filetype = original.filetype
	vim.bo[buf].modifiable = original.modifiable
	vim.bo[buf].readonly = original.readonly
	vim.bo[buf].modified = original.modified
end

local function close_handle(handle)
	if not handle then
		return
	end
	pcall(handle.stop, handle)
	local ok, closing = pcall(handle.is_closing, handle)
	if not ok or not closing then
		pcall(handle.close, handle)
	end
end

local function close_fd(watcher)
	local fd = watcher.fd
	watcher.fd = nil
	if fd then
		pcall(uv.fs_close, fd)
	end
end

local function tail_windows(buf, pin_all)
	local out = {}
	local old_count = vim.api.nvim_buf_line_count(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
		if ok then
			out[#out + 1] = { win = win, tail = pin_all or cursor[1] >= old_count }
		end
	end
	return out
end

local function mutate_buffer(watcher, callback)
	if not live(watcher) then
		return false
	end
	local buf = watcher.buf
	local windows = tail_windows(buf, watcher.pin_all_once)
	watcher.pin_all_once = false

	local ok, err = pcall(function()
		vim.bo[buf].modifiable = true
		vim.bo[buf].readonly = false
		callback()
	end)
	if vim.api.nvim_buf_is_valid(buf) and watchers[buf] == watcher then
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].modified = false
		local new_count = vim.api.nvim_buf_line_count(buf)
		for _, item in ipairs(windows) do
			if item.tail and vim.api.nvim_win_is_valid(item.win) and vim.api.nvim_win_get_buf(item.win) == buf then
				pcall(vim.api.nvim_win_set_cursor, item.win, { new_count, 0 })
			end
		end
	end
	if not ok then
		watcher.force_reload = true
		notify("Could not update followed buffer: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

-- Split a byte chunk into newline-terminated lines plus an optional trailing
-- partial line. A partial is kept separately so the next append updates that
-- buffer line instead of duplicating it.
local function split_chunk(prefix, chunk)
	local text = (prefix or "") .. chunk
	local complete = {}
	local start = 1
	while true do
		local newline = text:find("\n", start, true)
		if not newline then
			break
		end
		complete[#complete + 1] = text:sub(start, newline - 1)
		start = newline + 1
	end
	local partial = start <= #text and text:sub(start) or nil
	return complete, partial
end

local function recalculate_bytes(watcher)
	local total = 0
	for _, size in ipairs(watcher.sizes) do
		total = total + size
	end
	watcher.buffer_bytes = total
	return total
end

local function enforce_bounds(watcher)
	local sizes = watcher.sizes
	local total = recalculate_bytes(watcher)
	local drop = 0
	while #sizes - drop > watcher.max_lines or (total > watcher.max_bytes and #sizes - drop > 1) do
		drop = drop + 1
		total = total - sizes[drop]
	end
	if drop > 0 then
		vim.api.nvim_buf_set_lines(watcher.buf, 0, drop, false, {})
		local remaining = {}
		for index = drop + 1, #sizes do
			remaining[#remaining + 1] = sizes[index]
		end
		watcher.sizes = remaining
		sizes = remaining
	end

	-- A single unterminated or exceptionally long line can exceed the byte
	-- ceiling by itself. Keep its newest suffix so memory remains bounded.
	if total > watcher.max_bytes and #sizes == 1 then
		local lines = vim.api.nvim_buf_get_lines(watcher.buf, 0, 1, false)
		local line = lines[1] or ""
		local is_partial = watcher.partial ~= nil
		local newline_bytes = is_partial and 0 or 1
		local keep = math.max(0, watcher.max_bytes - newline_bytes)
		if #line > keep then
			line = keep == 0 and "" or line:sub(#line - keep + 1)
			vim.api.nvim_buf_set_lines(watcher.buf, 0, 1, false, { line })
			if is_partial then
				watcher.partial = line
			end
		end
		sizes[1] = #line + newline_bytes
		total = sizes[1]
	end
	watcher.buffer_bytes = total
end

local function apply_reload(watcher, data)
	local complete, partial = split_chunk(nil, data)
	local lines = {}
	local sizes = {}
	for _, line in ipairs(complete) do
		lines[#lines + 1] = line
		sizes[#sizes + 1] = #line + 1
	end
	if partial ~= nil then
		lines[#lines + 1] = partial
		sizes[#sizes + 1] = #partial
	end

	watcher.partial = partial
	watcher.sizes = sizes
	return mutate_buffer(watcher, function()
		vim.api.nvim_buf_set_lines(watcher.buf, 0, -1, false, #lines > 0 and lines or { "" })
		enforce_bounds(watcher)
	end)
end

local function append_data(watcher, data)
	if data == "" then
		return true
	end
	local old_partial = watcher.partial
	local complete, partial = split_chunk(old_partial, data)

	return mutate_buffer(watcher, function()
		local sizes = watcher.sizes
		local additions = {}
		local addition_sizes = {}
		local first_complete = 1

		if old_partial ~= nil then
			local last = #sizes - 1
			if #complete > 0 then
				vim.api.nvim_buf_set_lines(watcher.buf, last, last + 1, false, { complete[1] })
				sizes[#sizes] = #complete[1] + 1
				first_complete = 2
			elseif partial ~= nil then
				vim.api.nvim_buf_set_lines(watcher.buf, last, last + 1, false, { partial })
				sizes[#sizes] = #partial
			end
		end

		for index = first_complete, #complete do
			additions[#additions + 1] = complete[index]
			addition_sizes[#addition_sizes + 1] = #complete[index] + 1
		end
		if partial ~= nil and (#complete > 0 or old_partial == nil) then
			additions[#additions + 1] = partial
			addition_sizes[#addition_sizes + 1] = #partial
		end

		if #additions > 0 then
			if #sizes == 0 then
				vim.api.nvim_buf_set_lines(watcher.buf, 0, -1, false, additions)
			else
				vim.api.nvim_buf_set_lines(watcher.buf, -1, -1, false, additions)
			end
			vim.list_extend(sizes, addition_sizes)
		end

		watcher.partial = partial
		enforce_bounds(watcher)
	end)
end

local request_refresh

local function finish_refresh(watcher)
	close_fd(watcher)
	if not live(watcher) then
		return
	end
	watcher.busy = false
	if watcher.pending then
		local force = watcher.pending_force
		watcher.pending = false
		watcher.pending_force = false
		request_refresh(watcher, force)
	end
end

local function read_file(watcher, stat, reload)
	local target_size = stat.size or 0
	local logical_start = reload and math.max(0, target_size - watcher.max_bytes) or watcher.offset
	local read_start = reload and logical_start > 0 and logical_start - 1 or logical_start
	local length = math.max(0, target_size - read_start)

	if length == 0 then
		if reload then
			apply_reload(watcher, "")
		end
		watcher.offset = 0
		watcher.identity = file_identity(stat)
		watcher.mtime = mtime_identity(stat)
		watcher.missing = false
		finish_refresh(watcher)
		return
	end

	local ok, read_request, read_err = pcall(
		uv.fs_read,
		watcher.fd,
		length,
		read_start,
		vim.schedule_wrap(function(err, raw)
			if not live(watcher) then
				close_fd(watcher)
				return
			end
			if err then
				notify("Could not read followed file: " .. tostring(err), vim.log.levels.ERROR)
				finish_refresh(watcher)
				return
			end

			raw = raw or ""
			local applied = true
			if reload then
				local content = raw
				if logical_start > 0 then
					local preceding = content:sub(1, 1)
					content = content:sub(2)
					if preceding ~= "\n" then
						local newline = content:find("\n", 1, true)
						if newline then
							content = content:sub(newline + 1)
						end
					end
				end
				applied = apply_reload(watcher, content)
			else
				applied = append_data(watcher, raw)
			end

			if applied then
				watcher.offset = read_start + #raw
				watcher.identity = file_identity(stat)
				watcher.mtime = mtime_identity(stat)
				watcher.missing = false
			end
			if #raw < length then
				watcher.pending = true
				watcher.pending_force = true
			end
			finish_refresh(watcher)
		end)
	)
	if not ok or read_request == nil then
		local reason = ok and read_err or read_request
		notify("Could not start followed-file read: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(watcher)
	end
end

local function inspect_open_file(watcher, force_reload)
	local ok, stat_request, stat_err = pcall(
		uv.fs_fstat,
		watcher.fd,
		vim.schedule_wrap(function(err, stat)
			if not live(watcher) then
				close_fd(watcher)
				return
			end
			if err or not stat then
				notify("Could not inspect followed file: " .. tostring(err), vim.log.levels.ERROR)
				finish_refresh(watcher)
				return
			end

			local identity = file_identity(stat)
			local mtime = mtime_identity(stat)
			local size = stat.size or 0
			local reload = force_reload
				or watcher.missing
				or watcher.identity == nil
				or watcher.identity ~= identity
				or size < watcher.offset
				or (size == watcher.offset and watcher.mtime ~= nil and watcher.mtime ~= mtime)
				or size - watcher.offset > watcher.max_bytes

			if not reload and size == watcher.offset then
				watcher.mtime = mtime
				watcher.missing = false
				finish_refresh(watcher)
				return
			end
			read_file(watcher, stat, reload)
		end)
	)
	if not ok or stat_request == nil then
		local reason = ok and stat_err or stat_request
		notify("Could not start followed-file inspection: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(watcher)
	end
end

request_refresh = function(watcher, force_reload)
	if not live(watcher) then
		return
	end
	force_reload = force_reload or watcher.force_reload or false
	if watcher.busy then
		watcher.pending = true
		watcher.pending_force = watcher.pending_force or force_reload
		return
	end

	watcher.force_reload = false
	watcher.busy = true
	local ok, open_request, open_err = pcall(
		uv.fs_open,
		watcher.name,
		"r",
		0,
		vim.schedule_wrap(function(err, fd)
			if not live(watcher) then
				if fd then
					pcall(uv.fs_close, fd)
				end
				return
			end
			if err or not fd then
				if tostring(err):find("ENOENT", 1, true) then
					watcher.missing = true
				else
					notify("Could not open followed file: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish_refresh(watcher)
				return
			end
			watcher.fd = fd
			inspect_open_file(watcher, force_reload)
		end)
	)
	if not ok or open_request == nil then
		local reason = ok and open_err or open_request
		notify("Could not start followed-file open: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(watcher)
	end
end

local function stop(buf, restore)
	local watcher = watchers[buf]
	if not watcher then
		return
	end

	-- Drop ownership first: scheduled poll/open/read callbacks can only clean up
	-- their own handles after this point and may not touch the buffer.
	watchers[buf] = nil
	if watcher.autocmd then
		pcall(vim.api.nvim_del_autocmd, watcher.autocmd)
		watcher.autocmd = nil
	end
	close_handle(watcher.poll)
	close_fd(watcher)

	if restore ~= false then
		restore_buffer(watcher)
	end
end

local function start(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
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

	local poll, poll_err = uv.new_fs_poll()
	if not poll then
		notify("Could not create file watcher: " .. tostring(poll_err), vim.log.levels.ERROR)
		return false
	end

	local limits = settings()
	local watcher = {
		buf = buf,
		poll = poll,
		name = name,
		max_lines = limits.max_lines,
		max_bytes = limits.max_bytes,
		offset = 0,
		sizes = {},
		buffer_bytes = 0,
		busy = false,
		pending = false,
		pending_force = false,
		missing = false,
		pin_all_once = true,
		original = {
			filetype = vim.bo[buf].filetype,
			modifiable = vim.bo[buf].modifiable,
			readonly = vim.bo[buf].readonly,
			modified = vim.bo[buf].modified,
		},
	}
	watchers[buf] = watcher

	local started_ok, start_result, start_err = pcall(
		poll.start,
		poll,
		name,
		POLL_INTERVAL_MS,
		vim.schedule_wrap(function(_, previous, current)
			if not live(watcher) then
				return
			end
			local force = watcher.missing
				or (previous and current and file_identity(previous) ~= file_identity(current))
				or (current and (current.size or 0) < watcher.offset)
			request_refresh(watcher, force)
		end)
	)
	if not started_ok or start_result == nil then
		watchers[buf] = nil
		close_handle(poll)
		local reason = started_ok and (start_err or "unknown error") or start_result
		notify("Could not start file watcher: " .. tostring(reason), vim.log.levels.ERROR)
		return false
	end

	local configured, config_err = pcall(function()
		if vim.bo[buf].filetype ~= "log" then
			vim.bo[buf].filetype = "log"
		end
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
		vim.bo[buf].modified = false
	end)
	if not configured then
		stop(buf)
		notify("Could not configure buffer for following: " .. tostring(config_err), vim.log.levels.ERROR)
		return false
	end

	watcher.autocmd = vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		buffer = buf,
		once = true,
		callback = function()
			watcher.autocmd = nil
			if watchers[buf] == watcher then
				stop(buf, false)
			end
		end,
	})

	request_refresh(watcher, true)
	notify("Following " .. vim.fn.fnamemodify(name, ":t") .. " (read-only)")
	return true
end

function M.command(opts)
	local buf = vim.api.nvim_get_current_buf()
	local arg = vim.trim((opts.args or "")):lower()

	if arg == "" then
		if is_watching(buf) then
			stop(buf)
			notify("Stopped following")
		else
			start(buf)
		end
		return
	end

	if arg == "on" then
		if is_watching(buf) then
			notify("Already following this buffer")
			return
		end
		start(buf)
	elseif arg == "off" then
		if is_watching(buf) then
			stop(buf)
			notify("Stopped following")
		else
			notify("This buffer is not being followed", vim.log.levels.WARN)
		end
	else
		notify("Argument must be 'on' or 'off'", vim.log.levels.ERROR)
	end
end

function M.complete()
	return { "on", "off" }
end

return M
