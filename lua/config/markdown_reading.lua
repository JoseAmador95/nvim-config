-- lua/config/markdown_reading.lua
-- Obsidian-style reading view for markdown, coupled to render-markdown's
-- enabled state.
--
-- When render-markdown renders a buffer we center the content with
-- no-neck-pain and strip editor chrome (numbers, sign/fold columns,
-- cursorline) while turning on soft wrapping; when it clears the buffer we
-- undo all of that. The coupling is driven by render-markdown's `on.render`
-- and `on.clear` callbacks (see lua/plugins/render-markdown.lua), so toggling
-- the render (`:MarkdownRender`) toggles the reading view in lockstep.
--
-- `on.render` fires on every render, so enable()/disable() are idempotent and
-- guarded per tab-page (no-neck-pain itself is tab-scoped).

local M = {}

-- [tabpage handle] = { win = <content window that we decluttered> }
local active = {}

-- Window options overridden in the content window for a clean reading view.
local function declutter(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		vim.cmd(
			"setlocal nonumber norelativenumber signcolumn=no foldcolumn=0 nocursorline wrap linebreak breakindent"
		)
	end)
end

-- Restore each overridden option to its global value (the `<` suffix), so we
-- inherit the defaults from init.lua instead of hardcoding them here.
local function restore(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		vim.cmd(
			"setlocal number< relativenumber< signcolumn< foldcolumn< cursorline< wrap< linebreak< breakindent<"
		)
	end)
end

-- Drop entries for tab-pages that no longer exist.
local function prune()
	for tab in pairs(active) do
		if not vim.api.nvim_tabpage_is_valid(tab) then
			active[tab] = nil
		end
	end
end

function M.enable()
	-- The pager (nvimpager) loads render-markdown but not no-neck-pain, and a
	-- centered read-only view there adds nothing -- bail out early.
	if require("config.pager").active then
		return
	end
	if not pcall(require, "no-neck-pain") then
		return
	end

	prune()
	local tab = vim.api.nvim_get_current_tabpage()
	if active[tab] then
		return
	end

	local win = vim.api.nvim_get_current_win()
	active[tab] = { win = win }

	-- Guard the window mutation: if no-neck-pain refuses (e.g. textlock during
	-- a render), clear our flag so a later render retries instead of getting
	-- wedged, and never let the error bubble into render-markdown's pipeline.
	local ok = pcall(function()
		require("no-neck-pain").enable()
	end)
	if not ok then
		active[tab] = nil
		return
	end

	declutter(win)
end

function M.disable()
	local tab = vim.api.nvim_get_current_tabpage()
	local state = active[tab]
	if not state then
		return
	end
	active[tab] = nil

	local ok, nnp = pcall(require, "no-neck-pain")
	if ok then
		pcall(nnp.disable)
	end
	restore(state.win)
end

return M
