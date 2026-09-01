local decoder = require("log_workbench.decoder")

local M = {}

local DEFAULT_POLL_INTERVAL_MS = 500
local DEFAULT_MAX_LINES = 100000
local DEFAULT_MAX_BYTES = 64 * 1024 * 1024

local state = {
	configured = false,
	options = nil,
	sessions_by_buf = {},
	sessions_by_source = {},
	next_id = 0,
}

local Session = {}
Session.__index = Session
local start_poll
local start_fs_event

local function positive_integer(value, fallback, label)
	if value == nil then
		return fallback
	end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 or value ~= value or value == math.huge then
		return nil, label .. " must be a positive integer"
	end
	return value
end

local function copy(value)
	return vim.deepcopy(value)
end

local function notify(message, level)
	if state.options and state.options.notify then
		pcall(state.options.notify, message, level)
	end
end

local function session_error(session, message, level)
	session.error = tostring(message)
	session.health = level == vim.log.levels.WARN and "degraded" or "error"
	notify(message, level)
end

local function emit(kind, session, extra)
	if not state.options or not state.options.event then
		return
	end
	local event = copy(extra or {})
	event.kind = kind
	event.id = session.id
	event.bufnr = session.buf
	event.path = session.source_path
	event.state = session.state
	pcall(state.options.event, event)
end

local function schedule_call(session, callback)
	return function(...)
		local count = select("#", ...)
		local arguments = { ... }
		session.options.schedule(function()
			callback(unpack(arguments, 1, count))
		end)
	end
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

local function close_fd(session)
	local fd = session.fd
	session.fd = nil
	if fd then
		pcall(session.options.uv.fs_close, fd)
	end
end

local function live(session)
	return not session.closed
		and state.sessions_by_buf[session.buf] == session
		and vim.api.nvim_buf_is_valid(session.buf)
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

