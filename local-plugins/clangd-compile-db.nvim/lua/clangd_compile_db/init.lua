local M = {}

local uv = vim.uv
local configured = {}
local is_configured = false
local roots = {}
local providers = {}
local pending_restarts = {}
local MAX_BYTES = 256 * 1024 * 1024

local function public_defaults()
	return {
		max_validation_bytes = MAX_BYTES,
		restart_delay_ms = 100,
		restart_timeout_ms = 5000,
	}
end

local SETUP_KEYS = {
	clock = true,
	defer = true,
	event = true,
	events = true,
	lsp = true,
	max_validation_bytes = true,
	restart_delay_ms = true,
	restart_timeout_ms = true,
}

local LSP_KEYS = {
	attach = true,
	buffer_valid = true,
	client_root = true,
	clients = true,
	config = true,
	discard = true,
	reconcile = true,
	start = true,
	stop = true,
	wait_initialized = true,
	wait_stopped = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function reject_unknown(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key: " .. tostring(key)
		end
	end
	return true
end

local function emit(kind, details)
	local callback = configured.event or configured.events
	if type(callback) ~= "function" then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	pcall(callback, event)
end

local function canonical(path)
	if type(path) ~= "string" or path == "" or path:find("%z") then
		return nil
	end
	local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	return uv.fs_realpath(absolute) or absolute
end

local function state_for(root)
	local state = roots[root]
	if not state then
		state = {
			generation = 0,
			state = "candidate",
			candidates = {},
			active_revision = 0,
			applied_revision = 0,
		}
		roots[root] = state
	end
	return state
end

local function publish(root, name, fields, clear)
	local state = state_for(root)
	state.generation = state.generation + 1
	state.state = name
	state.updated_at = type(configured.clock) == "function" and configured.clock() or os.time()
	for key, value in pairs(fields or {}) do
		state[key] = copy(value)
	end
	for _, key in ipairs(clear or {}) do
		state[key] = nil
	end
	emit("status", { root = root, status = M.status(root) })
	return state
end

local function fingerprint(stat, digest)
	local mtime = stat.mtime or {}
	return table.concat({
		tostring(stat.dev or ""),
		tostring(stat.ino or ""),
		tostring(stat.size or ""),
		tostring(mtime.sec or ""),
		tostring(mtime.nsec or ""),
		tostring(digest or ""),
	}, ":")
end

local function same_identity(left, right)
	local left_mtime = left and left.mtime or {}
	local right_mtime = right and right.mtime or {}
	local left_ctime = left and left.ctime or {}
	local right_ctime = right and right.ctime or {}
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left_mtime.sec == right_mtime.sec
		and left_mtime.nsec == right_mtime.nsec
		and left_ctime.sec == right_ctime.sec
		and left_ctime.nsec == right_ctime.nsec
end

local function open_checked(path, expected)
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, tostring(open_err)
	end
	local opened = uv.fs_fstat(fd)
	if not same_identity(expected, opened) then
		uv.fs_close(fd)
		return nil, "compile_commands.json changed while opening"
	end
	return fd, opened
end

local function read_file(path, expected)
	local fd, opened_or_err = open_checked(path, expected)
	if not fd then
		return nil, opened_or_err
	end
	local opened = opened_or_err
	local data, read_err = uv.fs_read(fd, opened.size, 0)
	local after_read = uv.fs_fstat(fd)
	local closed, close_err = uv.fs_close(fd)
	local after_path = uv.fs_lstat(path)
	if type(data) ~= "string" or #data ~= opened.size then
		return nil, tostring(read_err or "short read")
	end
	if not closed then
		return nil, "could not close compile_commands.json: " .. tostring(close_err)
	end
	if not same_identity(opened, after_read) or not same_identity(opened, after_path) then
		return nil, "compile_commands.json changed while reading"
	end
	return data
end

local function inspect_file(path, expected)
	local fd, opened_or_err = open_checked(path, expected)
	if not fd then
		return nil, opened_or_err
	end
	local opened = opened_or_err
	local closed, close_err = uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if not closed then
		return nil, tostring(close_err)
	end
	if not same_identity(opened, after) then
		return nil, "compile_commands.json changed while inspecting"
	end
	return opened
end

local function validate_entry(entry, index)
	local label = ("compile_commands.json entry %d"):format(index)
	if type(entry) ~= "table" or vim.islist(entry) then
		return nil, label .. " must be an object"
	end
	for _, key in ipairs({ "directory", "file" }) do
		if type(entry[key]) ~= "string" or entry[key] == "" or entry[key]:find("%z") then
			return nil, label .. "." .. key .. " must be a non-empty string"
		end
	end
	local has_arguments = entry.arguments ~= nil
	local has_command = entry.command ~= nil
	if has_arguments == has_command then
		return nil, label .. " must contain exactly one of arguments or command"
	end
	if has_arguments then
		if type(entry.arguments) ~= "table" or not vim.islist(entry.arguments) then
			return nil, label .. ".arguments must be an array of strings"
		end
		for argument_index, argument in ipairs(entry.arguments) do
			if type(argument) ~= "string" or argument:find("%z") then
				return nil, ("%s.arguments[%d] must be a string without NUL bytes"):format(label, argument_index)
			end
		end
	elseif type(entry.command) ~= "string" or entry.command == "" or entry.command:find("%z") then
		return nil, label .. ".command must be a non-empty string"
	end
	return true
end

function M.validate(directory, options)
	options = options or {}
	local expanded = canonical(directory)
	local directory_stat = expanded and uv.fs_stat(expanded) or nil
	if not directory_stat or directory_stat.type ~= "directory" then
		return nil, "not a directory: " .. tostring(expanded or directory)
	end
	local path = vim.fs.joinpath(expanded, "compile_commands.json")
	local stat = uv.fs_lstat(path)
	if not stat or stat.type ~= "file" then
		return nil, "compile_commands.json not found in " .. expanded
	end
	local maximum = configured.max_validation_bytes or MAX_BYTES
	if stat.size > maximum then
		if options.unchecked ~= true then
			return nil, ("compile_commands.json exceeds %d bytes; use bang to apply unchecked"):format(maximum)
		end
		local inspected, inspect_err = inspect_file(path, stat)
		if not inspected then
			return nil, "could not inspect " .. path .. ": " .. tostring(inspect_err)
		end
		return {
			directory = expanded,
			path = path,
			size = inspected.size,
			validity = "unchecked",
			fingerprint = fingerprint(inspected),
		}
	end
	local data, read_err = read_file(path, stat)
	if not data then
		return nil, "could not read " .. path .. ": " .. tostring(read_err)
	end
	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or not vim.islist(decoded) then
		return nil, "invalid compile_commands.json in " .. expanded .. " (expected a JSON array)"
	end
	for index, entry in ipairs(decoded) do
		local valid, entry_err = validate_entry(entry, index)
		if not valid then
			return nil, "invalid compile_commands.json in " .. expanded .. ": " .. entry_err
		end
	end
	return {
		directory = expanded,
		path = path,
		size = stat.size,
		validity = "structural",
		fingerprint = fingerprint(stat, vim.fn.sha256(data)),
	}
end

function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local valid, setup_err = reject_unknown(opts, SETUP_KEYS, "clangd_compile_db.setup options")
	if not valid then
		error(setup_err)
	end
	for _, name in ipairs({ "clock", "defer", "event", "events" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error("clangd_compile_db.setup " .. name .. " must be a function")
		end
	end
	if opts.event ~= nil and opts.events ~= nil then
		error("clangd_compile_db.setup accepts event, not both event and events")
	end
	if opts.lsp ~= nil then
		valid, setup_err = reject_unknown(opts.lsp, LSP_KEYS, "clangd_compile_db.setup lsp")
		if not valid then
			error(setup_err)
		end
		for name, callback in pairs(opts.lsp) do
			if type(callback) ~= "function" then
				error("clangd_compile_db.setup lsp." .. name .. " must be a function")
			end
		end
	end
	local maximum = opts.max_validation_bytes
	if maximum == nil then
		maximum = MAX_BYTES
	end
	if type(maximum) ~= "number" or maximum < 1 or maximum % 1 ~= 0 or maximum > MAX_BYTES then
		error(("max_validation_bytes must be an integer between 1 and %d"):format(MAX_BYTES))
	end
	local timeout = opts.restart_timeout_ms
	if timeout == nil then
		timeout = 5000
	end
	if type(timeout) ~= "number" or timeout < 1 or timeout % 1 ~= 0 then
		error("restart_timeout_ms must be a positive integer")
	end
	local delay = opts.restart_delay_ms
	if delay == nil then
		delay = 100
	end
	if type(delay) ~= "number" or delay < 0 or delay % 1 ~= 0 then
		error("restart_delay_ms must be a non-negative integer")
	end
	if is_configured then
		M.teardown()
	end
	configured = {
		clock = opts.clock,
		defer = opts.defer,
		event = opts.event,
		events = opts.events,
		lsp = opts.lsp and copy(opts.lsp) or nil,
		max_validation_bytes = maximum,
		restart_delay_ms = delay,
		restart_timeout_ms = timeout,
	}
	roots = {}
	providers = {}
	pending_restarts = {}
	is_configured = true
	emit("setup", { config = M.effective_config() })
	return M
end

function M.effective_config()
	if not is_configured then
		return public_defaults()
	end
	return copy({
		max_validation_bytes = configured.max_validation_bytes,
		restart_delay_ms = configured.restart_delay_ms,
		restart_timeout_ms = configured.restart_timeout_ms,
	})
end

function M.teardown()
	if not is_configured then
		return true
	end
	emit("teardown", {})
	configured = {}
	roots = {}
	providers = {}
	pending_restarts = {}
	is_configured = false
	return true
end

function M.register_provider(name, options)
	assert(type(name) == "string" and name:match("^[%w_.-]+$"), "provider name is invalid")
	providers[name] = { priority = tonumber(options and options.priority) or 0 }
	return M
end

local function provider_priority(name, options)
	return tonumber(options and options.priority) or (providers[name] and providers[name].priority) or 0
end

function M.candidate(root, provider, directory, options)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	if type(provider) ~= "string" or not provider:match("^[%w_.-]+$") then
		return nil, "invalid compile database provider"
	end
	local validated, err = M.validate(directory, options)
	if not validated then
		local state = state_for(root)
		state.candidates[provider] = nil
		local published = publish(root, "error", { error = err }, { "candidate" })
		return nil, err, copy(published)
	end
	local record = vim.tbl_extend("force", validated, {
		provider = provider,
		priority = provider_priority(provider, options),
	})
	local state = state_for(root)
	state.candidates[provider] = record
	publish(root, "candidate", { candidate = record }, { "error" })
	return copy(record)
end

local function best_candidate(state, provider)
	if state.override then
		return state.override
	end
	if provider then
		return state.candidates[provider]
	end
	local candidates = {}
	for _, candidate in pairs(state.candidates) do
		candidates[#candidates + 1] = candidate
	end
	table.sort(candidates, function(left, right)
		if left.priority == right.priority then
			return left.provider < right.provider
		end
		return left.priority > right.priority
	end)
	return candidates[1]
end

local function same_record(left, right)
	return left
		and right
		and left.provider == right.provider
		and left.directory == right.directory
		and left.fingerprint == right.fingerprint
		and left.validity == right.validity
end

local function same_configuration(left, right)
	return (left == nil and right == nil) or same_record(left, right)
end

local function application_matches(state, active)
	return state.applied_revision ~= nil and same_configuration(state.applied, active)
end

local function advance_active_revision(state, active)
	if same_configuration(state.active, active) then
		return false
	end
	state.active_revision = state.active_revision + 1
	return true
end

local function touch(root)
	local state = state_for(root)
	state.generation = state.generation + 1
	state.updated_at = type(configured.clock) == "function" and configured.clock() or os.time()
	emit("status", { root = root, status = M.status(root) })
	return state
end

local function mark_applied(root, revision, active)
	local state = state_for(root)
	state.applied_revision = revision
	state.applied = copy(active)
	if revision == state.active_revision and same_configuration(state.active, active) then
		state.state = active and "active" or "candidate"
		state.error = nil
	end
	return touch(root)
end

local function mark_unapplied(root, message)
	local state = state_for(root)
	state.applied = nil
	state.applied_revision = nil
	return publish(root, "error", { error = message })
end

local function refresh_record(record, options)
	options = options or {}
	local validated, err = M.validate(record.directory, {
		unchecked = options.unchecked == true or record.validity == "unchecked",
	})
	if not validated then
		return nil, err
	end
	return vim.tbl_extend("force", validated, {
		provider = record.provider,
		priority = record.priority,
	})
end

local function store_record(state, record)
	if record.provider == "manual" then
		state.override = record
	else
		state.candidates[record.provider] = record
	end
end

local function unchecked_requires_bang(state, record, options)
	return record.validity == "unchecked"
		and (not options or options.unchecked ~= true)
		and not same_record(state.active, record)
end

local function client_root(lsp, client)
	if type(lsp.client_root) == "function" then
		return canonical(lsp.client_root(client))
	end
	return canonical(client.config and client.config.root_dir)
end

local function stopped_clients(lsp, clients, root)
	if type(lsp.wait_stopped) ~= "function" then
		return nil, "cannot confirm that clangd stopped: wait callback is missing"
	end
	local ok, stopped = pcall(lsp.wait_stopped, clients, root, configured.restart_timeout_ms)
	if not ok then
		return nil, "could not confirm that clangd stopped: " .. tostring(stopped)
	end
	if not stopped then
		return nil, "timed out waiting for clangd to stop"
	end
	return true
end

local function ticket_live(root, ticket)
	return is_configured and pending_restarts[root] == ticket
end

local function valid_buffers(lsp, buffers)
	local ordered = vim.tbl_keys(buffers)
	table.sort(ordered)
	local valid = {}
	for _, bufnr in ipairs(ordered) do
		local ok, keep = true, true
		if type(lsp.buffer_valid) == "function" then
			ok, keep = pcall(lsp.buffer_valid, bufnr)
		end
		if not ok then
			return nil, "could not validate clangd buffer " .. tostring(bufnr) .. ": " .. tostring(keep)
		end
		if keep then
			valid[#valid + 1] = bufnr
		end
	end
	return valid
end

local function merge_buffers(target, source)
	for _, bufnr in ipairs(source or {}) do
		if type(bufnr) ~= "number" or bufnr < 1 or bufnr % 1 ~= 0 then
			return nil, "clangd reconciliation returned an invalid buffer"
		end
		target[bufnr] = true
	end
	return target
end

local function reconcile_clients(lsp, root, buffers)
	if type(lsp.reconcile) ~= "function" then
		return nil, "cannot reconcile autoactivated clangd clients: reconcile callback is missing"
	end
	local ok, extra, reconcile_err = pcall(lsp.reconcile, root, configured.restart_timeout_ms)
	if not ok then
		return nil, "could not reconcile autoactivated clangd clients: " .. tostring(extra)
	end
	if type(extra) ~= "table" or not vim.islist(extra) then
		return nil,
			"could not reconcile autoactivated clangd clients: " .. tostring(
				reconcile_err or "callback did not return a buffer list"
			)
	end
	local merged, merge_err = merge_buffers(buffers, extra)
	if not merged then
		return nil, merge_err
	end
	return valid_buffers(lsp, merged)
end

local function discard_started(lsp, client_id, root)
	if type(lsp.discard) ~= "function" then
		return nil, "discard callback is missing"
	end
	local ok, discarded, discard_err = pcall(lsp.discard, client_id, root, configured.restart_timeout_ms)
	if not ok then
		return nil, tostring(discarded)
	end
	if discarded ~= true then
		return nil, tostring(discard_err or "owned client did not stop")
	end
	return true
end

local function start_configuration(lsp, root, active, buffers)
	if
		type(lsp.config) ~= "function"
		or type(lsp.start) ~= "function"
		or type(lsp.attach) ~= "function"
		or type(lsp.wait_initialized) ~= "function"
	then
		return nil, "clangd restart callbacks are incomplete", true, buffers
	end
	local config_ok, config = pcall(lsp.config, root, copy(active))
	if not config_ok then
		return nil, "could not build clangd restart config: " .. tostring(config), true, buffers
	end
	if type(config) ~= "table" then
		return nil, "could not build clangd restart config", true, buffers
	end
	local buffer_set = {}
	for _, bufnr in ipairs(buffers) do
		buffer_set[bufnr] = true
	end
	local reconciled, reconcile_err = reconcile_clients(lsp, root, buffer_set)
	if not reconciled then
		return nil, reconcile_err, false, buffers
	end
	if #reconciled == 0 then
		return { skipped = true, buffers = reconciled }
	end
	local start_ok, outcome = pcall(lsp.start, config)
	if not start_ok then
		return nil, "clangd restart raised an error: " .. tostring(outcome), false, reconciled
	end
	if type(outcome) ~= "table" then
		return nil, "clangd restart returned an invalid ownership outcome", false, reconciled
	end
	if outcome.owned ~= true or type(outcome.client_id) ~= "number" or outcome.client_id < 1 then
		if outcome.owned == false and outcome.client_id == nil then
			return nil, tostring(outcome.error or "clangd restart failed"), true, reconciled
		end
		return nil, "clangd restart returned an invalid ownership outcome", false, reconciled
	end
	for _, bufnr in ipairs(reconciled) do
		local attached_ok, attached = pcall(lsp.attach, bufnr, outcome.client_id)
		if not attached_ok or attached ~= true then
			local attach_err = ("could not attach clangd to buffer %d: %s"):format(
				bufnr,
				tostring(attached_ok and "rejected" or attached)
			)
			local discarded, discard_err = discard_started(lsp, outcome.client_id, root)
			if not discarded then
				return nil, attach_err .. "; could not discard owned client: " .. discard_err, false, reconciled
			end
			return nil, attach_err, true, reconciled
		end
	end
	local wait_ok, initialized, initialize_err =
		pcall(lsp.wait_initialized, outcome.client_id, root, configured.restart_timeout_ms)
	if not wait_ok or initialized ~= true then
		local message = wait_ok and tostring(initialize_err or "clangd did not initialize")
			or "could not confirm clangd initialization: " .. tostring(initialized)
		local discarded, discard_err = discard_started(lsp, outcome.client_id, root)
		if not discarded then
			return nil, message .. "; could not discard owned client: " .. discard_err, false, reconciled
		end
		return nil, message, true, reconciled
	end
	return { client_id = outcome.client_id, buffers = reconciled }
end

local schedule_restart

local function finish_restart(root, ticket, attempted_revision)
	if pending_restarts[root] ~= ticket then
		return
	end
	local followup_force = ticket.followup_force == true
	pending_restarts[root] = nil
	if is_configured and (state_for(root).active_revision ~= attempted_revision or followup_force) then
		schedule_restart(root, followup_force)
	end
end

local function fail_after_stop(
	root,
	ticket,
	attempted_revision,
	message,
	rollback_safe,
	rollback_revision,
	rollback,
	lsp,
	buffers
)
	if not ticket_live(root, ticket) then
		return
	end
	if rollback_safe and rollback_revision ~= nil and not same_configuration(rollback, ticket.target) then
		local restored, restore_err = start_configuration(lsp, root, rollback, buffers)
		if not ticket_live(root, ticket) then
			return
		end
		if restored then
			local suffix = restore_err and "; " .. restore_err or ""
			publish(root, "error", { error = message .. "; previous clangd configuration restored" .. suffix })
			finish_restart(root, ticket, attempted_revision)
			return
		end
		message = message .. "; previous clangd configuration could not be restored: " .. tostring(restore_err)
	elseif not rollback_safe then
		message = message .. "; replacement outcome is uncertain, so rollback was not attempted"
	end
	mark_unapplied(root, message)
	finish_restart(root, ticket, attempted_revision)
end

local function restart_now(root, ticket)
	if pending_restarts[root] ~= ticket then
		return
	end
	ticket.scheduled = false
	ticket.running = true
	local attempted_revision = state_for(root).active_revision
	local rollback_revision = state_for(root).applied_revision
	local rollback = copy(state_for(root).applied)
	if not ticket.force and same_configuration(state_for(root).active, rollback) and rollback_revision ~= nil then
		mark_applied(root, attempted_revision, state_for(root).active)
		finish_restart(root, ticket, attempted_revision)
		return
	end
	local lsp = configured.lsp
	if type(lsp) ~= "table" then
		mark_applied(root, attempted_revision, state_for(root).active)
		finish_restart(root, ticket, attempted_revision)
		return
	end
	local buffers = {}
	local stopped_for_root = {}
	if type(lsp.clients) ~= "function" then
		publish(root, "error", { error = "cannot enumerate clangd clients: clients callback is missing" })
		finish_restart(root, ticket, attempted_revision)
		return
	end
	local clients_ok, clients = pcall(lsp.clients, root)
	if not ticket_live(root, ticket) then
		return
	end
	if not clients_ok or type(clients) ~= "table" then
		publish(root, "error", { error = "could not enumerate clangd clients: " .. tostring(clients) })
		finish_restart(root, ticket, attempted_revision)
		return
	end
	for _, client in ipairs(clients or {}) do
		local root_ok, current_root = pcall(client_root, lsp, client)
		if not root_ok then
			publish(root, "error", { error = "could not inspect clangd client root: " .. tostring(current_root) })
			finish_restart(root, ticket, attempted_revision)
			return
		end
		if current_root == root then
			stopped_for_root[#stopped_for_root + 1] = client
			for bufnr in pairs(client.attached_buffers or {}) do
				buffers[bufnr] = true
			end
		end
	end
	if #stopped_for_root == 0 then
		local revision = state_for(root).active_revision
		mark_applied(root, revision, state_for(root).active)
		finish_restart(root, ticket, revision)
		return
	end
	if type(lsp.stop) ~= "function" then
		mark_unapplied(root, "cannot stop existing clangd clients: stop callback is missing")
		finish_restart(root, ticket, attempted_revision)
		return
	end
	for _, client in ipairs(stopped_for_root) do
		local stop_ok, stop_err = pcall(lsp.stop, client)
		if not ticket_live(root, ticket) then
			return
		end
		if not stop_ok then
			mark_unapplied(root, "could not stop clangd: " .. tostring(stop_err))
			finish_restart(root, ticket, attempted_revision)
			return
		end
	end
	local stopped, stopped_err = stopped_clients(lsp, stopped_for_root, root)
	if not ticket_live(root, ticket) then
		return
	end
	if not stopped then
		mark_unapplied(root, stopped_err)
		finish_restart(root, ticket, attempted_revision)
		return
	end
	local valid, valid_err = valid_buffers(lsp, buffers)
	if not ticket_live(root, ticket) then
		return
	end
	if not valid then
		mark_unapplied(root, valid_err)
		finish_restart(root, ticket, attempted_revision)
		return
	end
	local state = state_for(root)
	local target_revision = state.active_revision
	local target = copy(state.active)
	ticket.target = target
	if #valid == 0 then
		mark_applied(root, target_revision, target)
		finish_restart(root, ticket, target_revision)
		return
	end
	local outcome, start_err, rollback_safe, reconciled = start_configuration(lsp, root, target, valid)
	if not ticket_live(root, ticket) then
		return
	end
	if not outcome then
		fail_after_stop(
			root,
			ticket,
			target_revision,
			start_err,
			rollback_safe,
			rollback_revision,
			rollback,
			lsp,
			reconciled or valid
		)
		return
	end
	mark_applied(root, target_revision, target)
	finish_restart(root, ticket, target_revision)
end

schedule_restart = function(root, force)
	local state = state_for(root)
	local pending = pending_restarts[root]
	if pending then
		pending.requested_revision = state.active_revision
		if pending.running and force == true then
			pending.followup_force = true
		else
			pending.force = pending.force or force == true
		end
		return
	end
	local ticket = {
		requested_revision = state.active_revision,
		scheduled = true,
		running = false,
		force = force == true,
	}
	pending_restarts[root] = ticket
	local defer = configured.defer or vim.defer_fn
	defer(function()
		restart_now(root, ticket)
	end, configured.restart_delay_ms)
end

function M.apply(root, options)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	options = options or {}
	local state = state_for(root)
	local record = best_candidate(state, options.provider)
	if not record then
		local err = "no compile database candidate"
		publish(root, "error", { error = err })
		return nil, err
	end
	local refreshed, refresh_err = refresh_record(record, options)
	if not refreshed then
		local retryable_policy = refresh_err:find("use bang", 1, true) ~= nil
		if not retryable_policy then
			if record.provider == "manual" then
				state.override = nil
			else
				state.candidates[record.provider] = nil
			end
		end
		publish(root, "error", { error = refresh_err }, { "candidate" })
		return nil, refresh_err
	end
	store_record(state, refreshed)
	if unchecked_requires_bang(state, refreshed, options) then
		local err = "unchecked compile database requires bang"
		publish(root, "error", { error = err, candidate = refreshed })
		return nil, err
	end
	local changed = advance_active_revision(state, refreshed)
	publish(root, "active", { active = refreshed }, { "candidate", "error" })
	if changed or not application_matches(state, refreshed) then
		schedule_restart(root)
	end
	return M.status(root, { refresh = false })
end

function M.set_provider(root, provider, directory, options)
	local candidate, err = M.candidate(root, provider, directory, options)
	if not candidate then
		return nil, err
	end
	return M.apply(root, { provider = provider, unchecked = options and options.unchecked })
end

function M.set_override(root, directory, options)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	local validated, err = M.validate(directory, options)
	if not validated then
		local state = state_for(root)
		state.override = nil
		publish(root, "error", { error = err }, { "candidate" })
		return nil, err
	end
	local state = state_for(root)
	state.override = vim.tbl_extend("force", validated, {
		provider = "manual",
		priority = math.huge,
	})
	publish(root, "candidate", { candidate = state.override }, { "error" })
	return M.apply(root, { unchecked = options and options.unchecked })
end

function M.clear_override(root)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	local state = state_for(root)
	state.override = nil
	local previous = state.active
	local fallback = best_candidate(state)
	if not fallback then
		advance_active_revision(state, nil)
		publish(root, "candidate", {}, { "active", "candidate", "error" })
		if previous or not application_matches(state, nil) then
			schedule_restart(root)
		end
		return M.status(root, { refresh = false })
	end

	local refreshed, refresh_err = refresh_record(fallback, {})
	if refreshed then
		store_record(state, refreshed)
	end
	local policy_err = refreshed
			and unchecked_requires_bang(state, refreshed, {})
			and "unchecked compile database requires bang"
		or nil
	local err = refresh_err or policy_err
	if err then
		if refresh_err and fallback.provider ~= "manual" then
			state.candidates[fallback.provider] = nil
		end
		local fields = { error = err }
		if refreshed then
			fields.candidate = refreshed
		end
		local clear = { "candidate" }
		if previous and previous.provider == "manual" then
			advance_active_revision(state, nil)
			clear[#clear + 1] = "active"
		end
		publish(root, "error", fields, clear)
		if previous and previous.provider == "manual" then
			schedule_restart(root)
		end
		return nil, err
	end

	local changed = advance_active_revision(state, refreshed)
	publish(root, "active", { active = refreshed }, { "candidate", "error" })
	if changed or not application_matches(state, refreshed) then
		schedule_restart(root)
	end
	return M.status(root, { refresh = false })
end

function M.active(root)
	root = canonical(root)
	local state = root and roots[root] or nil
	return state and copy(state.active) or nil
end

function M.status(root)
	if root == nil then
		return copy({
			configured = is_configured,
			pending_restarts = pending_restarts,
			providers = providers,
			roots = roots,
		})
	end
	root = canonical(root)
	local state = root and roots[root] or nil
	if not state then
		return {
			generation = 0,
			state = "candidate",
			root = root,
			candidate = nil,
			active = nil,
			active_revision = 0,
			applied_revision = 0,
			error = nil,
			restart_pending = false,
		}
	end
	local result = copy(state)
	result.root = root
	result.restart_pending = pending_restarts[root] ~= nil
	return result
end

function M.refresh(root)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	local state = state_for(root)
	if not state.active then
		return M.apply(root)
	end
	local previous = state.active
	local refreshed, refresh_err = refresh_record(previous, { unchecked = previous.validity == "unchecked" })
	if not refreshed then
		if state.state ~= "stale" or state.error ~= refresh_err then
			publish(root, "stale", { error = refresh_err, active = previous })
		end
		return nil, refresh_err, M.status(root)
	end
	store_record(state, refreshed)
	if same_record(previous, refreshed) then
		if state.state == "stale" or state.state == "error" then
			publish(root, "active", { active = refreshed }, { "candidate", "error" })
		end
		if not application_matches(state, refreshed) then
			schedule_restart(root)
		end
		return M.status(root)
	end
	advance_active_revision(state, refreshed)
	publish(root, "active", { active = refreshed }, { "candidate", "error" })
	schedule_restart(root)
	return M.status(root)
end

function M.restart(root)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	schedule_restart(root, true)
	return true
end

function M.command_directory(root)
	local active = M.active(root)
	return active and active.directory or nil
end

function M._reset_for_tests()
	configured = {}
	is_configured = false
	roots = {}
	providers = {}
	pending_restarts = {}
end

M.MAX_BYTES = MAX_BYTES

return M
