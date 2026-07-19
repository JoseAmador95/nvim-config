-- Obsidian-style "readable line length" for markdown: auto-open Snacks.zen
-- (centered ~80-col float, view-only) when entering a markdown buffer, and
-- close it again when the zen window ends up showing a non-markdown buffer.
-- :MarkdownZenAuto toggles the automatic behaviour; <leader>z stays manual.
local M = {}

-- The zen window we auto-opened. Manual zen sessions (<leader>z) are never
-- auto-closed, only this one.
local auto_win = nil

-- NOTE: win:valid() also requires the window to still display win.buf, which
-- is false mid buffer-switch (BufEnter fires before snacks syncs win.buf), so
-- check only the window handle here.
local function zen_win()
	local win = Snacks.zen.win
	if win ~= nil and win:win_valid() then
		return win
	end
end

local function is_markdown(buf)
	return vim.bo[buf].filetype == "markdown" and vim.bo[buf].buftype == ""
end

local function wants_zen(buf)
	return vim.g.markdown_zen_auto ~= false and is_markdown(buf)
end

local function on_enter(event)
	local zen = zen_win()
	if zen then
		-- Buffer in the auto-opened zen window switched to non-markdown (e.g.
		-- picked a code file from within zen): close the float. Deferred so
		-- snacks first syncs the new buffer to the parent window.
		if zen == auto_win and vim.api.nvim_get_current_win() == zen.win and not is_markdown(event.buf) then
			vim.schedule(function()
				if zen:win_valid() then
					zen:close()
				end
			end)
		end
		return
	end
	local buf = event.buf
	if not wants_zen(buf) then
		return
	end
	-- Only auto-open from a regular window; floats (pickers, previews) must
	-- not spawn zen underneath themselves.
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		return
	end
	-- Schedule so the float opens after the autocmd chain settles.
	vim.schedule(function()
		if not zen_win() and vim.api.nvim_get_current_buf() == buf and wants_zen(buf) then
			Snacks.zen()
			auto_win = zen_win()
		end
	end)
end

function M.setup()
	local group = vim.api.nvim_create_augroup("MarkdownZen", { clear = true })

	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "markdown",
		callback = function(event)
			-- Word-level wrapping also outside zen ('wrap' is already on by
			-- default), and wrapped list lines aligned under their bullet text.
			vim.opt_local.linebreak = true
			vim.opt_local.breakindent = true
			vim.opt_local.breakindentopt = "list:-1"
			on_enter(event)
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = on_enter,
	})

	vim.api.nvim_create_user_command("MarkdownZenAuto", function()
		vim.g.markdown_zen_auto = vim.g.markdown_zen_auto == false
		vim.notify(
			"Markdown auto-zen " .. (vim.g.markdown_zen_auto ~= false and "enabled" or "disabled"),
			vim.log.levels.INFO
		)
	end, { desc = "Toggle automatic zen mode for markdown buffers" })
end

return M