local function tail_windows(buf, pin_all)
	local windows = {}
	local old_count = vim.api.nvim_buf_line_count(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
		if ok then
			windows[#windows + 1] = { win = win, tail = pin_all or cursor[1] >= old_count }
		end
	end
	return windows
end

local function mutate_buffer(session, callback)
	if not live(session) then
		return false
	end
	local windows = tail_windows(session.buf, session.pin_all_once)
	session.pin_all_once = false
	local ok, err = pcall(function()
		vim.bo[session.buf].modifiable = true
		vim.bo[session.buf].readonly = false
		callback()
	end)
	if live(session) then
		vim.bo[session.buf].modifiable = false
		vim.bo[session.buf].readonly = true
		vim.bo[session.buf].modified = false
		local line_count = vim.api.nvim_buf_line_count(session.buf)
		for _, item in ipairs(windows) do
			if
				item.tail
				and vim.api.nvim_win_is_valid(item.win)
				and vim.api.nvim_win_get_buf(item.win) == session.buf
			then
				pcall(vim.api.nvim_win_set_cursor, item.win, { line_count, 0 })
			end
		end
	end
	if not ok then
		session.force_reload = true
		notify("Could not update followed buffer: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

local function split_chunk(prefix, chunk)
	local text = (prefix or "") .. chunk
	local complete = {}
	local first = 1
	while true do
		local newline = text:find("\n", first, true)
		if not newline then
			break
		end
		complete[#complete + 1] = text:sub(first, newline - 1)
		first = newline + 1
	end
	local partial = first <= #text and text:sub(first) or nil
	return complete, partial
end

local function enforce_bounds(session)
	local total = 0
	for _, size in ipairs(session.sizes) do
		total = total + size
	end
	local drop = 0
	while #session.sizes - drop > session.max_lines or (total > session.max_bytes and #session.sizes - drop > 1) do
		drop = drop + 1
		total = total - session.sizes[drop]
	end
	if drop > 0 then
		local dropped_bytes = 0
		for index = 1, drop do
			dropped_bytes = dropped_bytes + session.sizes[index]
		end
		session.dropped.lines = session.dropped.lines + drop
		session.dropped.bytes = session.dropped.bytes + dropped_bytes
		vim.api.nvim_buf_set_lines(session.buf, 0, drop, false, {})
		local remaining = {}
		for index = drop + 1, #session.sizes do
			remaining[#remaining + 1] = session.sizes[index]
		end
		session.sizes = remaining
	end

	if total > session.max_bytes and #session.sizes == 1 then
		local line = vim.api.nvim_buf_get_lines(session.buf, 0, 1, false)[1] or ""
		local previous_size = session.sizes[1]
		local newline_bytes = session.partial_text ~= nil and 0 or 1
		local keep = math.max(0, session.max_bytes - newline_bytes)
		line = assert(decoder.suffix(line, keep))
		vim.api.nvim_buf_set_lines(session.buf, 0, 1, false, { line })
		if session.partial_text ~= nil then
			session.partial_text = line
		end
		session.sizes[1] = #line + newline_bytes
		session.dropped.bytes = session.dropped.bytes + math.max(0, previous_size - session.sizes[1])
		total = session.sizes[1]
	end
	session.buffer_bytes = total
end

local function apply_reload(session, raw)
	local decoded, carry, decode_err = decoder.feed("", raw)
	if not decoded then
		notify("Could not decode followed file: " .. tostring(decode_err), vim.log.levels.ERROR)
		return false
	end
	local complete, partial = split_chunk(nil, decoded)
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
	session.decode_carry = carry
	session.partial_text = partial
	session.sizes = sizes
	return mutate_buffer(session, function()
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, #lines > 0 and lines or { "" })
		enforce_bounds(session)
	end)
end

local function append_data(session, raw)
	if raw == "" then
		return true
	end
	local decoded, carry, decode_err = decoder.feed(session.decode_carry, raw)
	if not decoded then
		notify("Could not decode followed file: " .. tostring(decode_err), vim.log.levels.ERROR)
		return false
	end
	session.decode_carry = carry
	if decoded == "" then
		return true
	end
	local old_partial = session.partial_text
	local complete, partial = split_chunk(old_partial, decoded)
	return mutate_buffer(session, function()
		local additions = {}
		local addition_sizes = {}
		local first_complete = 1
		if old_partial ~= nil then
			local last = #session.sizes - 1
			if #complete > 0 then
				vim.api.nvim_buf_set_lines(session.buf, last, last + 1, false, { complete[1] })
				session.sizes[#session.sizes] = #complete[1] + 1
				first_complete = 2
			elseif partial ~= nil then
				vim.api.nvim_buf_set_lines(session.buf, last, last + 1, false, { partial })
				session.sizes[#session.sizes] = #partial
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
			if #session.sizes == 0 then
				vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, additions)
			else
				vim.api.nvim_buf_set_lines(session.buf, -1, -1, false, additions)
			end
			vim.list_extend(session.sizes, addition_sizes)
		end
		session.partial_text = partial
		enforce_bounds(session)
	end)
end

local function update_continuity(session, raw, reload)
	local existing = reload and "" or session.continuity
	local combined = (existing or "") .. raw
	local limit = session.max_bytes
	if #combined > limit then
		combined = combined:sub(#combined - limit + 1)
	end
	session.continuity = combined
end

local request_refresh

local function finish_refresh(session)
	close_fd(session)
	if not live(session) then
		return
	end
	session.busy = false
	if session.pending then
		local force = session.pending_force
		session.pending = false
		session.pending_force = false
		request_refresh(session, force)
	end
end

local function read_file(session, stat, reload)
	local target_size = stat.size or 0
	local logical_start = reload and math.max(0, target_size - session.max_bytes) or session.offset
	local read_start = reload and logical_start > 0 and logical_start - 1 or logical_start
	local length = math.max(0, target_size - read_start)
	if length == 0 then
		if reload then
			apply_reload(session, "")
		end
		session.offset = 0
		session.continuity = ""
		session.identity = file_identity(stat)
		session.mtime = mtime_identity(stat)
		session.missing = false
		session.state = "following"
		finish_refresh(session)
		return
	end

	local ok, request, request_err = pcall(
		session.options.uv.fs_read,
		session.fd,
		length,
		read_start,
		schedule_call(session, function(err, raw)
			if not live(session) then
				close_fd(session)
				return
			end
			if err then
				session_error(session, "Could not read followed file: " .. tostring(err), vim.log.levels.ERROR)
				finish_refresh(session)
				return
			end
			raw = raw or ""
			local applied
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
				applied = apply_reload(session, content)
			else
				applied = append_data(session, raw)
			end
			if applied then
				update_continuity(session, raw, reload)
				session.offset = read_start + #raw
				session.identity = file_identity(stat)
				session.mtime = mtime_identity(stat)
				session.missing = false
				session.state = "following"
				session.error = nil
				session.health = session.watcher_error and "degraded" or "healthy"
				emit(reload and "reload" or "append", session, { bytes = #raw })
			end
			if #raw < length then
				session.pending = true
				session.pending_force = true
			end
			finish_refresh(session)
		end)
	)
	if not ok or request == nil then
		local reason = ok and request_err or request
		session_error(session, "Could not start followed-file read: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(session)
	end
end

local function verify_append_continuity(session, stat)
	local expected = session.continuity or ""
	if session.offset == 0 then
		read_file(session, stat, false)
		return
	end
	if expected == "" then
		read_file(session, stat, true)
		return
	end

	local length = math.min(#expected, session.offset)
	local expected_suffix = expected:sub(#expected - length + 1)
	local read_start = session.offset - length
	local ok, request, request_err = pcall(
		session.options.uv.fs_read,
		session.fd,
		length,
		read_start,
		schedule_call(session, function(err, raw)
			if not live(session) then
				close_fd(session)
				return
			end
			if err then
				session_error(
					session,
					"Could not verify followed-file continuity: " .. tostring(err),
					vim.log.levels.ERROR
				)
				finish_refresh(session)
				return
			end
			read_file(session, stat, (raw or "") ~= expected_suffix)
		end)
	)
	if not ok or request == nil then
		local reason = ok and request_err or request
		session_error(
			session,
			"Could not start followed-file continuity check: " .. tostring(reason),
			vim.log.levels.ERROR
		)
		finish_refresh(session)
	end
end

local function inspect_open_file(session, force_reload)
	local ok, request, request_err = pcall(
		session.options.uv.fs_fstat,
		session.fd,
		schedule_call(session, function(err, stat)
			if not live(session) then
				close_fd(session)
				return
			end
			if err or not stat or stat.type ~= "file" then
				session_error(
					session,
					"Could not inspect followed file: " .. tostring(err or "not a regular file"),
					vim.log.levels.ERROR
				)
				finish_refresh(session)
				return
			end
			local identity = file_identity(stat)
			local mtime = mtime_identity(stat)
			local size = stat.size or 0
			local reload = force_reload
				or session.missing
				or session.identity == nil
				or session.identity ~= identity
				or size < session.offset
				or (size == session.offset and session.mtime ~= nil and session.mtime ~= mtime)
				or size - session.offset > session.max_bytes
			if not reload and size == session.offset then
				session.mtime = mtime
				session.missing = false
				session.state = "following"
				finish_refresh(session)
				return
			end
			if reload then
				read_file(session, stat, true)
			else
				verify_append_continuity(session, stat)
			end
		end)
	)
	if not ok or request == nil then
		local reason = ok and request_err or request
		session_error(session, "Could not start followed-file inspection: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(session)
	end
end

request_refresh = function(session, force_reload)
	if not live(session) or session.paused then
		if live(session) and session.paused then
			session.dropped.events = session.dropped.events + 1
		end
		return false
	end
	force_reload = force_reload or session.force_reload or false
	if session.busy then
		session.dropped.events = session.dropped.events + 1
		session.pending = true
		session.pending_force = session.pending_force or force_reload
		return true
	end
	session.force_reload = false
	session.busy = true
	local ok, request, request_err = pcall(
		session.options.uv.fs_open,
		session.source_path,
		"r",
		0,
		schedule_call(session, function(err, fd)
			if not live(session) then
				if fd then
					pcall(session.options.uv.fs_close, fd)
				end
				return
			end
			if err or not fd then
				if tostring(err):find("ENOENT", 1, true) then
					session.missing = true
					session.state = "missing"
					emit("missing", session)
				else
					session_error(session, "Could not open followed file: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish_refresh(session)
				return
			end
			session.fd = fd
			inspect_open_file(session, force_reload)
		end)
	)
	if not ok or request == nil then
		local reason = ok and request_err or request
		session_error(session, "Could not start followed-file open: " .. tostring(reason), vim.log.levels.ERROR)
		finish_refresh(session)
		return false
	end
	return true
end

local function close_buffer(session)
	if vim.api.nvim_buf_is_valid(session.buf) then
		vim.bo[session.buf].modified = false
		pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
	end
end

function Session:stop(options)
	if self.closed then
		return false
	end
	options = options or {}
	self.closed = true
	self.state = "stopped"
	state.sessions_by_buf[self.buf] = nil
	state.sessions_by_source[self.source_path] = nil
	if self.autocmd then
		pcall(vim.api.nvim_del_autocmd, self.autocmd)
		self.autocmd = nil
	end
	close_handle(self.poll)
	close_handle(self.fs_event)
	self.poll = nil
	self.fs_event = nil
	close_fd(self)
	emit("stopped", self)
	if options.wipe ~= false then
		close_buffer(self)
	end
	return true
end

function Session:refresh(force_reload)
	return request_refresh(self, force_reload == true)
end

function Session:pause()
	if self.closed or self.paused then
		return false
	end
	self.paused = true
	self.state = "paused"
	close_handle(self.poll)
	close_handle(self.fs_event)
	self.poll = nil
	self.fs_event = nil
	emit("paused", self)
	return true
end

function Session:resume()
	if self.closed or not self.paused then
		return false
	end
	self.paused = false
	self.state = "starting"
	local poll_ok, poll_err = start_poll(self)
	if not poll_ok then
		self.paused = true
		self.state = "paused"
		session_error(self, poll_err, vim.log.levels.ERROR)
		return nil, poll_err
	end
	start_fs_event(self)
	emit("resumed", self)
	request_refresh(self, true)
	return true
end

function Session:buffer()
	return self.buf
end

function Session:path()
	return self.source_path
end

function Session:status()
	return {
		id = self.id,
		bufnr = self.buf,
		path = self.source_path,
		state = self.state,
		offset = self.offset,
		buffer_bytes = self.buffer_bytes,
		max_lines = self.max_lines,
		max_bytes = self.max_bytes,
		missing = self.missing,
		paused = self.paused,
		health = self.paused and "paused" or self.health,
		dropped = copy(self.dropped),
		error = self.error,
		metadata = copy(self.metadata),
	}
end

local function create_tail_buffer(path, id)
	local buf = vim.api.nvim_create_buf(false, true)
	local ok, err = pcall(vim.api.nvim_buf_set_name, buf, "tail://" .. path)
	if not ok then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		return nil, err
	end
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buflisted = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = false
	vim.bo[buf].filetype = "log"
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modified = false
	vim.b[buf].log_workbench_follow = { id = id, path = path, ephemeral = true }
	return buf
end

start_poll = function(session)
	local poll, poll_err = session.options.new_fs_poll()
	if not poll then
		return nil, "could not create polling watcher: " .. tostring(poll_err)
	end
	local ok, result, start_err = pcall(
		poll.start,
		poll,
		session.source_path,
		session.options.poll_interval_ms,
		schedule_call(session, function(err, previous, current)
			if not live(session) then
				return
			end
			if err then
				session.watcher_error = "Follow poll failed: " .. tostring(err)
				session_error(session, session.watcher_error, vim.log.levels.WARN)
			end
			local force = session.missing
				or (previous and current and file_identity(previous) ~= file_identity(current))
				or (current and (current.size or 0) < session.offset)
			request_refresh(session, force)
		end)
	)
	if not ok or result == nil then
		close_handle(poll)
		return nil, "could not start polling watcher: " .. tostring(ok and start_err or result)
	end
	session.poll = poll
	return true
end

start_fs_event = function(session)
	local handle, handle_err = session.options.new_fs_event()
	if not handle then
		session.watcher_error = "Could not create event watcher: " .. tostring(handle_err)
		session_error(session, session.watcher_error, vim.log.levels.WARN)
		return
	end
	local directory = vim.fs.dirname(session.source_path)
	local basename = vim.fs.basename(session.source_path)
	local ok, result, start_err = pcall(
		handle.start,
		handle,
		directory,
		{},
		schedule_call(session, function(err, filename, events)
			if not live(session) or (filename and filename ~= "" and vim.fs.basename(filename) ~= basename) then
				return
			end
			if err then
				session.watcher_error = "Follow event watcher failed: " .. tostring(err)
				session_error(session, session.watcher_error, vim.log.levels.WARN)
			end
			local known = type(events) == "table" and (events.change == true or events.rename == true)
			local force = err ~= nil
				or filename == nil
				or filename == ""
				or not known
				or (type(events) == "table" and events.rename == true)
			request_refresh(session, force)
		end)
	)
	if not ok or result == nil then
		close_handle(handle)
		session.watcher_error = "Could not start event watcher: " .. tostring(ok and start_err or result)
		session_error(session, session.watcher_error, vim.log.levels.WARN)
		return
	end
	session.fs_event = handle
end

function M.setup(opts)
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "setup options must be an object"
	end
	local allowed = {
		uv = true,
		notify = true,
		event = true,
		schedule = true,
		new_fs_poll = true,
		new_fs_event = true,
		poll_interval_ms = true,
		max_lines = true,
		max_bytes = true,
	}
	for key in pairs(opts) do
		if not allowed[key] then
			return nil, "setup contains an unknown option: " .. tostring(key)
		end
	end
	for _, name in ipairs({ "notify", "event", "schedule", "new_fs_poll", "new_fs_event" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			return nil, ("setup.%s must be a function"):format(name)
		end
	end
	if opts.uv ~= nil and type(opts.uv) ~= "table" then
		return nil, "setup.uv must be a table"
	end
	local uv = opts.uv or vim.uv
	for _, name in ipairs({ "fs_stat", "fs_open", "fs_fstat", "fs_read", "fs_close" }) do
		if type(uv[name]) ~= "function" then
			return nil, ("setup.uv.%s must be a function"):format(name)
		end
	end
	local new_fs_poll = opts.new_fs_poll or uv.new_fs_poll
	local new_fs_event = opts.new_fs_event or uv.new_fs_event
	if type(new_fs_poll) ~= "function" or type(new_fs_event) ~= "function" then
		return nil, "setup requires fs_poll and fs_event factories"
	end
	local poll_interval_ms, poll_err =
		positive_integer(opts.poll_interval_ms, DEFAULT_POLL_INTERVAL_MS, "setup.poll_interval_ms")
	if not poll_interval_ms then
		return nil, poll_err
	end
	local max_lines, lines_err = positive_integer(opts.max_lines, DEFAULT_MAX_LINES, "setup.max_lines")
	if not max_lines then
		return nil, lines_err
	end
	local max_bytes, bytes_err = positive_integer(opts.max_bytes, DEFAULT_MAX_BYTES, "setup.max_bytes")
	if not max_bytes then
		return nil, bytes_err
	end
	local sessions = {}
	for _, session in pairs(state.sessions_by_buf) do
		sessions[#sessions + 1] = session
	end
	for _, session in ipairs(sessions) do
		session:stop()
	end
	state.options = {
		uv = uv,
		notify = opts.notify,
		event = opts.event,
		schedule = opts.schedule or vim.schedule,
		new_fs_poll = new_fs_poll,
		new_fs_event = new_fs_event,
		poll_interval_ms = poll_interval_ms,
		max_lines = max_lines,
		max_bytes = max_bytes,
	}
	state.sessions_by_buf = {}
	state.sessions_by_source = {}
	state.configured = true
	return true
end

function M.effective_config()
	return state.options
			and {
				poll_interval_ms = state.options.poll_interval_ms,
				max_lines = state.options.max_lines,
				max_bytes = state.options.max_bytes,
			}
		or {
			poll_interval_ms = DEFAULT_POLL_INTERVAL_MS,
			max_lines = DEFAULT_MAX_LINES,
			max_bytes = DEFAULT_MAX_BYTES,
		}
end

function M.open(path, opts)
	if not state.configured then
		return nil, "setup must be called first"
	end
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return nil, "follow path must be a non-empty string without NUL bytes"
	end
	path = vim.fs.normalize(path)
	if path:sub(1, 1) ~= "/" then
		return nil, "follow path must be absolute"
	end
	if state.sessions_by_source[path] then
		return nil, "path is already being followed"
	end
	local stat = state.options.uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil, "follow path must be a readable regular file"
	end
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		return nil, "follow options must be an object"
	end
	if
		opts.metadata ~= nil
		and (type(opts.metadata) ~= "table" or (next(opts.metadata) ~= nil and vim.islist(opts.metadata)))
	then
		return nil, "follow metadata must be an object"
	end
	for key in pairs(opts) do
		if key ~= "metadata" and key ~= "max_lines" and key ~= "max_bytes" then
			return nil, "follow options contain an unknown option: " .. tostring(key)
		end
	end
	local max_lines, lines_err = positive_integer(opts.max_lines, state.options.max_lines, "follow.max_lines")
	if not max_lines then
		return nil, lines_err
	end
	local max_bytes, bytes_err = positive_integer(opts.max_bytes, state.options.max_bytes, "follow.max_bytes")
	if not max_bytes then
		return nil, bytes_err
	end
	state.next_id = state.next_id + 1
	local buf, buffer_err = create_tail_buffer(path, state.next_id)
	if not buf then
		return nil, "could not create tail buffer: " .. tostring(buffer_err)
	end
	local session = setmetatable({
		id = state.next_id,
		buf = buf,
		source_path = path,
		state = "starting",
		closed = false,
		options = state.options,
		max_lines = max_lines,
		max_bytes = max_bytes,
		offset = 0,
		sizes = {},
		buffer_bytes = 0,
		decode_carry = "",
		continuity = "",
		partial_text = nil,
		busy = false,
		pending = false,
		pending_force = false,
		missing = false,
		paused = false,
		health = "healthy",
		error = nil,
		watcher_error = nil,
		dropped = { lines = 0, bytes = 0, events = 0 },
		pin_all_once = true,
		metadata = copy(opts.metadata or {}),
	}, Session)
	state.sessions_by_buf[buf] = session
	state.sessions_by_source[path] = session
	local poll_ok, poll_err = start_poll(session)
	if not poll_ok then
		session:stop()
		return nil, poll_err
	end
	start_fs_event(session)
	session.autocmd = vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		buffer = buf,
		once = true,
		callback = function()
			session.autocmd = nil
			if live(session) then
				session:stop({ wipe = false })
			end
		end,
	})
	emit("opened", session)
	request_refresh(session, true)
	return session
end

local function resolve(session_or_buf)
	if type(session_or_buf) == "table" and getmetatable(session_or_buf) == Session then
		return session_or_buf
	end
	if type(session_or_buf) == "number" then
		return state.sessions_by_buf[session_or_buf]
	end
end

function M.stop(session_or_buf, options)
	local session = resolve(session_or_buf)
	return session and session:stop(options) or false
end

function M.pause(session_or_buf)
	local session = resolve(session_or_buf)
	return session and session:pause() or false
end

function M.resume(session_or_buf)
	local session = resolve(session_or_buf)
	return session and session:resume() or false
end

function M.stop_all(options)
	local sessions = {}
	for _, session in pairs(state.sessions_by_buf) do
		sessions[#sessions + 1] = session
	end
	for _, session in ipairs(sessions) do
		session:stop(options)
	end
	return #sessions
end

function M.session(buf)
	return state.sessions_by_buf[buf]
end

function M.find(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	return state.sessions_by_source[vim.fs.normalize(path)]
end

function M.is_tail(buf)
	return state.sessions_by_buf[buf] ~= nil
end

function M.status()
	local result = {}
	for _, session in pairs(state.sessions_by_buf) do
		result[#result + 1] = session:status()
	end
	table.sort(result, function(left, right)
		return left.id < right.id
	end)
	return result
end

function M.teardown()
	M.stop_all()
	state.configured = false
	state.options = nil
	return true
end

return M
