vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local follow = require("log_workbench.follow")
local matches = require("log_workbench.matches")
local workbench = require("log_workbench")
local decoder = require("log_workbench.decoder")
local failures = {}
local count = 0
local temporary = {}

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function write_raw(path, data)
	local fd, open_err = vim.uv.fs_open(path, "w", 384)
	assert(fd, open_err)
	local written, write_err = vim.uv.fs_write(fd, data, 0)
	assert(written == #data, write_err)
	assert(vim.uv.fs_close(fd))
end

local function append_raw(path, data)
	local fd, open_err = vim.uv.fs_open(path, "a", 384)
	assert(fd, open_err)
	local written, write_err = vim.uv.fs_write(fd, data, -1)
	assert(written == #data, write_err)
	assert(vim.uv.fs_close(fd))
end

local function temporary_file(data)
	local path = vim.fn.tempname()
	write_raw(path, data)
	temporary[#temporary + 1] = path
	return path
end

local function wait_for(predicate, message)
	assert(vim.wait(3000, predicate, 10), message)
end

local function lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function watchers()
	local result = { polls = {}, events = {} }
	local function handle(kind)
		local item = { kind = kind, stopped = false, closed = false }
		function item:start(path, interval_or_options, callback)
			self.path = path
			self.interval_or_options = interval_or_options
			self.callback = callback
			result[kind][#result[kind] + 1] = self
			return 0
		end
		function item:stop()
			self.stopped = true
			return 0
		end
		function item:is_closing()
			return self.closed
		end
		function item:close()
			self.closed = true
		end
		return item
	end
	result.new_fs_poll = function()
		return handle("polls")
	end
	result.new_fs_event = function()
		return handle("events")
	end
	return result
end

test("decoder replaces an invalid available continuation without hiding following ASCII", function()
	local decoded, carry = assert(decoder.feed("", string.char(0xE2) .. "A"))
	equal("\239\191\189A", decoded)
	equal("", carry, "invalid lead plus ASCII remained hidden in carry")
	decoded, carry = assert(decoder.feed("", string.char(0xE2, 0x82)))
	equal("", decoded)
	equal(string.char(0xE2, 0x82), carry, "genuinely incomplete UTF-8 was replaced")
	decoded, carry = assert(decoder.feed(carry, string.char(0xAC)))
	equal("\226\130\172", decoded)
	equal("", carry)
end)

test("top-level setup configures both modules with an exact option object", function()
	equal({ poll_interval_ms = 500, max_lines = 100000, max_bytes = 64 * 1024 * 1024 }, workbench.effective_config())
	assert(workbench.status().configured == false)
	local defaults = workbench.effective_config()
	defaults.max_lines = 1
	equal(100000, workbench.effective_config().max_lines, "effective config leaked mutable state")
	local invalid, invalid_err = workbench.setup({ injected = true })
	assert(not invalid and invalid_err:find("unknown field", 1, true))
	invalid, invalid_err = workbench.setup(false)
	assert(not invalid and invalid_err:find("object", 1, true), "false setup options were accepted")
	assert(workbench.setup({ follow = {}, matches = {} }))
	local before = workbench.status()
	local coerced, coerced_err = workbench.setup({ follow = { max_lines = "bogus" } })
	assert(not coerced and coerced_err:find("positive integer", 1, true), "invalid follow limit was coerced")
	equal(before, workbench.status(), "invalid numeric setup mutated state")
	local nested, nested_err = workbench.setup({ follow = { injected = true }, matches = {} })
	assert(not nested and nested_err:find("unknown option", 1, true), nested_err)
	equal(before, workbench.status(), "rejected nested setup mutated state")
	local status = workbench.status()
	status.config.max_lines = 1
	equal(100000, workbench.status().config.max_lines, "status leaked mutable config")
	assert(workbench.teardown())
	assert(workbench.teardown())
	assert(workbench.status().configured == false)
end)

local function setup_follow(opts)
	opts = opts or {}
	local observed = watchers()
	local ok, err = follow.setup({
		uv = opts.uv,
		max_lines = opts.max_lines or 100,
		max_bytes = opts.max_bytes or 1024,
		new_fs_poll = observed.new_fs_poll,
		new_fs_event = observed.new_fs_event,
		schedule = opts.schedule or vim.schedule,
		notify = function() end,
		event = opts.event,
	})
	assert(ok, err)
	return observed
end

local function poll(observed, previous, current)
	local watcher = assert(observed.polls[#observed.polls], "poll watcher was not started")
	watcher.callback(nil, previous, current)
end

test("follow decodes invalid and split UTF-8 in a separate ephemeral tail buffer", function()
	local observed = setup_follow()
	local path = temporary_file("ok\nbad:\255\254\0\nsplit:\226\130")
	local session = assert(follow.open(path, { metadata = { source_buf = 42 } }))
	local buf = session:buffer()
	wait_for(function()
		return vim.deep_equal(lines(buf), { "ok", "bad:���", "split:" })
	end, "initial invalid UTF-8 was not bounded and replaced")
	assert(vim.startswith(vim.api.nvim_buf_get_name(buf), "tail://"), "tail buffer URI is missing")
	equal("nofile", vim.bo[buf].buftype)
	equal("wipe", vim.bo[buf].bufhidden)
	equal(false, vim.bo[buf].buflisted)
	equal(false, vim.bo[buf].swapfile)
	equal(false, vim.bo[buf].undofile)
	equal(false, vim.bo[buf].modifiable)
	equal(true, vim.bo[buf].readonly)
	equal(1, #observed.polls, "poll watcher count")
	equal(1, #observed.events, "event watcher count")

	local previous = vim.uv.fs_stat(path)
	append_raw(path, "\172\n")
	poll(observed, previous, vim.uv.fs_stat(path))
	wait_for(function()
		return lines(buf)[3] == "split:€"
	end, "split UTF-8 codepoint was not carried across appends")
	equal(42, session:status().metadata.source_buf)
	session:stop()
end)

test("follow reconciles partial append, copytruncate, rotation, deletion, and recreation within limits", function()
	local observed = setup_follow({ max_lines = 3, max_bytes = 32 })
	local path = temporary_file("one\ntwo\nthree\nfour")
	local rotated = path .. ".old"
	temporary[#temporary + 1] = rotated
	local session = assert(follow.open(path))
	local buf = session:buffer()
	wait_for(function()
		return vim.deep_equal(lines(buf), { "two", "three", "four" })
	end, "initial line bound was not enforced")
	assert(session:status().dropped.lines == 1, "line retention did not report dropped data")

	local previous = vim.uv.fs_stat(path)
	append_raw(path, "-x")
	poll(observed, previous, vim.uv.fs_stat(path))
	wait_for(function()
		return lines(buf)[3] == "four-x"
	end, "partial line append did not replace the final line")
	assert(session:status().buffer_bytes <= 32, "byte bound was exceeded")

	previous = vim.uv.fs_stat(path)
	write_raw(path, "new-a\nnew-b")
	poll(observed, previous, vim.uv.fs_stat(path))
	wait_for(function()
		return vim.deep_equal(lines(buf), { "new-a", "new-b" })
	end, "copytruncate did not reload the tail")

	previous = vim.uv.fs_stat(path)
	assert(vim.uv.fs_rename(path, rotated))
	write_raw(path, "rotated-a\nrotated-b")
	observed.events[1].callback(nil, vim.fs.basename(path), { rename = true })
	wait_for(function()
		return vim.deep_equal(lines(buf), { "rotated-a", "rotated-b" })
	end, "inode rotation did not reconcile through fs_event")

	previous = vim.uv.fs_stat(path)
	assert(vim.uv.fs_unlink(path))
	poll(observed, previous, nil)
	wait_for(function()
		return session:status().state == "missing"
	end, "deleted path did not enter missing state")
	equal({ "rotated-a", "rotated-b" }, lines(buf), "delete discarded the last readable tail")

	write_raw(path, "recreated")
	poll(observed, nil, vim.uv.fs_stat(path))
	wait_for(function()
		return vim.deep_equal(lines(buf), { "recreated" })
	end, "recreated path did not reload")
	session:stop()
end)

test("change event detects copytruncate after the replacement regrows beyond the previous offset", function()
	local events = {}
	local observed = setup_follow({
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
		end,
	})
	local path = temporary_file("old-a\nold-b\n")
	local session = assert(follow.open(path))
	wait_for(function()
		return vim.deep_equal(lines(session:buffer()), { "old-a", "old-b" })
	end, "initial tail did not settle")
	local previous_offset = session:status().offset

	write_raw(path, "replacement-a\nreplacement-b\n")
	assert(vim.uv.fs_stat(path).size > previous_offset, "fixture did not regrow beyond the previous offset")
	observed.events[1].callback(nil, vim.fs.basename(path), { change = true })
	wait_for(function()
		return vim.deep_equal(lines(session:buffer()), { "replacement-a", "replacement-b" })
	end, "regrown copytruncate was mistaken for an append")
	assert(
		vim.tbl_contains(
			vim.tbl_map(function(event)
				return event.kind
			end, events),
			"reload"
		),
		"continuity break did not emit a reload"
	)
	session:stop()
end)

test("copytruncate cannot collide only on a short continuity suffix", function()
	local observed = setup_follow({ max_bytes = 200000 })
	local shared = string.rep("x", 65536)
	local path = temporary_file("OLD\n" .. shared)
	local session = assert(follow.open(path))
	wait_for(function()
		return lines(session:buffer())[1] == "OLD"
	end, "initial long tail did not settle")
	local previous_offset = session:status().offset

	write_raw(path, "NEW\n" .. shared .. "extra")
	assert(vim.uv.fs_stat(path).size > previous_offset, "fixture did not regrow beyond the previous offset")
	observed.events[1].callback(nil, vim.fs.basename(path), { change = true })
	wait_for(function()
		return lines(session:buffer())[1] == "NEW"
	end, "copytruncate prefix change collided on a shared 64 KiB suffix")
	session:stop()
end)

test("invalid per-session bounds fail before publishing a buffer or identity", function()
	setup_follow()
	local path = temporary_file("bounded\n")
	local before = #follow.status()
	local session, err = follow.open(path, { max_lines = "bad" })
	assert(not session and err:find("positive integer", 1, true))
	equal(before, #follow.status(), "invalid open published a follow session")
	assert(follow.find(path) == nil, "invalid open claimed the source path")
end)

test("fs-event storms coalesce, change appends incrementally, and uncertain identity reloads", function()
	local events = {}
	local observed = setup_follow({
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.path = "mutated"
		end,
	})
	local path = temporary_file("base")
	local session = assert(follow.open(path))
	wait_for(function()
		return session:status().state == "following"
	end, "initial follow did not settle")
	local event_watcher = observed.events[1]
	append_raw(path, "-append")
	for _ = 1, 8 do
		event_watcher.callback(nil, vim.fs.basename(path), { change = true })
	end
	wait_for(function()
		return vim.deep_equal(lines(session:buffer()), { "base-append" })
	end, "change event did not append incrementally")
	wait_for(function()
		return session:status().dropped.events > 0
	end, "event storm did not report coalesced notifications")
	assert(
		vim.tbl_contains(
			vim.tbl_map(function(event)
				return event.kind
			end, events),
			"append"
		),
		"change event forced a full reload"
	)
	assert(events[1].path == path, "event callback mutated plugin event state")

	local reloads = 0
	for _, event in ipairs(events) do
		reloads = reloads + (event.kind == "reload" and 1 or 0)
	end
	event_watcher.callback(nil, vim.fs.basename(path), { rename = true })
	wait_for(function()
		local count = 0
		for _, event in ipairs(events) do
			count = count + (event.kind == "reload" and 1 or 0)
		end
		return count > reloads
	end, "rename event did not force identity revalidation")
	reloads = reloads + 1
	event_watcher.callback(nil, vim.fs.basename(path), { unexpected = true })
	wait_for(function()
		local count = 0
		for _, event in ipairs(events) do
			count = count + (event.kind == "reload" and 1 or 0)
		end
		return count > reloads
	end, "unknown event flags did not force identity revalidation")
	session:stop()
end)

test("pause closes watchers, resume revalidates, and status exposes health and drops", function()
	local observed = setup_follow()
	local path = temporary_file("paused")
	local session = assert(follow.open(path))
	wait_for(function()
		return session:status().state == "following"
	end, "initial follow did not settle")
	local poll_watcher = observed.polls[1]
	local event_watcher = observed.events[1]
	assert(session:pause())
	local paused = session:status()
	assert(paused.paused and paused.health == "paused")
	assert(type(paused.dropped.lines) == "number" and paused.error == nil)
	assert(poll_watcher.stopped and poll_watcher.closed)
	assert(event_watcher.stopped and event_watcher.closed)
	event_watcher.callback(nil, vim.fs.basename(path), { change = true })
	wait_for(function()
		return session:status().dropped.events >= 1
	end, "paused event was not counted as dropped")
	append_raw(path, "-resume")
	assert(session:resume())
	equal(2, #observed.polls, "resume did not replace the poll watcher")
	equal(2, #observed.events, "resume did not replace the event watcher")
	wait_for(function()
		return vim.deep_equal(lines(session:buffer()), { "paused-resume" })
	end, "resume did not force a current-path reload")
	assert(not session:status().paused and session:status().health == "healthy")
	session:stop()
end)

test("single long lines retain a valid UTF-8 suffix inside the byte ceiling", function()
	setup_follow({ max_lines = 5, max_bytes = 7 })
	local path = temporary_file("abcdef€")
	local session = assert(follow.open(path))
	wait_for(function()
		return vim.deep_equal(lines(session:buffer()), { "cdef€" })
	end, "long-line suffix was not UTF-8 aligned")
	equal(7, session:status().buffer_bytes)
	session:stop()
end)

test("stop closes both watcher types and a delayed read cannot mutate after teardown", function()
	local delayed
	local uv = setmetatable({
		fs_read = function(_, _, _, callback)
			delayed = callback
			return {}
		end,
	}, { __index = vim.uv })
	local observed = setup_follow({ uv = uv })
	local path = temporary_file("late")
	local session = assert(follow.open(path))
	wait_for(function()
		return delayed ~= nil
	end, "delayed read was not captured")
	local buf = session:buffer()
	assert(session:stop())
	equal(false, vim.api.nvim_buf_is_valid(buf), "tail buffer survived stop")
	equal(true, observed.polls[1].stopped)
	equal(true, observed.polls[1].closed)
	equal(true, observed.events[1].stopped)
	equal(true, observed.events[1].closed)
	delayed(nil, "late data")
	wait_for(function()
		return #follow.status() == 0
	end, "late callback recreated a stopped session")
	follow.teardown()
	equal({}, follow.status())
end)

test("matches use stable IDs and extmarks with automatic refresh and navigation", function()
	assert(matches.setup())
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ERROR one", "ok", "WARN ERROR" })
	assert(matches.add(buf, { id = "errors", kind = "exact", text = "ERROR", hl_group = "ErrorMsg" }))
	local warning = assert(matches.add(buf, { kind = "regex", text = "W.RN", hl_group = "WarningMsg" }))
	equal(1, warning.id)
	equal(3, #matches.locations(buf))
	local extmarks = vim.api.nvim_buf_get_extmarks(buf, matches.namespace(), 0, -1, { details = true })
	equal(3, #extmarks, "match extmark count")

	local listed = matches.list(buf)
	listed[1].metadata.changed = true
	assert(matches.list(buf)[1].metadata.changed == nil, "pattern list leaked mutable registry state")
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	equal({ pattern_id = 1, row = 3, col = 1, end_col = 5 }, assert(matches.next(buf)))
	equal({ pattern_id = "errors", row = 3, col = 6, end_col = 11 }, assert(matches.next(buf)))
	equal({ pattern_id = "errors", row = 1, col = 1, end_col = 6 }, assert(matches.next(buf)))
	equal({ pattern_id = "errors", row = 3, col = 6, end_col = 11 }, assert(matches.previous(buf)))

	assert(matches.remove(buf, "errors"))
	equal(1, #matches.locations(buf))
	vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "WARN again" })
	wait_for(function()
		return #matches.locations(buf) == 2
	end, "buffer change did not refresh extmarks")
	equal(1, matches.clear(buf))
	equal({}, matches.locations(buf))
	matches.teardown()
	equal(0, #vim.api.nvim_buf_get_extmarks(buf, matches.namespace(), 0, -1, {}))
	vim.api.nvim_buf_delete(buf, { force = true })
end)

follow.teardown()
matches.teardown()
for _, path in ipairs(temporary) do
	vim.fn.delete(path, "rf")
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("log_workbench_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
