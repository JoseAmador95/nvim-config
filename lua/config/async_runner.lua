-- A small generation-aware wrapper around vim.system. Each runner owns at most
-- one child process and one queued request. New work invalidates the old
-- generation immediately, asks the active child to stop, and coalesces queued
-- work to the latest request.
local M = {}

local Runner = {}
Runner.__index = Runner

local function default_spawn(command, options, callback)
	return vim.system(command, options, callback)
end

local function default_schedule(callback)
	vim.schedule(callback)
end

local function report_callback_error(err)
	vim.schedule(function()
		vim.notify("Async callback failed: " .. tostring(err), vim.log.levels.ERROR, { title = "AsyncRunner" })
	end)
end

local function invoke(callback, ...)
	if not callback then
		return
	end
	local ok, err = pcall(callback, ...)
	if not ok then
		report_callback_error(err)
	end
end

function Runner:_stop_timer()
	local timer = self.timer
	self.timer = nil
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local ok, closing = pcall(timer.is_closing, timer)
	if not ok or not closing then
		pcall(timer.close, timer)
	end
end

function Runner:_discard_pending(reason)
	local pending = self.pending
	self.pending = nil
	if pending then
		invoke(pending.spec.on_finish, nil, false, reason or "superseded")
	end
end

function Runner:_cancel_running()
	local running = self.running
	if not running or running.cancel_sent then
		return
	end
	running.cancel_sent = true
	if running.handle and running.handle.kill then
		pcall(running.handle.kill, running.handle, 15)
	end
end

function Runner:_advance()
	self.generation = self.generation + 1
	self:_stop_timer()
	self:_discard_pending("superseded")
	self:_cancel_running()
	return self.generation
end

function Runner:_start(entry)
	if self.closed or entry.generation ~= self.generation then
		invoke(entry.spec.on_finish, nil, false, "stale")
		return
	end

	local job = {
		generation = entry.generation,
		spec = entry.spec,
		finished = false,
	}
	self.running = job

	local function finished(result)
		if job.finished then
			return
		end
		job.finished = true
		self.schedule(function()
			if self.running == job then
				self.running = nil
			end
			local delivered = not self.closed and job.generation == self.generation
			invoke(job.spec.on_finish, result, delivered, delivered and nil or "stale")
			if delivered then
				invoke(job.spec.on_result, result)
			end

			local pending = self.pending
			self.pending = nil
			if pending then
				self:_start(pending)
			end
		end)
	end

	local ok, handle = pcall(self.spawn, entry.spec.command, entry.spec.options or {}, finished)
	if not ok then
		finished({ code = -1, stdout = "", stderr = tostring(handle), spawn_error = true })
	elseif not job.finished then
		job.handle = handle
	end
end

function Runner:_enqueue(spec, generation)
	if self.closed or generation ~= self.generation then
		invoke(spec.on_finish, nil, false, "stale")
		return nil
	end

	local entry = { generation = generation, spec = spec }
	if self.running then
		self:_discard_pending("superseded")
		self.pending = entry
		self:_cancel_running()
	else
		self:_start(entry)
	end
	return generation
end

-- Start a process now. `on_result` is called only for the newest generation;
-- `on_finish` always runs so per-process temporary files can be cleaned up.
function Runner:request(spec)
	assert(type(spec) == "table" and type(spec.command) == "table", "async request needs a command")
	if self.closed then
		invoke(spec.on_finish, nil, false, "closed")
		return nil
	end
	local generation = self:_advance()
	return self:_enqueue(spec, generation)
end

-- Invalidate current work immediately, then enqueue only the last factory
-- result after `delay_ms`. This prevents an old render from landing during the
-- debounce window.
function Runner:debounce(delay_ms, factory)
	assert(type(factory) == "function", "debounce needs a request factory")
	if self.closed then
		return nil
	end
	local generation = self:_advance()
	local timer = self.new_timer()
	if not timer then
		local spec = factory()
		return spec and self:_enqueue(spec, generation) or generation
	end
	self.timer = timer
	timer:start(
		delay_ms,
		0,
		vim.schedule_wrap(function()
			if self.timer == timer then
				self:_stop_timer()
			end
			if self.closed or generation ~= self.generation then
				return
			end
			local spec = factory()
			if spec then
				self:_enqueue(spec, generation)
			end
		end)
	)
	return generation
end

function Runner:invalidate()
	if not self.closed then
		return self:_advance()
	end
	return self.generation
end

function Runner:close()
	if self.closed then
		return
	end
	self:_advance()
	self.closed = true
end

function M.new(options)
	local opts = options or {}
	return setmetatable({
		spawn = opts.spawn or default_spawn,
		schedule = opts.schedule or default_schedule,
		new_timer = opts.new_timer or vim.uv.new_timer,
		generation = 0,
		closed = false,
	}, Runner)
end

return M
