vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "could not resolve plugin spec")
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ":p")))
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

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

local tab_first = require("tab_first")
local paths = {}

test("workspace history defaults are copied and rejected setup is non-mutating", function()
	equal({ history = { enabled = true, max_entries = 200, scope = "workspace" } }, tab_first.effective_config())
	assert(tab_first.status().configured == false)
	local config = tab_first.effective_config()
	config.history.max_entries = 1
	equal(200, tab_first.effective_config().history.max_entries, "effective config leaked mutable state")
	local before = tab_first.status()
	local ok, err = pcall(tab_first.setup, { history = { unknown = true } })
	assert(not ok and tostring(err):find("unknown option", 1, true), tostring(err))
	equal(before, tab_first.status(), "rejected setup mutated state")
end)

local function make_file(label)
	local path = vim.fn.tempname() .. "-" .. label
	assert(vim.fn.writefile({ label .. " one", label .. " two", label .. " three" }, path) == 0)
	paths[#paths + 1] = path
	return path
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
	tab_first.unmark_home(vim.api.nvim_get_current_tabpage())
	tab_first.unmark_transient(vim.api.nvim_get_current_tabpage())
	tab_first.history_reset()
	tab_first.setup({
		enabled = function()
			return true
		end,
		schedule = vim.schedule,
		notify = function() end,
		dismiss_ui = nil,
		present_home = nil,
		is_special_buffer = function(buf)
			return vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == ""
		end,
		history = {
			enabled = true,
			max_entries = 200,
			native_fallback = nil,
		},
	})
end

test("setup creates no host command or global mapping and imports no config module", function()
	reset_editor()
	tab_first.setup({})
	for _, command in ipairs({ "CloseTab", "NavigationBack", "NavigationForward", "NavigationHistory" }) do
		equal(0, vim.fn.exists(":" .. command), command .. " was registered by the plugin")
	end
	equal({}, vim.fn.maparg("<leader>q", "n", false, true), "plugin registered the host close mapping")
	equal({}, vim.fn.maparg("<leader>nh", "n", false, true), "plugin registered the host history mapping")
	for name in pairs(package.loaded) do
		assert(not name:match("^config%."), "plugin imported host module " .. name)
	end
end)

test("canonical opening reuses the exact visible split", function()
	reset_editor()
	local first = make_file("visible-first")
	local second = make_file("visible-second")
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local expected_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit " .. vim.fn.fnameescape(second))
	local other_win = vim.api.nvim_get_current_win()

	local opened = tab_first.open(first, { lnum = 3, col = 2 })
	equal(expected_win, opened.winid, "opening did not reuse the split showing the canonical path")
	equal(expected_win, vim.api.nvim_get_current_win(), "opening focused a different split")
	equal({ 3, 1 }, vim.api.nvim_win_get_cursor(expected_win), "visible split reuse lost the cursor")
	assert(vim.api.nvim_win_is_valid(other_win), "opening replaced the neighboring split")
end)

test("opening reuses only a pristine marked home tab", function()
	reset_editor()
	local home = vim.api.nvim_get_current_tabpage()
	local path = make_file("home-target")
	assert(tab_first.mark_home(home), "could not mark the pristine home")

	local opened = tab_first.open(path)
	equal("home", opened.reused, "opening did not report home reuse")
	equal(home, opened.tabpage, "opening replaced the stable home handle")
	equal(1, #vim.api.nvim_list_tabpages(), "home reuse created an extra tab")
	assert(not tab_first.is_home(home), "opened file retained the home marker")

	reset_editor()
	local invalid = vim.api.nvim_get_current_tabpage()
	assert(tab_first.mark_home(invalid), "could not mark the invalid-home fixture")
	vim.cmd("vsplit")
	tab_first.open(path)
	equal(2, #vim.api.nvim_list_tabpages(), "multi-split home was reused")
end)

test("home presenter is injected and recovery requests coalesce", function()
	reset_editor()
	local queue = {}
	local presentations = 0
	local home = vim.api.nvim_get_current_tabpage()
	assert(tab_first.mark_home(home), "could not mark landing home")
	tab_first.setup({
		schedule = function(callback)
			queue[#queue + 1] = callback
		end,
		present_home = function(context)
			presentations = presentations + 1
			vim.bo[context.buf].buftype = "nofile"
			vim.bo[context.buf].filetype = "snacks_dashboard"
			vim.api.nvim_buf_set_lines(context.buf, 0, -1, false, { "Dashboard" })
			vim.bo[context.buf].modified = false
		end,
	})

	assert(tab_first.ensure_home(), "first home recovery was not queued")
	assert(not tab_first.ensure_home(), "duplicate home recovery was queued")
	equal(1, #queue, "home recovery did not coalesce")
	queue[1]()
	equal(1, presentations, "injected presenter did not run exactly once")
	assert(tab_first.is_home(home), "presented dashboard is not a valid home")
end)

test("home classification is injected and the plugin has no Snacks filetype literal", function()
	reset_editor()
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "custom_home"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Home" })
	vim.bo[buf].modified = false
	tab_first.setup({
		is_home_buffer = function(candidate)
			return candidate == buf and vim.bo[candidate].filetype == "custom_home"
		end,
	})
	assert(tab_first.mark_home(vim.api.nvim_get_current_tabpage()), "injected classifier was ignored")
	local implementation = table.concat(vim.fn.readfile(plugin .. "/lua/tab_first/init.lua"), "\n")
	assert(not implementation:find("snacks_dashboard", 1, true), "plugin retained a Snacks-specific classifier")
end)

test("queued closes use stable handles and coalesce duplicate clicks", function()
	reset_editor()
	local queue = {}
	tab_first.setup({
		schedule = function(callback)
			queue[#queue + 1] = callback
		end,
	})
	local first = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local target = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local neighbour = vim.api.nvim_get_current_tabpage()

	assert(tab_first.request_close(target), "stable target close was not queued")
	assert(not tab_first.request_close(target), "duplicate target close was queued")
	equal(1, #queue, "duplicate click produced more than one callback")
	queue[1]()
	assert(not vim.api.nvim_tabpage_is_valid(target), "queued target remains valid")
	assert(vim.api.nvim_tabpage_is_valid(first), "queued close removed the first tab")
	assert(vim.api.nvim_tabpage_is_valid(neighbour), "queued close removed the neighbor")
end)

test("safe final close retains modified output and uses injected host callbacks", function()
	reset_editor()
	local presented = 0
	local dismissed = 0
	tab_first.setup({
		dismiss_ui = function()
			dismissed = dismissed + 1
		end,
		present_home = function(context)
			presented = presented + 1
			vim.bo[context.buf].buftype = "nofile"
			vim.bo[context.buf].filetype = "snacks_dashboard"
			vim.api.nvim_buf_set_lines(context.buf, 0, -1, false, { "Dashboard" })
			vim.bo[context.buf].modified = false
		end,
	})
	local target = vim.api.nvim_get_current_tabpage()
	local user_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "unsaved" })
	vim.bo[user_buf].modified = true

	assert(tab_first.close(target), "final work tab did not close")
	assert(
		vim.wait(500, function()
			return presented == 1
		end, 5),
		"home presenter was not scheduled"
	)
	assert(vim.api.nvim_buf_is_valid(user_buf) and vim.bo[user_buf].modified, "close discarded the user buffer")
	equal(1, dismissed, "current-tab close did not dismiss host UI")
	assert(tab_first.is_home(vim.api.nvim_get_current_tabpage()), "final close did not leave a home tab")
end)

test("semantic history traverses exact locations then falls back when exhausted", function()
	reset_editor()
	local first = make_file("history-first")
	local second = make_file("history-second")
	local fallbacks = {}
	tab_first.setup({
		history = {
			native_fallback = function(direction)
				fallbacks[#fallbacks + 1] = direction
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	vim.api.nvim_win_set_cursor(0, { 2, 1 })
	tab_first.open(second, { lnum = 3, col = 2 })

	assert(tab_first.back(), "semantic back did not restore the origin")
	equal({ 2, 1 }, vim.api.nvim_win_get_cursor(0), "semantic back lost the origin cursor")
	assert(not tab_first.back(), "exhausted back reported a semantic traversal")
	equal({ -1 }, fallbacks, "exhausted back did not call native fallback")
	assert(tab_first.forward(), "semantic forward did not restore the destination")
	assert(not tab_first.forward(), "exhausted forward reported a semantic traversal")
	equal({ -1, 1 }, fallbacks, "exhausted forward did not call native fallback")
end)

test("closed history locations reopen through the injected host adapter", function()
	reset_editor()
	local first = make_file("history-adapter-first")
	local second = make_file("history-adapter-second")
	local reopened = 0
	tab_first.setup({
		history = {
			open_location = function(entry)
				reopened = reopened + 1
				tab_first.open(entry.path, {
					lnum = entry.lnum,
					col = entry.col,
					record_history = false,
				})
				return true
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local first_tab = vim.api.nvim_get_current_tabpage()
	tab_first.open(second)
	vim.api.nvim_set_current_tabpage(first_tab)
	vim.cmd("tabclose")

	assert(tab_first.back({ fallback = false }), "closed history location was not restored")
	equal(1, reopened, "history bypassed or repeated the injected open adapter")
	equal(vim.uv.fs_realpath(first), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), "adapter reopened wrong path")
end)

test("semantic history can be disabled without changing canonical opening", function()
	reset_editor()
	local first = make_file("disabled-first")
	local second = make_file("disabled-second")
	local fallback
	tab_first.setup({
		history = {
			enabled = false,
			native_fallback = function(direction)
				fallback = direction
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local opened = tab_first.open(second)
	assert(opened and opened.path, "canonical opening stopped when history was disabled")
	equal(0, #tab_first.history_snapshot().entries, "disabled history recorded a transition")
	assert(not tab_first.back(), "disabled history reported a semantic traversal")
	equal(-1, fallback, "disabled history did not delegate to the native fallback")
end)

test("history events are isolated and repeated teardown/setup resets lifecycle state", function()
	reset_editor()
	local events = {}
	tab_first.setup({
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.entries = 999
		end,
		history = { max_entries = 3 },
	})
	assert(tab_first.record_transition({ path = "/tmp/a", lnum = 1, col = 1 }, { path = "/tmp/b", lnum = 2, col = 1 }))
	equal({ kind = "history", index = 2, entries = 2 }, events[1])
	equal(2, tab_first.status().history.entries, "event callback mutated history state")
	local before = tab_first.status()
	local ok = pcall(tab_first.setup, { unknown = true })
	assert(not ok)
	equal(before, tab_first.status(), "invalid repeated setup changed history")
	assert(tab_first.teardown())
	assert(tab_first.teardown())
	assert(not tab_first.status().configured)
	equal(200, tab_first.effective_config().history.max_entries)
	assert(tab_first.setup())
	assert(tab_first.status().configured)
end)

for _, path in ipairs(paths) do
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == path then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	vim.fn.delete(path)
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tab_first_spec: %d tests passed", count))
vim.cmd("quitall!")
