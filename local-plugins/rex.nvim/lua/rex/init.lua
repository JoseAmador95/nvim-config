-- Passive host-side ownership of Rex floating terminals through the Rex CLI.
local process = require("rex.process")
local M = {}
local uv = vim.uv

local function defaults()
	return { bin = "rex", system = vim.system, schedule = vim.schedule, timeout_ms = 5000, poll_interval_ms = 500 }
end

local config = defaults()
local configured, stopping = false, false
local records, verified = {}, {}
local pending, serial = 0, 0
local poller, polling
local nonce = tostring(uv.os_getpid()) .. "-" .. tostring(uv.hrtime())
local close_record, reconcile, start_poll

local function text(value, maximum)
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%z")
end

local function id(value)
	return text(value, 256) and value:match("^[%w_:%-]+$") ~= nil
end

local function keys(value, allowed, name)
	if type(value) ~= "table" then
		return name .. " must be a table"
	end
	for key in pairs(value) do
		if not allowed[key] then
			return name .. " contains an unknown option: " .. tostring(key)
		end
	end
end

local function reply(callback, err, value)
	config.schedule(function()
		callback(err, value)
	end)
end

local function local_server()
	local server = vim.env.REX_SERVER
	if server and server ~= "" and not server:match("^unix:///") then
		return nil, "Rex requires the local Unix server; remote REX_SERVER is unsupported"
	end
	return server or ""
end

local function context_key(ctx)
	return table.concat({ ctx.session_id, ctx.window_id, ctx.block_id }, ":")
end

local function handle(record)
	return {
		session_id = record.context.session_id,
		window_id = record.context.window_id,
		source_block_id = record.context.block_id,
		layer_id = record.layer_id,
		block_id = record.block_id,
		label = record.label,
	}
end

local function run(server, argv, callback)
	local current, err = local_server()
	if err or current ~= server then
		reply(callback, err or "Rex server changed since the context was verified")
		return
	end
	pending = pending + 1
	return process.run(config, argv, function(failure, output)
		pending = pending - 1
		if failure then
			callback(failure)
			return
		end
		local ok, value = pcall(vim.json.decode, output)
		if not ok or type(value) ~= "table" then
			callback("Rex returned malformed JSON")
		else
			callback(nil, value)
		end
	end)
end

local function api(record, method, body, callback)
	body = vim.tbl_extend("force", body, { session_id = record.context.session_id })
	return run(record.server, {
		"api",
		"call",
		"-s",
		record.context.session_id,
		method,
		vim.json.encode(body),
	}, callback)
end

local function list(value)
	return type(value) == "table" and vim.islist(value)
end

local function valid_view(view, session_id)
	if view.session_id ~= session_id or not list(view.windows) then
		return false
	end
	if view.active_window_id ~= nil and view.active_window_id ~= vim.NIL and not id(view.active_window_id) then
		return false
	end
	for _, window in ipairs(view.windows) do
		if type(window) ~= "table" or not id(window.window_id) or not list(window.layers) then
			return false
		end
		if
			window.focused_block_id ~= nil
			and window.focused_block_id ~= vim.NIL
			and not id(window.focused_block_id)
		then
			return false
		end
		for _, layer in ipairs(window.layers) do
			if
				type(layer) ~= "table"
				or not id(layer.layer_id)
				or (layer.kind ~= "floating" and layer.kind ~= "tiled")
				or not list(layer.blocks)
			then
				return false
			end
			for _, block in ipairs(layer.blocks) do
				if type(block) ~= "table" or not id(block.block_id) then
					return false
				end
			end
		end
	end
	return true
end

local function view(record, callback)
	return api(record, "session.view", {}, function(err, value)
		if not err and not valid_view(value, record.context.session_id) then
			err = "Rex returned a malformed session view"
		end
		callback(err, not err and value or nil)
	end)
end

local function find_owned(snapshot, record)
	for _, window in ipairs(snapshot.windows) do
		if window.window_id == record.context.window_id then
			for _, layer in ipairs(window.layers) do
				if layer.layer_id == record.layer_id and layer.kind == "floating" then
					for _, block in ipairs(layer.blocks) do
						if block.block_id == record.block_id then
							return window, layer
						end
					end
				end
			end
		end
	end
end

