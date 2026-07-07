local M = {}

-- Per-buffer follow state: buf -> { poll = uv_fs_poll, name = string }
local watchers = {}

local POLL_INTERVAL_MS = 500

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "LogWatch" })
end

local function is_watching(buf)
	return watchers[buf] ~= nil
end

-- Reload the file from disk into the (read-only) buffer, keeping windows that
-- were parked at the bottom pinned to the new last line (tail -f behaviour).
local function reload(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return
	end

	local ok, lines = pcall(vim.fn.readfile, name)
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

local function stop(buf)
	local watcher = watchers[buf]
	if not watcher then
		return
	end

	if watcher.poll then
		watcher.poll:stop()
		if not watcher.poll:is_closing() then
			watcher.poll:close()
		end
	end
	watchers[buf] = nil

	if vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.bo[buf].readonly = false
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

	-- Guarantee log-highlight colouring and the :LogHl* helpers make sense here.
	if vim.bo[buf].filetype ~= "log" then
		vim.bo[buf].filetype = "log"
	end

	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true

	local poll = vim.uv.new_fs_poll()
	if not poll then
		notify("Could not create file watcher", vim.log.levels.ERROR)
		vim.bo[buf].modifiable = true
		vim.bo[buf].readonly = false
		return false
	end

	watchers[buf] = { poll = poll, name = name }

	poll:start(
		name,
		POLL_INTERVAL_MS,
		vim.schedule_wrap(function(err)
			if err then
				return
			end
			reload(buf)
		end)
	)

	-- Prime the buffer from disk and jump to the bottom like `tail -f`.
	reload(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
	end

	-- Tear the watcher down automatically if the buffer goes away.
	vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
		buffer = buf,
		once = true,
		callback = function()
			stop(buf)
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
