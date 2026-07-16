local M = {}

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

-- <CR> handler: on a file path line, toggle that file's results fold; on a
-- match line, open the match in a new tab (dedupes to an existing tab).
function M.on_enter(buf)
	buf = buf or 0
	local loc = location_at_cursor(buf)
	if not loc or not loc.filename then
		return
	end

	if not loc.lnum then
		-- file path line (no match line number) -> toggle its fold
		toggle_file_fold(buf)
		return
	end

	require("config.editor").open_file_in_tab(loc.filename, { lnum = loc.lnum, col = loc.col })
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
