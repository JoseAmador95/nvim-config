vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
vim.g.mapleader = " "

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local menu_opens = 0
local menu_dismisses = 0
package.loaded["config.pager"] = { active = false }
package.loaded["config.menu"] = {
	dismiss = function()
		menu_dismisses = menu_dismisses + 1
		return true
	end,
	ensure_open = function()
		menu_opens = menu_opens + 1
	end,
}

local tabs = require("config.tabs")
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, options)
	notifications[#notifications + 1] = { message = tostring(message), level = level, options = options }
end

local owned_paths = {}

local function drain()
	for _ = 1, 3 do
		local done = false
		vim.schedule(function()
			done = true
		end)
		assert(
			vim.wait(500, function()
				return done
			end, 5),
			"scheduled callbacks did not drain"
		)
	end
end

local function reset_editor()
	vim.o.hidden = true
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modified = false
		end
	end
	pcall(vim.cmd, "silent! tabonly!")
	pcall(vim.cmd, "silent! only!")
	vim.cmd("enew!")
	tabs.unmark_home(vim.api.nvim_get_current_tabpage())
	menu_opens = 0
	menu_dismisses = 0
	notifications = {}
end

local function named_buffer(label)
	local path = vim.fn.tempname() .. "-" .. label
	owned_paths[#owned_paths + 1] = path
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_name(buf, path)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label })
	vim.bo[buf].modified = false
	return buf
end

test("home requires an explicit marker and exactly one pristine normal window", function()
	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	assert(not tabs.is_home(home), "an arbitrary scratch tab became home")
	assert(tabs.mark_home(home), "clean scratch tab could not be marked")
	assert(tabs.is_home(home), "marked clean scratch tab is not home")

	vim.cmd("vsplit")
	assert(not tabs.is_home(home), "multi-split tab remained a valid home")
	vim.cmd("only")
	assert(tabs.is_home(home), "home did not recover after removing the split")

	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
	assert(not tabs.is_home(home), "modified scratch buffer remained home")
end)

test("closing the last work tab preserves its modified buffer and opens home", function()
	reset_editor()
	local target = vim.api.nvim_get_current_tabpage()
	local user_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "unsaved" })
	vim.bo[user_buf].modified = true

	assert(tabs.close(target), "last work tab did not close")
	drain()
	assert(not vim.api.nvim_tabpage_is_valid(target), "closed work tab is still valid")
	assert(vim.api.nvim_buf_is_valid(user_buf), "modified user buffer was deleted")
	assert(vim.bo[user_buf].modified, "modified state was discarded")
	local remaining = vim.api.nvim_list_tabpages()
	equal(1, #remaining, "last work close did not leave exactly one tab")
	assert(tabs.is_home(remaining[1]), "remaining tab is not a pristine marked home")
	equal(1, menu_dismisses, "current tab menu was not dismissed before close")
	equal(1, menu_opens, "main menu did not open exactly once")
end)

test("closing a tab with multiple splits never deletes its user buffers", function()
	reset_editor()
	local first = named_buffer("first-split")
	vim.cmd("vnew")
	local second = named_buffer("second-split")
	local target = vim.api.nvim_get_current_tabpage()

	assert(tabs.close(target), "multi-split work tab did not close")
	drain()
	assert(vim.api.nvim_buf_is_valid(first), "first split buffer was deleted")
	assert(vim.api.nvim_buf_is_valid(second), "second split buffer was deleted")
	assert(tabs.is_home(vim.api.nvim_get_current_tabpage()), "multi-split close did not land at home")
end)

test("nohidden close failure rolls back only the owned landing tab", function()
	reset_editor()
	local target = vim.api.nvim_get_current_tabpage()
	local user_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "must survive" })
	vim.bo[user_buf].modified = true
	vim.o.hidden = false

	assert(not tabs.close(target), "nohidden modified tab unexpectedly closed")
	drain()
	equal({ target }, vim.api.nvim_list_tabpages(), "failed close leaked its landing tab")
	equal(target, vim.api.nvim_get_current_tabpage(), "failed close did not restore the target")
	assert(vim.api.nvim_buf_is_valid(user_buf) and vim.bo[user_buf].modified, "failed close damaged user buffer")
	assert(not tabs.is_home(target), "failed target was marked home")
	assert(
		#notifications > 0 and notifications[#notifications].level == vim.log.levels.ERROR,
		"failure was not notified"
	)
	vim.o.hidden = true
end)

test("closing a non-current penultimate work tab focuses the existing home", function()
	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_home(home), "could not mark fixture home")
	vim.cmd("tabnew")
	local target = vim.api.nvim_get_current_tabpage()
	named_buffer("non-current-target")
	vim.api.nvim_set_current_tabpage(home)

	assert(tabs.close(target), "non-current target did not close")
	drain()
	equal({ home }, vim.api.nvim_list_tabpages(), "penultimate close left extra tabs")
	equal(home, vim.api.nvim_get_current_tabpage(), "home was not focused")
	equal(0, menu_dismisses, "closing a non-current tab dismissed the current tab menu")
	equal(1, menu_opens, "home menu did not open")
end)