local function stop_poll()
	if poller then
		poller:stop()
		poller:close()
		poller = nil
	end
end

local function live_records()
	for _, record in pairs(records) do
		if record.state == "live" or record.state == "closing" then
			return true
		end
	end
	return false
end

local function opened(record, err)
	local callback = record.callback
	record.callback = nil
	if callback then
		callback(err, not err and handle(record) or nil)
	end
end

local function closed(record, reason)
	if records[record.key] ~= record then
		return
	end
	records[record.key] = nil
	record.state = "closed"
	if not live_records() then
		stop_poll()
	end
	opened(record, "Rex opening was cancelled")
	if record.on_close then
		record.on_close(handle(record), reason)
	end
end

local function uncertain(record, failure)
	record.state = "uncertain"
	record.error = "Rex creation outcome is uncertain; retry to reconcile: " .. failure
	opened(record, record.error)
end

local function adopted(record, layer_id, block_id)
	record.layer_id, record.block_id = layer_id, block_id
	record.state, record.error = "live", nil
	if record.cancelled or stopping then
		close_record(record, function(err)
			if err then
				record.error = err
				opened(record, "Rex opening was cancelled; cleanup failed: " .. err)
			end
		end)
	else
		start_poll()
		opened(record)
	end
end

reconcile = function(record)
	record.state = "reconciling"
	view(record, function(err, snapshot)
		if err then
			uncertain(record, err)
			return
		end
		local found
		for _, window in ipairs(snapshot.windows) do
			for _, layer in ipairs(window.layers) do
				for _, block in ipairs(layer.blocks) do
					if block.label == record.label then
						if found or window.window_id ~= record.context.window_id or layer.kind ~= "floating" then
							uncertain(record, "unique owned floating layer could not be established")
							return
						end
						found = { layer_id = layer.layer_id, block_id = block.block_id }
					end
				end
			end
		end
		if found then
			adopted(record, found.layer_id, found.block_id)
		else
			-- Absence is not proof of failure: the mutation may still reach the server.
			uncertain(record, "the unique creation label is not visible")
		end
	end)
end

