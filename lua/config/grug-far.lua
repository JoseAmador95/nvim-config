local M = {}

-- Toggleable ripgrep options exposed as a friendly UI (instead of typing raw
-- flags into the Flags input). `--hidden` and the .git/node_modules excludes
-- live permanently in engines.ripgrep.extraArgs, so they are not listed here.
local OPTIONS = {
	{ flag = "--ignore-case", label = "Ignore case" },
	{ flag = "--word-regexp", label = "Whole word" },
	{ flag = "--fixed-strings", label = "Literal (no regex)" },
	{ flag = "--no-ignore", label = "Include ignored files" },
}

-- Tracked on/off state per grug-far buffer (starts all-off, matching the
-- ripgrep defaults). Kept in sync from toggle_flags' authoritative return.
local state_by_buf = {}

local function label_for(flag)
	for _, opt in ipairs(OPTIONS) do
		if opt.flag == flag then
			return opt.label
		end
	end
	return flag
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

-- Toggle a single search flag on the grug-far instance and remember its state.
-- Returns the new boolean state (or nil if grug-far is unavailable).
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
	vim.notify(
		"grug-far: " .. label_for(flag) .. " " .. (on and "ON" or "OFF"),
		vim.log.levels.INFO,
		{ title = "Search" }
	)
	return on
end

-- Popup menu (via vim.ui.select -> snacks) listing every option with a
-- checkbox reflecting its current state. Selecting one toggles it and reopens
-- the menu so several options can be flipped in a row (<Esc> closes it).
function M.options_menu(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local state = state_by_buf[buf] or {}

	local items = {}
	for _, opt in ipairs(OPTIONS) do
		table.insert(items, { flag = opt.flag, label = opt.label, on = state[opt.flag] == true })
	end

	vim.ui.select(items, {
		prompt = "Search options",
		format_item = function(item)
			return string.format("[%s] %s", item.on and "x" or " ", item.label)
		end,
	}, function(choice)
		if not choice then
			return
		end
		M.toggle_option(buf, choice.flag)
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(buf) then
				M.options_menu(buf)
			end
		end)
	end)
end

-- Register our custom actions into grug-far's own action registry so they show
-- up in the native help window (g?) alongside the built-ins, with their key and
-- description. This keeps discovery context-local (no which-key, no hidden
-- prefix) — the user just presses g? to see everything that applies here.
function M.register_actions(buf)
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return
	end

	local inst = grug_far.get_instance(buf)
	if not inst then
		return
	end

	local context = inst._context
	if not context or not context.actions then
		return
	end

	local actions = {
		{
			text = "Search Options",
			keymap = { n = "<localleader>m" },
			description = "Toggle search options: ignore-case, whole-word, literal, include-ignored.",
			action = function()
				M.options_menu(buf)
			end,
		},
	}

	local utils = require("grug-far.utils")
	for _, action in ipairs(actions) do
		local already = false
		for _, existing in ipairs(context.actions) do
			if existing.text == action.text then
				already = true
				break
			end
		end
		if not already then
			table.insert(context.actions, action)
			utils.setBufKeymap(buf, action.text, action.keymap, action.action)
		end
	end
end

-- Drop tracked state when a grug-far buffer goes away.
function M.forget(buf)
	state_by_buf[buf] = nil
end

return M
