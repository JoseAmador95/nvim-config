vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/tab-first.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")
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

local dashboard_opens = 0
local menu_dismisses = 0
local menu_context_options = {}
package.loaded["config.pager"] = { active = false }
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "tab_first")
		return vim.deepcopy(defaults)
	end,
}
package.loaded["config.menu"] = {
	dismiss = function()
		menu_dismisses = menu_dismisses + 1
		return true
	end,
	open_context = function(options)
		menu_context_options[#menu_context_options + 1] = options
		return true
	end,
}
package.loaded.snacks = {
	dashboard = {
		open = function(opts)
			dashboard_opens = dashboard_opens + 1
			vim.bo[opts.buf].modifiable = true
			vim.bo[opts.buf].buftype = "nofile"
			vim.bo[opts.buf].filetype = "snacks_dashboard"
			vim.api.nvim_buf_set_lines(opts.buf, 0, -1, false, { "Dashboard" })
			vim.bo[opts.buf].modified = false
			vim.bo[opts.buf].modifiable = false
			vim.api.nvim_exec_autocmds("User", { pattern = "SnacksDashboardOpened" })
		end,
	},
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
	vim.wo.diff = false
	tabs.unmark_home(vim.api.nvim_get_current_tabpage())
	tabs.unmark_transient(vim.api.nvim_get_current_tabpage())
	dashboard_opens = 0
	menu_dismisses = 0
	menu_context_options = {}
	notifications = {}
end

local function stale_dashboard()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "snacks_dashboard"
	vim.bo[buf].modified = false
	tabs.unmark_home(tabpage)
	return tabpage, buf
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

test("home recovery repairs one stale dashboard and coalesces queued requests", function()
	reset_editor()
	local home = stale_dashboard()

	assert(tabs.ensure_home(), "stale dashboard recovery was not queued")
	assert(not tabs.ensure_home(), "duplicate dashboard recovery was queued")
	equal(0, dashboard_opens, "dashboard recovery ran synchronously")
	drain()
	equal(1, dashboard_opens, "stale dashboard was not opened exactly once")
	assert(tabs.is_home(home), "recovered dashboard was not marked home")

	assert(tabs.ensure_home(), "idempotency check was not queued")
	drain()
	equal(1, dashboard_opens, "rendered dashboard was opened again")
end)

test("home recovery adopts a rendered dashboard without reopening it", function()
	reset_editor()
	local home, buf = stale_dashboard()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Rendered dashboard" })
	vim.bo[buf].modified = false

	assert(tabs.ensure_home(), "rendered dashboard adoption was not queued")
	drain()
	equal(0, dashboard_opens, "rendered dashboard was reopened")
	assert(tabs.is_home(home), "rendered dashboard did not regain its home marker")
end)

test("home recovery remains retryable after Snacks fails", function()
	reset_editor()
	local home = stale_dashboard()
	local original_open = package.loaded.snacks.dashboard.open
	local attempts = 0
	package.loaded.snacks.dashboard.open = function()
		attempts = attempts + 1
		error("fixture dashboard failure")
	end

	local ok, err = xpcall(function()
		assert(tabs.ensure_home(), "failing dashboard recovery was not queued")
		drain()
		equal(1, attempts, "dashboard failure was not attempted exactly once")
		assert(not tabs.is_home(home), "failed dashboard recovery marked the tab home")
		assert(
			#notifications == 1 and notifications[1].message:find("fixture dashboard failure", 1, true),
			"dashboard failure was not notified"
		)

		package.loaded.snacks.dashboard.open = original_open
		assert(tabs.ensure_home(), "dashboard recovery could not be retried")
		drain()
		equal(1, dashboard_opens, "dashboard retry did not open the dashboard")
		assert(tabs.is_home(home), "successful retry did not mark the dashboard home")
	end, debug.traceback)
	package.loaded.snacks.dashboard.open = original_open
	assert(ok, err)
end)

test("home recovery refuses non-dashboard and unsafe editor state", function()
	local function refused(label, prepare)
		reset_editor()
		prepare()
		assert(tabs.ensure_home(), label .. " check was not queued")
		drain()
		equal(0, dashboard_opens, label .. " was replaced with the dashboard")
	end

	refused("normal blank new file", function() end)
	refused("named dashboard", function()
		local _, buf = stale_dashboard()
		local path = vim.fn.tempname() .. "-named-dashboard"
		owned_paths[#owned_paths + 1] = path
		vim.api.nvim_buf_set_name(buf, path)
	end)
	refused("modified buffer", function()
		local tabpage = vim.api.nvim_get_current_tabpage()
		local buf = vim.api.nvim_get_current_buf()
		assert(tabs.mark_home(tabpage))
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
		assert(vim.bo[buf].modified)
	end)
	refused("help buffer", function()
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].buftype = "help"
		vim.bo[buf].filetype = "help"
	end)
	refused("terminal buffer", function()
		vim.api.nvim_open_term(vim.api.nvim_get_current_buf(), {})
	end)
	refused("diff window", function()
		stale_dashboard()
		vim.wo.diff = true
	end)
	refused("transient tab", function()
		local tabpage = stale_dashboard()
		assert(tabs.mark_transient(tabpage, "Review"))
	end)
	refused("multi-split tab", function()
		stale_dashboard()
		vim.cmd("vsplit")
	end)
	refused("multi-tab editor", function()
		stale_dashboard()
		vim.cmd("tabnew")
	end)

	reset_editor()
	stale_dashboard()
	local original_vscode = vim.g.vscode
	vim.g.vscode = true
	local vscode_queued = tabs.ensure_home()
	drain()
	vim.g.vscode = original_vscode
	assert(not vscode_queued, "VS Code queued dashboard recovery")
	equal(0, dashboard_opens, "VS Code state was replaced with the dashboard")

	reset_editor()
	stale_dashboard()
	package.loaded["config.pager"] = { active = true }
	local pager_queued = tabs.ensure_home()
	drain()
	package.loaded["config.pager"] = { active = false }
	assert(not pager_queued, "pager queued dashboard recovery")
	equal(0, dashboard_opens, "pager state was replaced with the dashboard")
end)

test("transient tabs expose a stable title without becoming reusable home tabs", function()
	reset_editor()
	local tabpage = vim.api.nvim_get_current_tabpage()
	assert(tabs.mark_home(tabpage), "could not mark transient fixture home")
	assert(not tabs.mark_transient(tabpage, ""), "empty transient title was accepted")
	assert(tabs.mark_transient(tabpage, "Review: feature branch"), "could not mark transient tab")
	equal(true, tabs.is_transient(tabpage), "transient marker is missing")
	equal("Review: feature branch", tabs.transient_title(tabpage), "transient title changed")
	assert(not tabs.is_home(tabpage), "transient tab remained reusable as home")
	equal(nil, tabs.find_home(), "transient tab was discovered as home")

	named_buffer("diffview-local.lua")
	equal(
		"Review: feature branch",
		tabs.name_formatter({ name = "diffview-local.lua", tabnr = tabpage }),
		"focused source buffer replaced the transient title"
	)
	vim.cmd("vnew")
	named_buffer("diffview-old.lua")
	equal(
		"Review: feature branch",
		tabs.name_formatter({ name = "diffview-old.lua", tabnr = tabpage }),
		"changing the focused split replaced the transient title"
	)

	tabs.unmark_transient(tabpage)
	equal(false, tabs.is_transient(tabpage), "transient marker survived unmark")
	equal(nil, tabs.transient_title(tabpage), "transient title survived unmark")
end)

test("dashboard new file reuses the home tab as an unnamed normal buffer", function()
	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	local dashboard_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(dashboard_buf, 0, -1, false, { "Dashboard" })
	vim.bo[dashboard_buf].bufhidden = "wipe"
	vim.bo[dashboard_buf].buftype = "nofile"
	vim.bo[dashboard_buf].filetype = "snacks_dashboard"
	vim.bo[dashboard_buf].modified = false
	vim.bo[dashboard_buf].modifiable = false
	assert(tabs.mark_home(home), "could not mark dashboard fixture home")

	local new_file
	for _, item in ipairs(require("plugins.snacks").opts.dashboard.preset.keys) do
		if item.key == "n" then
			new_file = item
			break
		end
	end
	assert(new_file and type(new_file.action) == "function", "dashboard new-file action is missing")

	new_file.action()

	equal({ home }, vim.api.nvim_list_tabpages(), "new file did not reuse the home tab")
	equal(home, vim.api.nvim_get_current_tabpage(), "new file changed the current tab handle")
	local buf = vim.api.nvim_get_current_buf()
	assert(buf ~= dashboard_buf, "new file retained the dashboard buffer")
	equal("", vim.api.nvim_buf_get_name(buf), "new buffer has a filename")
	equal("", vim.bo[buf].buftype, "new buffer is not normal")
	equal(false, vim.bo[buf].modified, "new buffer is modified")
	equal({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "new buffer is not empty")
	equal("n", vim.api.nvim_get_mode().mode, "new file did not remain in Normal mode")
	assert(not tabs.is_home(home), "new-file work tab retained its home marker")
	equal(nil, tabs.find_home(), "new-file work tab is still discoverable as home")
end)

test("closing the last work tab preserves its modified buffer and opens dashboard home", function()
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
	equal(1, dashboard_opens, "dashboard did not open exactly once")
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
	equal(1, dashboard_opens, "home dashboard did not open")
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

test("tab labels retain the last focused normal window while a float is active", function()
	reset_editor()
	tabs.setup()
	local tabpage = vim.api.nvim_get_current_tabpage()
	local first_buf = named_buffer("first-label.py")
	local first_win = vim.api.nvim_get_current_win()
	local first_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(first_buf), ":t")

	vim.cmd("vnew")
	local second_buf = named_buffer("second-label.py")
	local second_win = vim.api.nvim_get_current_win()
	local second_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(second_buf), ":t")

	local float_buf = vim.api.nvim_create_buf(false, true)
	local float_win = vim.api.nvim_open_win(float_buf, true, {
		relative = "editor",
		width = 20,
		height = 1,
		row = 1,
		col = 1,
		style = "minimal",
	})
	local item = { name = "[No Name]", path = "", bufnr = float_buf, tabnr = tabpage }
	equal(second_name, tabs.name_formatter(item), "unnamed float replaced the last focused split label")

	local replacement = vim.api.nvim_create_buf(true, false)
	local replacement_path = vim.fn.tempname() .. "-replacement-label.py"
	owned_paths[#owned_paths + 1] = replacement_path
	vim.api.nvim_buf_set_name(replacement, replacement_path)
	vim.api.nvim_win_set_buf(second_win, replacement)
	equal(
		vim.fn.fnamemodify(replacement_path, ":t"),
		tabs.name_formatter(item),
		"tab label cached a filename instead of following the saved window"
	)

	vim.api.nvim_win_close(second_win, true)
	equal(first_name, tabs.name_formatter(item), "stale focused split did not recover to a live normal window")
	assert(vim.api.nvim_win_is_valid(first_win), "fallback normal window was closed")

	vim.api.nvim_win_close(float_win, true)
	vim.api.nvim_buf_delete(float_buf, { force = true })
	reset_editor()
	tabs.setup()
	tabpage = vim.api.nvim_get_current_tabpage()
	float_buf = vim.api.nvim_create_buf(false, true)
	float_win = vim.api.nvim_open_win(float_buf, true, {
		relative = "editor",
		width = 20,
		height = 1,
		row = 1,
		col = 1,
		style = "minimal",
	})
	equal(
		"[No Name]",
		tabs.name_formatter({ name = "[No Name]", path = "", bufnr = float_buf, tabnr = tabpage }),
		"legitimate unnamed normal buffer received a synthetic label"
	)
	vim.api.nvim_win_close(float_win, true)
	vim.api.nvim_buf_delete(float_buf, { force = true })
end)

test("bufferline exposes native safe close callbacks and dynamic selected highlights", function()
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
	equal(true, captured.options.show_buffer_close_icons, "native per-tab close icons are disabled")
	equal(false, captured.options.show_close_icon, "global bufferline close icon remains enabled")
	equal(nil, captured.options.custom_areas, "custom global close area remains configured")
	equal(nil, tabs.close_area, "obsolete tabs.close_area API remains exported")
	equal(tabs.name_formatter, captured.options.name_formatter, "bufferline does not use the public tab name formatter")

	local requested = {}
	local original_request = tabs.request_close
	tabs.request_close = function(tabpage)
		requested[#requested + 1] = tabpage
	end
	local callback_ok, callback_error = xpcall(function()
		for index, option in ipairs({ "close_command", "middle_mouse_command" }) do
			assert(type(captured.options[option]) == "function", option .. " is not a public function callback")
			captured.options[option](987650 + index)
		end
		assert(type(captured.options.right_mouse_command) == "function", "right mouse is not a public callback")
		captured.options.right_mouse_command(987653)
	end, debug.traceback)
	tabs.request_close = original_request
	assert(callback_ok, callback_error)
	equal({ 987651, 987652 }, requested, "a close callback changed or dropped its stable tab handle")
	equal(1, #menu_context_options, "right mouse did not open the context menu")
	equal(false, menu_context_options[1].move_cursor, "tabline context menu replayed RightMouse")

	vim.api.nvim_set_hl(0, "Visual", { bg = 0x112233 })
	vim.api.nvim_set_hl(0, "PmenuSel", { bg = 0x445566 })
	vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0xabcdef })
	local defaults = {
		highlights = {
			tab_selected = {},
			buffer_selected = {},
			close_button_selected = {},
			separator_selected = {},
			indicator_selected = {},
			background = {},
		},
	}
	local first = captured.highlights(defaults)
	for _, name in ipairs({
		"tab_selected",
		"buffer_selected",
		"close_button_selected",
		"separator_selected",
		"indicator_selected",
	}) do
		equal(0x112233, first[name].bg, name .. " did not use Visual background")
	end
	equal(true, first.tab_selected.bold, "active label is not bold")
	equal(false, first.tab_selected.italic, "active label is italic")
	equal(0xabcdef, first.indicator_selected.fg, "indicator source")
	equal(0xabcdef, first.separator_selected.fg, "selected separator source")
	equal(0xabcdef, first.close_button_selected.fg, "selected close source")

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

test("UI startup recovers a dashboard restored without its Snacks instance", function()
	reset_editor()
	local home = stale_dashboard()
	tabs.setup()
	vim.api.nvim_exec_autocmds("UIEnter", {})
	drain()
	equal(1, dashboard_opens, "startup did not recover the stale dashboard")
	assert(tabs.is_home(home), "startup recovery did not restore the home marker")
end)

test("setup owns CloseTab only in the full terminal editor", function()
	reset_editor()
	assert(_G.NvimConfigCloseTab == nil, "obsolete global tabline callback exists before setup")
	tabs.setup()
	equal(2, vim.fn.exists(":CloseTab"), "CloseTab command is missing")
	local mapping = vim.fn.maparg("<leader>q", "n", false, true)
	equal("<cmd>CloseTab<cr>", mapping.rhs, "editor close mapping bypasses CloseTab")
	assert(_G.NvimConfigCloseTab == nil, "setup recreated the obsolete global tabline callback")

	local requested
	local original_request = tabs.request_close
	tabs.request_close = function(tabpage)
		requested = tabpage
	end
	local current = vim.api.nvim_get_current_tabpage()
	local command_ok, command_error = pcall(vim.cmd, "CloseTab")
	tabs.request_close = original_request
	assert(command_ok, command_error)
	equal(current, requested, "CloseTab did not forward the current stable tab handle")

	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	package.loaded.snacks.dashboard.open({ buf = 0, win = 0 })
	assert(tabs.is_home(home), "startup dashboard event did not mark the reusable home tab")
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