start_poll = function()
	if poller or stopping or not live_records() then
		return
	end
	local timer = uv.new_timer()
	poller = timer
	timer:start(config.poll_interval_ms, config.poll_interval_ms, function()
		config.schedule(function()
			if poller ~= timer or polling then
				return
			end
			local sessions = {}
			for _, record in pairs(records) do
				if record.state == "live" then
					sessions[record.context.session_id] = record
				end
			end
			local count = vim.tbl_count(sessions)
			polling = count > 0
			for _, representative in pairs(sessions) do
				view(representative, function(err, snapshot)
					if poller == timer and not err then
						local gone = {}
						for _, record in pairs(records) do
							if record.state == "live" and record.context.session_id == snapshot.session_id then
								if not find_owned(snapshot, record) then
									gone[#gone + 1] = record
								end
							end
						end
						for _, record in ipairs(gone) do
							closed(record, "external")
						end
					end
					count = count - 1
					if count == 0 then
						polling = false
					end
				end)
			end
		end)
	end)
end

local function restore_focus(record, callback)
	view(record, function(err, snapshot)
		if err then
			callback(err)
			return
		end
		for _, window in ipairs(snapshot.windows) do
			if window.window_id == record.context.window_id and snapshot.active_window_id == window.window_id then
				local focused = window.focused_block_id
				if focused == record.block_id or focused == vim.NIL or focused == nil then
					api(record, "session.focus_block", { block_id = record.context.block_id }, callback)
					return
				end
			end
		end
		callback()
	end)
end

close_record = function(record, callback)
	if record.state == "closing" then
		reply(callback, "Rex floating layer is already closing")
		return
	end
	record.state = "closing"
	view(record, function(err, snapshot)
		if err then
			record.state = "live"
			callback(err)
			return
		end
		local window = find_owned(snapshot, record)
		if not window then
			closed(record, "external")
			callback()
			return
		end
		local focused = snapshot.active_window_id == window.window_id and window.focused_block_id == record.block_id
		api(record, "session.close_layer", { layer_id = record.layer_id }, function(failure)
			if failure then
				record.state = "live"
				callback(failure)
				return
			end
			closed(record, record.cancelled and "cancelled" or "closed")
			if focused then
				restore_focus(record, callback)
			else
				callback()
			end
		end)
	end)
end

function M.context(callback)
	local session_id, block_id = vim.env.REX_SESSION, vim.env.REX_BLOCK
	if not session_id and not block_id then
		reply(callback)
		return
	end
	local server, err = local_server()
	if err or not id(session_id) or not id(block_id) then
		reply(callback, err or "Rex inherited session and block IDs are incomplete or invalid")
		return
	end
	return run(server, { "block", "inspect", "-s", session_id, block_id, "--json" }, function(failure, result)
		if failure then
			callback(failure)
			return
		end
		local block = result.block
		if
			result.session_id ~= session_id
			or type(block) ~= "table"
			or block.block_id ~= block_id
			or not id(block.window_id)
		then
			callback("Rex could not verify the exact inherited session and block")
			return
		end
		local ctx = { session_id = session_id, block_id = block_id, window_id = block.window_id }
		verified[context_key(ctx)] = server
		callback(nil, ctx)
	end)
end

local function validate_open(opts)
	local err = keys(opts, { context = true, label = true, command = true, cwd = true, on_close = true }, "Rex float")
	if err then
		return err
	end
	local ctx = opts.context
	if type(ctx) ~= "table" or not id(ctx.session_id) or not id(ctx.block_id) or not id(ctx.window_id) then
		return "Rex float needs a verified context"
	end
	if verified[context_key(ctx)] == nil then
		return "Rex float context has not been verified by this client"
	end
	if not text(opts.label, 256) or not text(opts.cwd, 4096) or opts.cwd:sub(1, 1) ~= "/" then
		return "Rex float needs a label and an absolute cwd"
	end
	if not list(opts.command) or #opts.command < 1 or #opts.command > 256 then
		return "Rex float command must be a nonempty argv list"
	end
	local bytes = 0
	for index, arg in ipairs(opts.command) do
		if type(arg) ~= "string" or arg:find("%z") or (index == 1 and arg == "") then
			return "Rex float command arguments must be strings without NUL bytes"
		end
		bytes = bytes + #arg
	end
	if bytes > 65536 then
		return "Rex float command exceeds its size limit"
	end
	if opts.on_close ~= nil and type(opts.on_close) ~= "function" then
		return "Rex float on_close must be a function"
	end
end

function M.open_float(opts, callback)
	local err = validate_open(opts)
	if err or stopping then
		reply(callback, err or "Rex client is stopping")
		return
	end
	local key = context_key(opts.context) .. ":" .. opts.label
	local record = records[key]
	if record then
		if record.cwd ~= opts.cwd or not vim.deep_equal(record.command, opts.command) then
			reply(callback, "Rex float already exists with a different command or cwd")
		elseif record.state == "live" then
			reply(callback, nil, handle(record))
		elseif record.state == "uncertain" then
			record.callback = callback
			reconcile(record)
		else
			reply(callback, "Rex float creation or cleanup is already pending")
		end
		return
	end
	if vim.tbl_count(records) >= 16 then
		reply(callback, "Rex client owns too many live or uncertain floating layers")
		return
	end
	serial = serial + 1
	record = {
		key = key,
		context = vim.deepcopy(opts.context),
		server = verified[context_key(opts.context)],
		label = opts.label .. " [nvim-" .. nonce .. "-" .. serial .. "]",
		command = vim.deepcopy(opts.command),
		cwd = opts.cwd,
		on_close = opts.on_close,
		callback = callback,
		state = "creating",
	}
	records[key] = record
	local request = api(record, "session.new_layer", {
		window_id = record.context.window_id,
		bounds = { 0.05, 0.05, 0.9, 0.9 },
		focus = true,
		layout = {
			block = {
				flavor = "com.superlogical.terminal.shell",
				label = record.label,
				options = {
					command = record.command,
					cwd = record.cwd,
					shell = "none",
					login = false,
					exit = { on_completion = true },
				},
			},
		},
	}, function(failure, result)
		record.request = nil
		if
			failure
			or not id(result.layer_id)
			or not list(result.block_ids)
			or #result.block_ids ~= 1
			or not id(result.block_ids[1])
			or result.block_ids[1] == record.context.block_id
		then
			reconcile(record)
		else
			adopted(record, result.layer_id, result.block_ids[1])
		end
	end)
	if record.state == "creating" then
		record.request = request
	end
	return {
		cancel = function()
			if records[key] ~= record or record.cancelled then
				return
			end
			record.cancelled = true
			if record.request then
				record.request.cancel()
			elseif record.state == "live" then
				close_record(record, function(failure)
					record.error = failure
				end)
			end
		end,
	}
end

local function owned(value)
	if type(value) == "table" then
		for _, record in pairs(records) do
			if record.layer_id and vim.deep_equal(handle(record), value) then
				return record
			end
		end
	end
end

function M.focus(value, callback)
	local record = owned(value)
	if not record or record.state ~= "live" then
		reply(callback, "Rex handle is not an owned live floating layer")
		return
	end
	return api(record, "session.focus_block", { block_id = record.block_id }, callback)
end

local function layer_action(value, method, body, callback)
	local record = owned(value)
	if not record or record.state ~= "live" or stopping then
		reply(callback, "Rex handle is not an owned live floating layer")
		return
	end
	return view(record, function(err, snapshot)
		if err then
			callback(err)
		elseif records[record.key] ~= record or record.state ~= "live" or stopping then
			callback("Rex floating layer is no longer live")
		elseif not find_owned(snapshot, record) then
			closed(record, "external")
			callback("Rex floating layer is no longer in its source window")
		else
			body.layer_id = record.layer_id
			api(record, method, body, callback)
		end
	end)
end

function M.hide(value, callback)
	return layer_action(value, "session.set_layer_state", { state = "minimized" }, callback)
end

function M.restore(value, callback)
	return layer_action(value, "session.set_layer_state", { state = "normal", focus = true }, callback)
end

function M.resize(value, bounds, callback)
	local valid = list(bounds) and #bounds == 4
	if valid then
		for _, number in ipairs(bounds) do
			if type(number) ~= "number" or number ~= number or number < 0 or number > 1 then
				valid = false
				break
			end
		end
	end
	if not valid or bounds[3] <= 0 or bounds[4] <= 0 or bounds[1] + bounds[3] > 1 or bounds[2] + bounds[4] > 1 then
		reply(callback, "Rex bounds must be [x, y, width, height] fractions inside the window")
		return
	end
	return layer_action(value, "session.resize_layer", { bounds = vim.deepcopy(bounds) }, callback)
end

function M.close(value, callback)
	local record = owned(value)
	if not record then
		reply(callback, "Rex handle is not owned by this client")
		return
	end
	close_record(record, callback)
end

function M.teardown()
	stopping = true
	stop_poll()
	for _, record in pairs(records) do
		record.cancelled = true
		if record.request then
			record.request.cancel()
		elseif record.state == "live" then
			close_record(record, function(err)
				record.error = err
			end)
		elseif record.state == "uncertain" then
			reconcile(record)
		end
	end
	return M
end

function M.effective_config()
	return vim.deepcopy(config)
end

function M.status()
	local values = {}
	for _, record in pairs(records) do
		values[#values + 1] = { state = record.state, handle = handle(record), error = record.error }
	end
	table.sort(values, function(a, b)
		return a.handle.label < b.handle.label
	end)
	return { configured = configured, stopping = stopping, pending = pending, records = values }
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local err = keys(
		opts,
		{ bin = true, system = true, schedule = true, timeout_ms = true, poll_interval_ms = true },
		"Rex setup"
	)
	if err then
		error(err)
	end
	local candidate = vim.tbl_extend("force", defaults(), opts)
	if
		not text(candidate.bin, 4096)
		or type(candidate.system) ~= "function"
		or type(candidate.schedule) ~= "function"
	then
		error("Rex setup requires a binary name and system/schedule functions")
	end
	for _, field in ipairs({ "timeout_ms", "poll_interval_ms" }) do
		local value = candidate[field]
		if type(value) ~= "number" or value < 1 or value > 60000 or value % 1 ~= 0 then
			error("Rex " .. field .. " must be an integer between 1 and 60000")
		end
	end
	if next(records) or pending > 0 then
		error("Rex resources must finish cleanup before setup can change")
	end
	config = candidate
	verified = {}
	configured, stopping = true, false
	return M
end

return M
