-- Host-owned vim.notify lifecycle broker.
--
-- Providers acquire generation-bound leases instead of replacing vim.notify.
-- The newest live provider owns dispatch; failures and stale scheduled work fall
-- back through the function that was installed before the broker.
local M = {}

local state = {
	base = nil,
	dispatcher = nil,
	fallback = nil,
	fallback_depth = 0,
	generation = 0,
	installed = false,
	leases = {},
	next_id = 0,
}

local function fallback_notify(fallback, message, level, options)
	local target = fallback
	if target == state.dispatcher or state.fallback_depth > 0 then
		target = state.base
	end
	if type(target) ~= "function" or target == state.dispatcher then
		return nil
	end

	state.fallback_depth = state.fallback_depth + 1
	local ok, result = pcall(target, message, level, options)
	state.fallback_depth = state.fallback_depth - 1
	if state.installed and vim.notify ~= state.dispatcher then
		-- Some providers lazily replace vim.notify on their first call. Preserve
		-- that resolved function as the next fallback, then reclaim ownership.
		state.fallback = vim.notify
		vim.notify = state.dispatcher
	end
	return ok and result or nil
end

local function active_lease()
	for index = #state.leases, 1, -1 do
		local lease = state.leases[index]
		if lease.active and not lease.dispatching then
			return lease
		end
	end
	return nil
end

local function dispatch(lease, generation, fallback, message, level, options)
	if lease and lease.active and generation == state.generation and active_lease() == lease then
		lease.dispatching = true
		local ok, result = pcall(lease.handler, message, level, options)
		lease.dispatching = false
		if ok then
			return result
		end
	end
	return fallback_notify(fallback, message, level, options)
end

local function broker_notify(message, level, options)
	local lease = active_lease()
	local generation = state.generation
	local fallback = state.fallback or state.base
	if vim.in_fast_event() then
		local scheduled_message = message
		if type(message) == "table" then
			local copied, value = pcall(vim.deepcopy, message)
			scheduled_message = copied and value or message
		end
		vim.schedule(function()
			-- A provider released or superseded before this callback must never be
			-- called. Use the fallback captured with the original notification.
			dispatch(lease, generation, fallback, scheduled_message, level, options)
		end)
		return nil
	end
	return dispatch(lease, generation, fallback, message, level, options)
end

function M.setup()
	if not state.dispatcher then
		state.dispatcher = broker_notify
	end
	if not state.base then
		state.base = vim.notify
	end
	if vim.notify ~= state.dispatcher then
		state.fallback = vim.notify
		vim.notify = state.dispatcher
	end
	state.installed = true
	return true
end

function M.acquire(name, handler)
	if type(name) ~= "string" or name == "" then
		return nil, "notification provider name must be a non-empty string"
	end
	if type(handler) ~= "function" then
		return nil, "notification provider handler must be a function"
	end
	M.setup()
	state.next_id = state.next_id + 1
	state.generation = state.generation + 1
	local token = { id = state.next_id, generation = state.generation, name = name }
	state.leases[#state.leases + 1] = {
		active = true,
		dispatching = false,
		handler = handler,
		name = name,
		token = token,
	}
	return token
end

function M.release(token)
	if type(token) ~= "table" then
		return false
	end
	for index = #state.leases, 1, -1 do
		local lease = state.leases[index]
		if lease.token == token then
			if not lease.active then
				return false
			end
			lease.active = false
			table.remove(state.leases, index)
			state.generation = state.generation + 1
			return true
		end
	end
	return false
end

function M.status()
	local active = active_lease()
	return {
		active = active and active.name or nil,
		generation = state.generation,
		installed = state.installed and vim.notify == state.dispatcher,
		leases = #state.leases,
	}
end

function M.teardown()
	for _, lease in ipairs(state.leases) do
		lease.active = false
	end
	state.leases = {}
	state.generation = state.generation + 1
	state.installed = false
	local restore = state.fallback
	if vim.notify == state.dispatcher and type(restore) == "function" then
		vim.notify = restore
	end
	-- A wrapper retained by another owner may still call the old dispatcher.
	-- Point that stale call straight at the original function, not back into the
	-- wrapper that retained it.
	state.fallback = state.base
	return true
end

return M
