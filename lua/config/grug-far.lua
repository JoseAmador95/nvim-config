local M = {}

-- Create and enter a centered floating window holding a throwaway scratch
-- buffer, for grug-far to attach its own buffer to. Wired up as grug-far's
-- `windowCreationCommand`, so it runs both on the initial open and on every
-- toggle_instance re-show, keeping the panel floating each time (grug-far's
-- _createWindow runs this via vim.cmd, then grabs the current window).
function M.open_float_window()
	local width = math.floor(vim.o.columns * 0.9)
	local height = math.floor(vim.o.lines * 0.85)
	local scratch = vim.api.nvim_create_buf(false, true)
	-- wiped automatically once grug-far swaps its own buffer into the window
	vim.bo[scratch].bufhidden = "wipe"
	vim.api.nvim_open_win(scratch, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2 - 1),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		title = " Search & Replace ",
		title_pos = "center",
	})
end

-- Instance names whose search should survive opening a match: their float is
-- only hidden (the scratch buffer keeps the search), so <leader>fg re-floats
-- them intact. Every other instance -- the throwaway ones from <leader>fw /
-- "Search in File", which grug-far auto-names -- is wiped on match open so
-- hidden grug-far buffers don't pile up.
local PERSISTENT_INSTANCES = { far = true }

-- Resolve the grug-far result location under the cursor (nil if not on one).
local function location_at_cursor(buf)
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return nil
	end
	local inst = grug_far.get_instance(buf)
	if not inst then
		return nil
	end
	local resultsList = require("grug-far.render.resultsList")
	return resultsList.getResultLocationAtCursor(inst._buf, inst._context)
end

-- Name grug-far registered this buffer's instance under (nil if none).
local function instance_name(buf)
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return nil
	end
	local inst = grug_far.get_instance(buf)
	local ctx = inst and inst._context
	return ctx and ctx.options and ctx.options.instanceName or nil
end

-- Toggle the fold holding a file's match lines. The cursor sits on the file
-- path line (fold level 0); its matches below are level 1, so we toggle the
-- fold that starts on the next line and leave the cursor where it was.
local function toggle_file_fold(buf)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local target = cursor[1] + 1
	vim.api.nvim_win_call(win, function()
		if vim.fn.foldlevel(target) == 0 then
			return
		end
		if vim.fn.foldclosed(target) == -1 then
			vim.cmd(target .. "foldclose")
		else
			vim.cmd(target .. "foldopen")
		end
	end)
	pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

-- Close the floating panel via window/buffer API calls, which dismiss the
-- float reliably (the :quit ex command sometimes doesn't on this float, but
-- nvim_win_close / nvim_buf_delete always do). Persistent instances (far) are
-- only hidden -- their scratch buffer (bufhidden=hide) keeps the search, so
-- <leader>fg re-floats them intact. Throwaway instances (<leader>fw, "Search
-- in File") are wiped instead: deleting the buffer closes its float and fires
-- grug-far's BufUnload cleanup, so hidden grug-far buffers don't accumulate.
function M.dismiss(buf)
	if not buf or buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	if PERSISTENT_INSTANCES[instance_name(buf) or ""] then
		local win = vim.fn.bufwinid(buf)
		if win ~= -1 then
			vim.api.nvim_win_close(win, true)
		end
	elseif vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

-- <CR> handler: on a file path line, toggle that file's results fold; on a
-- match line, open the match in a new tab (dedupes to an existing tab).
function M.on_enter(buf)
	if not buf or buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	local loc = location_at_cursor(buf)
	if not loc or not loc.filename then
		return
	end

	if not loc.lnum then
		-- file path line (no match line number) -> toggle its fold
		toggle_file_fold(buf)
		return
	end

	-- Get the panel out of the way before jumping to the match so it doesn't
	-- linger behind the file (the search still persists for the "far" instance).
	M.dismiss(buf)

	require("config.editor").open_file_in_tab(loc.filename, { lnum = loc.lnum, col = loc.col })
end

-- QuitPre handler for :q / :quit issued from the panel. On this float the ex
-- command often fails to close the window, so we finish the job from the API
-- after the command runs: dismiss() force-closes it if it's still open (and is
-- a no-op / leak cleanup if :quit already closed it).
function M.on_quit(buf)
	if not buf or buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	vim.schedule(function()
		M.dismiss(buf)
	end)
end

-- Toggle a ripgrep flag in the grug-far Flags input. The current flags are
-- shown in the panel itself, so no extra feedback is emitted here.
function M.toggle_option(buf, flag)
	buf = buf or 0
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return
	end

	local inst = grug_far.get_instance(buf)
	if inst then
		inst:toggle_flags({ flag })
	end
end

return M
