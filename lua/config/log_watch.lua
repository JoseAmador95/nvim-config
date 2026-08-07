local M = {}

-- Per-buffer follow state: buf -> watcher
local watchers = {}

local POLL_INTERVAL_MS = 500

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "LogWatch" })
end

local function is_watching(buf)
	return watchers[buf] ~= nil
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

local function close_poll(poll)
	if not poll then
		return
	end

	pcall(poll.stop, poll)
	local ok, closing = pcall(poll.is_closing, poll)
	if not ok or not closing then
		pcall(poll.close, poll)
	end
end

-- Reload the file from disk into the (read-only) buffer, keeping windows that
-- were parked at the bottom pinned to the new last line (tail -f behaviour).
local function reload(watcher)
	local buf = watcher.buf
	if watchers[buf] ~= watcher or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local ok, lines = pcall(vim.fn.readfile, watcher.name)
	if not ok then
		return
	end

	local old_count = vim.api.nvim_buf_line_count(buf)

	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modified = false

	local new_count = vim.api.nvim_buf_line_count(buf)

	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local cursor = vim.api.nvim_win_get_cursor(win)
		if cursor[1] >= old_count then
			pcall(vim.api.nvim_win_set_cursor, win, { new_count, 0 })
		end
	end
end

local function stop(buf, restore)
	local watcher = watchers[buf]
	if not watcher then
		return
	end

	-- Clear ownership first so an already-scheduled callback cannot touch the
	-- buffer after its original state has been restored.
	watchers[buf] = nil
	if watcher.autocmd then
		pcall(vim.api.nvim_del_autocmd, watcher.autocmd)
		watcher.autocmd = nil
	end
	close_poll(watcher.poll)

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

	local poll, poll_err = vim.uv.new_fs_poll()
	if not poll then
		notify("Could not create file watcher: " .. tostring(poll_err), vim.log.levels.ERROR)
		return false
	end

	local watcher = {
		buf = buf,
		poll = poll,
		name = name,
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
		vim.schedule_wrap(function(err)
			if err or watchers[buf] ~= watcher then
				return
			end
			reload(watcher)
		end)
	)
	if not started_ok or start_result == nil then
		watchers[buf] = nil
		close_poll(poll)
		local reason = started_ok and start_err or start_result
		notify("Could not start file watcher: " .. tostring(reason), vim.log.levels.ERROR)
		return false
	end

	-- Guarantee log-highlight colouring and the :LogHl* helpers make sense here.
	local configured, config_err = pcall(function()
		if vim.bo[buf].filetype ~= "log" then
			vim.bo[buf].filetype = "log"
		end
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
	end)
	if not configured then
		stop(buf)
		notify("Could not configure buffer for following: " .. tostring(config_err), vim.log.levels.ERROR)
		return false
	end

	-- Prime the buffer from disk and jump to the bottom like `tail -f`.
	reload(watcher)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
	end

	-- Tear the watcher down automatically if the buffer goes away.
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