test("queued close coalesces double clicks and retains a stable non-current handle", function()
	reset_editor()
	local first = vim.api.nvim_get_current_tabpage()
	named_buffer("first")
	vim.cmd("tabnew")
	local hole = vim.api.nvim_get_current_tabpage()
	named_buffer("hole")
	vim.cmd("tabnew")
	local target = vim.api.nvim_get_current_tabpage()
	named_buffer("target")
	vim.cmd("tabnew")
	local neighbour = vim.api.nvim_get_current_tabpage()
	named_buffer("neighbour")

	assert(tabs.close(hole), "could not create a hole in tab handles")
	assert(not vim.api.nvim_tabpage_is_valid(hole), "fixture hole is still valid")
	assert(tabs.request_close(target), "first mouse close was not queued")
	assert(not tabs.request_close(target), "double click was queued twice")
	drain()
	assert(not vim.api.nvim_tabpage_is_valid(target), "stable target was not closed")
	assert(vim.api.nvim_tabpage_is_valid(first), "first tab was closed")
	assert(vim.api.nvim_tabpage_is_valid(neighbour), "double click closed the following tab")
	assert(not tabs.request_close(target), "stale handle was accepted")
end)

test("editor reuses only a valid marked home tab", function()
	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_home(home), "could not mark editor fixture home")
	local path = vim.fn.tempname() .. " file.lua"
	owned_paths[#owned_paths + 1] = path
	assert(vim.fn.writefile({ "first", "second" }, path) == 0, "could not write editor fixture")

	require("config.editor").open_file_in_tab(path, { lnum = 2, col = 2 })
	equal(1, #vim.api.nvim_list_tabpages(), "valid home was not reused")
	equal(home, vim.api.nvim_get_current_tabpage(), "navigation replaced the home handle")
	assert(not tabs.is_home(home), "file tab retained its home marker")
	equal({ 2, 1 }, vim.api.nvim_win_get_cursor(0), "home reuse lost cursor position")

	reset_editor()
	local invalid_home = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_home(invalid_home), "could not mark invalid-home fixture")
	vim.cmd("vsplit")
	require("config.editor").open_file_in_tab(path)
	equal(2, #vim.api.nvim_list_tabpages(), "invalid multi-split home was reused")
end)

test("bufferline exposes one global close area, stable middle click, and dynamic selected highlights", function()
	reset_editor()
	local captured
	local original_bufferline = package.loaded.bufferline
	package.loaded.bufferline = {
		setup = function(config)
			captured = config
		end,
	}
	package.loaded["plugins.bufferline"] = nil
	local spec = require("plugins.bufferline")
	assert(spec.cond(), "bufferline is disabled in the full editor")
	spec.config()
	package.loaded.bufferline = original_bufferline

	assert(captured, "bufferline setup was not called")
	equal("tabs", captured.options.mode, "bufferline mode")
	equal(false, captured.options.show_buffer_close_icons, "per-tab close icons remain enabled")
	equal(false, captured.options.show_close_icon, "legacy global close icon remains enabled")
	local area = captured.options.custom_areas.right()
	equal(1, #area, "close area contains more than one control")
	assert(area[1].text:find("%@v:lua.NvimConfigCloseTab@", 1, true), "public click callback is missing")
	assert(area[1].text:find("%X", 1, true), "click region is not terminated")

	local requested
	local original_request = tabs.request_close
	tabs.request_close = function(tabpage)
		requested = tabpage
	end
	captured.options.middle_mouse_command(987654)
	tabs.request_close = original_request
	equal(987654, requested, "middle click did not forward the stable tab handle")

	vim.api.nvim_set_hl(0, "Visual", { bg = 0x112233 })
	vim.api.nvim_set_hl(0, "PmenuSel", { bg = 0x445566 })
	local defaults = {
		highlights = {
			tab_selected = {},
			buffer_selected = {},
			separator_selected = {},
			indicator_selected = {},
			background = {},
		},
	}
	local first = captured.highlights(defaults)
	for _, name in ipairs({ "tab_selected", "buffer_selected", "separator_selected", "indicator_selected" }) do
		equal(0x112233, first[name].bg, name .. " did not use Visual background")
	end
	equal(true, first.tab_selected.bold, "active label is not bold")
	equal(false, first.tab_selected.italic, "active label is italic")
	equal({ highlight = "DiagnosticInfo", attribute = "fg" }, first.indicator_selected.fg, "indicator source")

	vim.api.nvim_set_hl(0, "Visual", {})
	local fallback = captured.highlights(defaults)
	equal(0x445566, fallback.tab_selected.bg, "PmenuSel fallback was not recomputed after colors changed")

	local original_vscode = vim.g.vscode
	vim.g.vscode = true
	assert(not spec.cond(), "bufferline leaked into VS Code")
	vim.g.vscode = false
	package.loaded["config.pager"] = { active = true }
	assert(not spec.cond(), "bufferline leaked into nvimpager")
	package.loaded["config.pager"] = { active = false }
	vim.g.vscode = original_vscode
end)

test("setup owns CloseTab only in the full terminal editor", function()
	reset_editor()
	tabs.setup()
	equal(2, vim.fn.exists(":CloseTab"), "CloseTab command is missing")
	local mapping = vim.fn.maparg("<leader>q", "n", false, true)
	equal("<cmd>CloseTab<cr>", mapping.rhs, "editor close mapping bypasses CloseTab")
	assert(type(_G.NvimConfigCloseTab) == "function", "global tabline callback is missing")

	local requested = 0
	local original_request = tabs.request_close
	tabs.request_close = function()
		requested = requested + 1
	end
	_G.NvimConfigCloseTab(0, 1, "r", "")
	_G.NvimConfigCloseTab(0, 2, "l", "")
	equal(0, requested, "right click or the second double-click event closed a tab")
	_G.NvimConfigCloseTab(0, 1, "l", "")
	equal(1, requested, "single left click did not close the current tab")
	tabs.request_close = original_request
end)

vim.notify = original_notify
vim.o.hidden = true
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
	if vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modified = false
	end
end
for _, path in ipairs(owned_paths) do
	local buf = vim.fn.bufnr(path)
	if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
	vim.fn.delete(path)
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tabs_spec: %d tests passed", count))
vim.cmd("quitall!")
