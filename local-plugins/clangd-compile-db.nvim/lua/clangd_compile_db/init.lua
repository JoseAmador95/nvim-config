local M = {}

local uv = vim.uv
local configured = {}
local roots = {}
local providers = {}
local pending_restarts = {}
local MAX_BYTES = 256 * 1024 * 1024

local function copy(value)
	return vim.deepcopy(value)
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
		state = { generation = 0, state = "candidate", candidates = {} }
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
	if type(configured.events) == "function" then
		configured.events("status", M.status(root, { refresh = false }))
	end
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

local function read_file(path, size)
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, tostring(open_err)
	end
	local stat = uv.fs_fstat(fd)
	if not stat or stat.type ~= "file" or stat.size ~= size then
		uv.fs_close(fd)
		return nil, "compile_commands.json changed while opening"
	end
	local data, read_err = uv.fs_read(fd, size, 0)
	uv.fs_close(fd)
	if type(data) ~= "string" or #data ~= size then
		return nil, tostring(read_err or "short read")
	end
	return data
end

function M.validate(directory, options)
	options = options or {}
	local expanded = canonical(directory)
	local directory_stat = expanded and uv.fs_stat(expanded) or nil
	if not directory_stat or directory_stat.type ~= "directory" then
		return nil, "not a directory: " .. tostring(expanded or directory)
	end
	local path = vim.fs.joinpath(expanded, "compile_commands.json")
	local stat = uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil, "compile_commands.json not found in " .. expanded
	end
	if stat.size > MAX_BYTES then
		if options.unchecked ~= true then
			return nil, ("compile_commands.json exceeds %d bytes; use bang to apply unchecked"):format(MAX_BYTES)
		end
		return {
			directory = expanded,
			path = path,
			size = stat.size,
			validity = "unchecked",
			fingerprint = fingerprint(stat),
		}
	end
	local data, read_err = read_file(path, stat.size)
	if not data then
		return nil, "could not read " .. path .. ": " .. tostring(read_err)
	end
	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or not vim.islist(decoded) then
		return nil, "invalid compile_commands.json in " .. expanded .. " (expected a JSON array)"
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
	configured = vim.tbl_extend("force", {}, opts or {})
	return M
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
		local state = publish(root, "error", { error = err }, { "candidate" })
		return nil, err, copy(state)
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

local function client_root(lsp, client)
	if type(lsp.client_root) == "function" then
		return canonical(lsp.client_root(client))
	end
	return canonical(client.config and client.config.root_dir)
end

local function restart_now(root)
	pending_restarts[root] = nil
	local lsp = configured.lsp
	if type(lsp) ~= "table" then
		return
	end
	local buffers = {}
	local clients = type(lsp.clients) == "function" and lsp.clients(root) or {}
	for _, client in ipairs(clients or {}) do
		if client_root(lsp, client) == root then
			for bufnr in pairs(client.attached_buffers or {}) do
				buffers[bufnr] = true
			end
			if type(lsp.stop) == "function" then
				lsp.stop(client)
			end
		end
	end
	local ordered = vim.tbl_keys(buffers)
	table.sort(ordered)
	local valid = {}
	for _, bufnr in ipairs(ordered) do
		if type(lsp.buffer_valid) ~= "function" or lsp.buffer_valid(bufnr) then
			valid[#valid + 1] = bufnr
		end
	end
	if #valid == 0 or type(lsp.config) ~= "function" or type(lsp.start) ~= "function" then
		return
	end
	local config = lsp.config(root, M.active(root))
	local client = lsp.start(config, valid[1])
	if not client then
		publish(root, "error", { error = "clangd restart failed" })
		return
	end
	if type(lsp.attach) == "function" then
		for index = 2, #valid do
			lsp.attach(valid[index], client)
		end
	end
end

local function schedule_restart(root)
	if pending_restarts[root] then
		return
	end
	pending_restarts[root] = true
	local defer = configured.defer or vim.defer_fn
	defer(function()
		restart_now(root)
	end, tonumber(configured.restart_delay_ms) or 100)
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
	if record.validity == "unchecked" and options.unchecked ~= true and not same_record(state.active, record) then
		local err = "unchecked compile database requires bang"
		publish(root, "error", { error = err })
		return nil, err
	end
	local changed = not same_record(state.active, record)
	publish(root, "active", { active = record }, { "candidate", "error" })
	if changed then
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
	return M.apply(root)
end

function M.active(root)
	root = canonical(root)
	local state = root and roots[root] or nil
	return state and copy(state.active) or nil
end

local function refresh_stale(root, state)
	if not state.active then
		return
	end
	local current = M.validate(state.active.directory, { unchecked = state.active.validity == "unchecked" })
	if (not current or current.fingerprint ~= state.active.fingerprint) and state.state ~= "stale" then
		publish(root, "stale", { error = "active compile database changed", active = state.active })
	end
end

function M.status(root, options)
	root = canonical(root)
	local state = root and roots[root] or nil
	if not state then
		return {
			generation = 0,
			state = "candidate",
			root = root,
			candidate = nil,
			active = nil,
			error = nil,
		}
	end
	if not options or options.refresh ~= false then
		refresh_stale(root, state)
		state = roots[root]
	end
	local result = copy(state)
	result.root = root
	return result
end

function M.restart(root)
	root = canonical(root)
	if not root then
		return nil, "invalid project root"
	end
	schedule_restart(root)
	return true
end

function M.command_directory(root)
	local active = M.active(root)
	return active and active.directory or nil
end

function M._reset_for_tests()
	configured = {}
	roots = {}
	providers = {}
	pending_restarts = {}
end

M.MAX_BYTES = MAX_BYTES

return M
