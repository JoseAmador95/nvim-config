local M = {}

-- Toggleable ripgrep options shown as an always-visible winbar at the top of
-- the grug-far panel. `--hidden` and the .git/node_modules excludes live
-- permanently in engines.ripgrep.extraArgs, so they are not listed here.
local OPTIONS = {
	{ flag = "--ignore-case", label = "Ignore case" },
	{ flag = "--word-regexp", label = "Whole word" },
	{ flag = "--fixed-strings", label = "Literal" },
	{ flag = "--no-ignore", label = "Ignored" },
}

-- Tracked on/off state per grug-far buffer (starts all-off, matching the
-- ripgrep defaults). Kept in sync from toggle_flags' authoritative return.
local state_by_buf = {}

-- Build the winbar string: one clickable region per option showing its state.
local function winbar_string(buf)
	local state = state_by_buf[buf] or {}
	local segs = { "%#Comment# Options:%* " }
	for i, opt in ipairs(OPTIONS) do
		local on = state[opt.flag] == true
		local box = on and "[x]" or "[ ]"
		local hl = on and "%#String#" or "%#NonText#"
		-- %<i>@fn@ ... %X : clicking calls fn(i, ...) via the mouse
		segs[#segs + 1] = "%" .. i .. "@v:lua.GrugFarWinbarClick@" .. hl .. " " .. box .. " " .. opt.label .. " %*%X"
	end
	return table.concat(segs, "")
end

-- Render / refresh the winbar for every window showing this grug-far buffer.
function M.render_winbar(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local ok, str = pcall(winbar_string, buf)
	if not ok then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		pcall(vim.api.nvim_set_option_value, "winbar", str, { win = win })
	end
end

-- Open the grug-far result under the cursor in a new tab, reusing the shared
-- tab-opening helper (which dedupes to an existing tab for the same file).
function M.open_entry_in_tab(buf)
	buf = buf or 0
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return
	end

	local inst = grug_far.get_instance(buf)
	if not inst then
		return
	end

	local resultsList = require("grug-far.render.resultsList")
	local loc = resultsList.getResultLocationAtCursor(inst._buf, inst._context)
	if not loc or not loc.filename then
		return
	end

	require("config.editor").open_file_in_tab(loc.filename, { lnum = loc.lnum, col = loc.col })
end

-- Toggle a single search flag on the grug-far instance, remember its state and
-- refresh the winbar. Returns the new boolean state (nil if unavailable).
function M.toggle_option(buf, flag)
	buf = buf or vim.api.nvim_get_current_buf()
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return nil
	end

	local inst = grug_far.get_instance(buf)
	if not inst then
		return nil
	end

	local states = inst:toggle_flags({ flag })
	local on = states and states[1] or false
	state_by_buf[buf] = state_by_buf[buf] or {}
	state_by_buf[buf][flag] = on
	M.render_winbar(buf)
	return on
end

-- Toggle the option at the given 1-based index (used by the winbar click).
function M.toggle_index(buf, idx)
	local opt = OPTIONS[idx]
	if not opt then
		return
	end
	M.toggle_option(buf, opt.flag)
end

-- Drop tracked state when a grug-far buffer goes away.
function M.forget(buf)
	state_by_buf[buf] = nil
end

-- Global click handler referenced from the winbar (%@v:lua.GrugFarWinbarClick@).
function _G.GrugFarWinbarClick(minwid)
	local buf
	local pos = vim.fn.getmousepos()
	if pos and pos.winid and pos.winid ~= 0 and vim.api.nvim_win_is_valid(pos.winid) then
		buf = vim.api.nvim_win_get_buf(pos.winid)
	end
	if not buf or vim.bo[buf].filetype ~= "grug-far" then
		buf = vim.api.nvim_get_current_buf()
	end
	if vim.bo[buf].filetype ~= "grug-far" then
		return
	end
	M.toggle_index(buf, minwid)
end

return M
