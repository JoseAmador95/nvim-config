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

test("canonical opening prefers the current duplicate tab", function()
	reset_editor()
	local path = make_file("duplicate-current")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	vim.cmd("tab split")
	local preferred = vim.api.nvim_get_current_tabpage()
	local preferred_win = vim.api.nvim_get_current_win()

	local opened = tab_first.open(path, { lnum = 2, col = 2 })
	equal(preferred, vim.api.nvim_get_current_tabpage(), "opening selected an earlier duplicate tab")
	equal(preferred_win, vim.api.nvim_get_current_win(), "opening selected another duplicate window")
	equal("visible", opened.reused, "current duplicate was not classified as visible reuse")
	equal({ 2, 1 }, vim.api.nvim_win_get_cursor(0), "current duplicate lost the requested cursor")
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

test("transient leases create one dedicated tab per owner key and reuse it exactly", function()
	reset_editor()
	local origin = vim.api.nvim_get_current_tabpage()
	local tabs_before = #vim.api.nvim_list_tabpages()
	local closed = {}
	local first = assert(tab_first.acquire_transient({
		owner = "review",
		key = "workspace",
		title = "Review: first",
		on_closed = function(handle, reason)
			closed[#closed + 1] = { handle = handle, reason = reason }
		end,
	}))
	local owned_buf = vim.api.nvim_get_current_buf()
	assert(first.tabpage ~= origin and vim.api.nvim_get_current_tabpage() == first.tabpage)
	equal(tabs_before + 1, #vim.api.nvim_list_tabpages(), "transient acquisition did not create one dedicated tab")
	assert(tab_first.valid_transient(first), "new transient handle was not valid")
	equal("Review: first", tab_first.transient_title(first.tabpage), "transient title was not installed")

	vim.api.nvim_set_current_tabpage(origin)
	local second = assert(tab_first.acquire_transient({
		owner = "review",
		key = "workspace",
		title = "Review: reused",
		on_closed = function(handle, reason)
			closed[#closed + 1] = { handle = handle, reason = reason }
		end,
	}))
	equal(first, second, "same owner/key did not reuse its opaque handle")
	equal(tabs_before + 1, #vim.api.nvim_list_tabpages(), "same owner/key created a second transient tab")
	assert(vim.api.nvim_get_current_tabpage() == first.tabpage, "reused transient tab was not focused")
	equal("Review: reused", tab_first.transient_title(first.tabpage), "reused transient tab was not renamed")
	assert(tab_first.rename_transient(first, "Review: renamed"), "explicit transient rename failed")
	equal("Review: renamed", tab_first.transient_title(first.tabpage), "explicit transient rename was not visible")

	vim.api.nvim_set_current_tabpage(origin)
	assert(tab_first.focus_transient(first), "explicit transient focus failed")
	assert(vim.api.nvim_get_current_tabpage() == first.tabpage, "explicit transient focus selected the wrong tab")
	assert(tab_first.release_transient(first), "owner release failed")
	assert(not tab_first.valid_transient(first), "released transient handle stayed valid")
	equal(1, #closed, "owner release did not notify closure exactly once")
	equal({ handle = first, reason = "released" }, closed[1], "owner release callback changed")
	assert(not vim.api.nvim_buf_is_valid(owned_buf), "hidden owned blank scratch buffer survived release")
end)

test("supported transient closes honor vetoes and callback errors", function()
	reset_editor()
	local queue = {}
	local preflights = {}
	local closed = {}
	tab_first.setup({
		schedule = function(callback)
			queue[#queue + 1] = callback
		end,
		notify = function() end,
	})
	local handle = assert(tab_first.acquire_transient({
		owner = "review",
		key = "veto",
		title = "Review: veto",
		on_request_close = function(received, reason)
			preflights[#preflights + 1] = { handle = received, reason = reason }
			return false
		end,
		on_closed = function(received, reason)
			closed[#closed + 1] = { handle = received, reason = reason }
		end,
	}))
	assert(not tab_first.request_close(handle.tabpage), "supported close ignored its synchronous veto")
	equal(0, #queue, "vetoed supported close was queued")
	equal({ { handle = handle, reason = "supported" } }, preflights, "close request skipped synchronous preflight")
	assert(tab_first.valid_transient(handle), "preflight veto closed the transient tab")
	equal(0, #closed, "preflight veto emitted a closed callback")

	assert(tab_first.acquire_transient({
		owner = "review",
		key = "veto",
		title = "Review: callback error",
		on_request_close = function()
			error("simulated preflight failure")
		end,
		on_closed = function(received, reason)
			closed[#closed + 1] = { handle = received, reason = reason }
		end,
	}))
	assert(not tab_first.close(handle.tabpage), "preflight callback error closed the transient tab")
	assert(tab_first.valid_transient(handle), "callback error invalidated the transient lease")

	assert(tab_first.acquire_transient({
		owner = "review",
		key = "veto",
		title = "Review: approved",
		on_request_close = function(received, reason)
			preflights[#preflights + 1] = { handle = received, reason = reason }
			return true
		end,
		on_closed = function(received, reason)
			closed[#closed + 1] = { handle = received, reason = reason }
		end,
	}))
	assert(tab_first.request_close(handle.tabpage), "approved supported close was not queued")
	assert(not tab_first.request_close(handle.tabpage), "duplicate supported close was queued")
	equal(1, #queue, "approved supported close did not retain click coalescing")
	equal(2, #preflights, "duplicate supported close reran preflight")
	queue[1]()
	assert(not tab_first.valid_transient(handle), "approved supported close retained the lease")
	equal({ handle = handle, reason = "supported" }, closed[1], "supported close callback changed")
end)

test("owner release bypasses close preflight", function()
	reset_editor()
	local preflights = 0
	local closed
	local handle = assert(tab_first.acquire_transient({
		owner = "review",
		key = "release",
		title = "Review: release",
		on_request_close = function()
			preflights = preflights + 1
			return false
		end,
		on_closed = function(received, reason)
			closed = { handle = received, reason = reason }
		end,
	}))
	local retained_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(retained_buf, 0, -1, false, { "owner content" })
	vim.bo[retained_buf].modified = false
	assert(tab_first.release_transient(handle), "owner release was vetoed by its own preflight")
	equal(0, preflights, "owner release invoked supported-close preflight")
	equal({ handle = handle, reason = "released" }, closed, "owner release notification changed")
	assert(vim.api.nvim_buf_is_valid(retained_buf), "release deleted a nonblank owner buffer")
	equal({ "owner content" }, vim.api.nvim_buf_get_lines(retained_buf, 0, -1, false), "release changed owner content")
	vim.api.nvim_buf_delete(retained_buf, { force = true })
end)

test("releasing the final transient tab preserves user buffers and creates a safe home", function()
	reset_editor()
	local origin = vim.api.nvim_get_current_tabpage()
	local user_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "unsaved user content" })
	vim.bo[user_buf].modified = true
	local handle = assert(tab_first.acquire_transient({
		owner = "review",
		key = "last-tab",
		title = "Review: last tab",
	}))
	local origin_number = assert(vim.api.nvim_tabpage_get_number(origin))
	vim.api.nvim_cmd({ cmd = "tabclose", args = { tostring(origin_number) } }, {})
	assert(#vim.api.nvim_list_tabpages() == 1 and tab_first.valid_transient(handle), "fixture did not leave one lease")
	assert(tab_first.release_transient(handle), "final transient release failed")
	assert(tab_first.is_home(vim.api.nvim_get_current_tabpage()), "final transient release did not create a safe home")
	assert(vim.api.nvim_buf_is_valid(user_buf) and vim.bo[user_buf].modified, "final release deleted user changes")
end)

test("raw tab close reconciles once and stale generations cannot affect reacquisition", function()
	reset_editor()
	local preflights = {}
	local closed = {}
	local first = assert(tab_first.acquire_transient({
		owner = "review",
		key = "raw",
		title = "Review: raw",
		on_request_close = function(received, reason)
			preflights[#preflights + 1] = { handle = received, reason = reason }
			return false
		end,
		on_closed = function(received, reason)
			closed[#closed + 1] = { handle = received, reason = reason }
		end,
	}))
	vim.cmd("tabclose")
	equal({ { handle = first, reason = "external" } }, preflights, "raw close did not run best-effort preflight")
	equal({ { handle = first, reason = "external" } }, closed, "raw close did not reconcile exactly once")
	assert(not tab_first.valid_transient(first), "raw close retained a valid lease")

	local second = assert(tab_first.acquire_transient({
		owner = "review",
		key = "raw",
		title = "Review: replacement",
	}))
	assert(second.token > first.token, "reacquisition reused an opaque generation")
	assert(not tab_first.focus_transient(first), "stale handle focused the replacement lease")
	assert(not tab_first.rename_transient(first, "Review: stale"), "stale handle renamed the replacement lease")
	assert(not tab_first.release_transient(first), "stale handle released the replacement lease")
	assert(tab_first.valid_transient(second), "stale handle operation invalidated the replacement lease")
	equal("Review: replacement", tab_first.transient_title(second.tabpage), "stale handle changed replacement title")
	assert(tab_first.release_transient(second), "replacement lease cleanup failed")
end)

test("teardown clears lease callbacks without closing the visible tab", function()
	reset_editor()
	local closed = {}
	local handle = assert(tab_first.acquire_transient({
		owner = "review",
		key = "teardown",
		title = "Review: teardown",
		on_request_close = function()
			error("preflight survived teardown")
		end,
		on_closed = function(received, reason)
			closed[#closed + 1] = { handle = received, reason = reason }
		end,
	}))
	local leased_tab = handle.tabpage
	assert(tab_first.teardown(), "tab-first teardown failed")
	assert(vim.api.nvim_tabpage_is_valid(leased_tab), "teardown destructively closed the visible leased tab")
	assert(not tab_first.valid_transient(handle), "teardown retained an active lease")
	equal(nil, tab_first.transient_title(leased_tab), "teardown retained the transient title")
	equal({ { handle = handle, reason = "teardown" } }, closed, "teardown callback changed")
	vim.cmd("tabclose")
	equal(1, #closed, "closed callback survived lifecycle teardown")
	assert(tab_first.setup({}), "tab-first setup after teardown failed")
end)

test("semantic history never falls through after entries exist", function()
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
	equal({}, fallbacks, "exhausted back escaped into native history")
	assert(tab_first.forward(), "semantic forward did not restore the destination")
	assert(not tab_first.forward(), "exhausted forward reported a semantic traversal")
	equal({}, fallbacks, "exhausted forward escaped into native history")
end)

test("semantic history honors counts without forwarding residual steps", function()
	reset_editor()
	local first = make_file("history-count-first")
	local second = make_file("history-count-second")
	local third = make_file("history-count-third")
	local fallbacks = {}
	tab_first.setup({
		history = {
			native_fallback = function(direction, count)
				fallbacks[#fallbacks + 1] = { direction, count }
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	tab_first.open(second)
	tab_first.open(third)

	assert(tab_first.back({ count = 2 }), "counted semantic back did not move")
	equal(
		vim.uv.fs_realpath(first),
		vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)),
		"counted back landed incorrectly"
	)
	equal({}, fallbacks, "counted back fell through before history was exhausted")
	assert(tab_first.forward({ count = 5 }), "partial counted forward did not report semantic movement")
	equal(
		vim.uv.fs_realpath(third),
		vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)),
		"counted forward landed incorrectly"
	)
	equal({}, fallbacks, "residual forward count escaped into native history")
	assert(not tab_first.forward({ count = 4, fallback = false }), "disabled fallback reported movement")
	equal(0, #fallbacks, "fallback=false still invoked native history")
end)

test("empty history delegates one counted request and propagates fallback errors", function()
	reset_editor()
	local calls = {}
	tab_first.setup({
		history = {
			native_fallback = function(direction, count)
				calls[#calls + 1] = { direction, count }
			end,
		},
	})
	assert(not tab_first.forward({ count = 4 }), "native fallback reported semantic movement")
	equal({ { 1, 4 } }, calls, "empty history did not forward the exact count once")

	tab_first.setup({
		history = {
			native_fallback = function()
				error("native fallback failed")
			end,
		},
	})
	local ok, err = pcall(tab_first.back)
	assert(not ok and tostring(err):find("native fallback failed", 1, true), "fallback error was silently swallowed")
end)

test("unrecorded same-file movement is appended before traversal", function()
	reset_editor()
	local path = make_file("history-native-same-file")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	tab_first.open(path, { lnum = 2, col = 1 })
	vim.api.nvim_win_set_cursor(0, { 3, 0 })

	assert(tab_first.back({ fallback = false }), "back did not return to the semantic endpoint")
	equal({ 2, 0 }, vim.api.nvim_win_get_cursor(0), "first back skipped the semantic endpoint")
	assert(tab_first.back({ fallback = false }), "second back did not return to the semantic origin")
	equal({ 1, 0 }, vim.api.nvim_win_get_cursor(0), "second back lost the semantic origin")
end)

test("explicit open origins remain immutable across delayed navigation", function()
	reset_editor()
	local first = make_file("history-explicit-first")
	local intermediate = make_file("history-explicit-intermediate")
	local destination = make_file("history-explicit-destination")
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local origin = assert(tab_first.capture())
	vim.cmd("edit! " .. vim.fn.fnameescape(intermediate))
	tab_first.open(destination, { history_origin = origin })

	local snapshot = tab_first.history_snapshot()
	equal(2, #snapshot.entries, "delayed open recorded an extra location")
	equal(vim.uv.fs_realpath(first), snapshot.entries[1].path, "delayed open recaptured its late origin")
	equal(vim.uv.fs_realpath(destination), snapshot.entries[2].path, "delayed open lost its destination")
end)

test("provider history captures, restores, and skips stale entries", function()
	reset_editor()
	local current
	local restores = {}
	local function entry(location, stale)
		return {
			kind = "provider",
			provider = "review",
			document_key = "session:file.lua",
			location_key = location,
			label = "Review file.lua:" .. location,
			payload = { location = location, stale = stale == true },
		}
	end
	tab_first.setup({
		history = {
			capture_location = function()
				return current
			end,
			restore_location = function(value)
				restores[#restores + 1] = value.location_key
				if value.payload.stale then
					return false
				end
				current = value
				return true
			end,
		},
	})
	local first = entry("1:1")
	local stale = entry("2:1", true)
	local third = entry("3:1")
	current = first
	equal(first, tab_first.capture(), "provider capture changed the opaque entry")
	assert(tab_first.same_location(first, vim.deepcopy(first)), "provider identity was not recognized")
	assert(not tab_first.same_location(first, stale), "different provider locations compared equal")
	assert(tab_first.record_transition(first, stale), "provider transition was rejected")
	assert(tab_first.record_transition(stale, third), "provider destination was rejected")
	current = third
	assert(tab_first.back({ fallback = false }), "stale provider entry consumed the traversal")
	equal({ "2:1", "1:1" }, restores, "provider restoration order changed")
	equal("1:1", current.location_key, "provider traversal landed at the wrong location")
end)

test("recorded history owns immutable copies of provider entries", function()
	reset_editor()
	local origin = {
		kind = "provider",
		provider = "review",
		document_key = "session:first.lua",
		location_key = "1:1",
		label = "Review first.lua:1:1",
		payload = { location = { line = 1, col = 1 } },
	}
	local destination = {
		kind = "provider",
		provider = "review",
		document_key = "session:second.lua",
		location_key = "2:3",
		label = "Review second.lua:2:3",
		payload = { location = { line = 2, col = 3 } },
	}
	assert(tab_first.record_transition(origin, destination), "provider transition was rejected")
	origin.location_key = "mutated"
	origin.payload.location.line = 99
	destination.document_key = "mutated"
	destination.payload.location.col = 99

	local snapshot = tab_first.history_snapshot()
	equal("1:1", snapshot.entries[1].location_key, "origin key remained caller-owned")
	equal(1, snapshot.entries[1].payload.location.line, "origin payload remained caller-owned")
	equal("session:second.lua", snapshot.entries[2].document_key, "destination key remained caller-owned")
	equal(3, snapshot.entries[2].payload.location.col, "destination payload remained caller-owned")
end)

test("provider callback failures are notified without crashing capture or traversal", function()
	reset_editor()
	local notifications = {}
	local named_path = make_file("history-provider-capture-error")
	vim.cmd("edit! " .. vim.fn.fnameescape(named_path))
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			capture_location = function()
				error("capture exploded")
			end,
		},
	})
	equal(nil, tab_first.capture(), "failed provider capture fabricated a location")
	assert(notifications[1]:find("capture exploded", 1, true), "provider capture failure was not notified")
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			capture_location = function()
				return nil, "capture returned an error"
			end,
		},
	})
	equal(nil, tab_first.capture(), "provider capture error fabricated a location")
	assert(
		notifications[#notifications]:find("capture returned an error", 1, true),
		"returned provider capture failure was not notified"
	)
	equal(2, #notifications, "returned provider capture failure notified more than once")
	vim.cmd("enew!")
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			capture_location = function()
				return nil
			end,
		},
	})
	equal(nil, tab_first.capture(), "neutral provider capture fabricated a location")
	equal(2, #notifications, "neutral provider capture emitted an error")

	local first = {
		kind = "provider",
		provider = "review",
		document_key = "session:file.lua",
		location_key = "1:1",
		label = "Review file.lua:1:1",
		payload = {},
	}
	local second = vim.tbl_extend("force", vim.deepcopy(first), { location_key = "2:1" })
	local third = vim.tbl_extend("force", vim.deepcopy(first), { location_key = "3:1" })
	assert(tab_first.record_transition(first, second), "provider error fixture was not recorded")
	assert(tab_first.record_transition(second, third), "provider error destination was not recorded")
	local restore_calls = {}
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			capture_location = function()
				return third
			end,
			restore_location = function(entry)
				restore_calls[#restore_calls + 1] = entry.location_key
				if entry.location_key == second.location_key then
					error("restore exploded")
				end
				return true
			end,
		},
	})
	assert(not tab_first.back({ fallback = false }), "failed provider restore reported movement")
	assert(notifications[#notifications]:find("restore exploded", 1, true), "provider restore failure was not notified")
	equal({ "2:1" }, restore_calls, "provider restore failure continued into older history")
	equal(3, tab_first.history_snapshot().index, "provider restore failure advanced the history index")

	local notifications_before_reported_failure = #notifications
	restore_calls = {}
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			capture_location = function()
				return third
			end,
			restore_location = function(entry)
				restore_calls[#restore_calls + 1] = entry.location_key
				return false, "restore was already reported", true
			end,
		},
	})
	assert(not tab_first.back({ fallback = false }), "reported provider failure claimed movement")
	equal({ "2:1" }, restore_calls, "reported provider failure continued into older history")
	equal(
		notifications_before_reported_failure,
		#notifications,
		"provider failure reported by its owner was notified twice"
	)
end)

test("malformed public history entries are rejected without poisoning the stack", function()
	reset_editor()
	local valid = { path = "/tmp/valid-history-entry", lnum = 1, col = 1 }
	for _, malformed in ipairs({
		{},
		{ path = "/tmp/missing-position" },
		{ path = "/tmp/invalid-line", lnum = 0, col = 1 },
		{ path = "/tmp/invalid-column", lnum = 1, col = 0 },
		{
			kind = "provider",
			provider = "review",
			document_key = "document",
			location_key = "location",
			label = "Missing payload",
		},
	}) do
		assert(not tab_first.record_transition(malformed, valid), "malformed origin entered history")
		assert(not tab_first.record_transition(valid, malformed), "malformed destination entered history")
	end
	equal({ entries = {}, index = 0 }, tab_first.history_snapshot(), "malformed entries changed history")
end)

test("counted traversal skips stale entries without consuming a step", function()
	reset_editor()
	local first = make_file("history-stale-first")
	local stale = make_file("history-stale-middle")
	local third = make_file("history-stale-third")
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	tab_first.open(stale)
	local stale_buf = vim.api.nvim_get_current_buf()
	tab_first.open(third)
	vim.api.nvim_buf_delete(stale_buf, { force = true })
	vim.fn.delete(stale)

	assert(tab_first.back({ count = 1, fallback = false }), "stale entry consumed the requested step")
	equal(vim.uv.fs_realpath(first), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), "stale skip landed incorrectly")
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

test("closed-location adapter errors are visible and do not advance history", function()
	reset_editor()
	local first = make_file("history-adapter-error-first")
	local second = make_file("history-adapter-error-second")
	local notifications = {}
	tab_first.setup({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		history = {
			open_location = function()
				error("adapter exploded")
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local first_tab = vim.api.nvim_get_current_tabpage()
	tab_first.open(second)
	vim.api.nvim_set_current_tabpage(first_tab)
	vim.cmd("tabclose")

	local before = tab_first.history_snapshot()
	assert(not tab_first.back({ fallback = false }), "failed adapter reported a traversal")
	equal(before.index, tab_first.history_snapshot().index, "failed adapter advanced the history index")
	assert(
		notifications[#notifications]:find("adapter exploded", 1, true),
		"closed-location adapter failure was not notified"
	)
end)

test("closed-location adapters must confirm restoration explicitly", function()
	reset_editor()
	local first = make_file("history-adapter-nil-first")
	local second = make_file("history-adapter-nil-second")
	tab_first.setup({
		history = {
			open_location = function()
				return nil
			end,
		},
	})
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	local first_tab = vim.api.nvim_get_current_tabpage()
	tab_first.open(second)
	vim.api.nvim_set_current_tabpage(first_tab)
	vim.cmd("tabclose")

	local before = tab_first.history_snapshot()
	assert(not tab_first.back({ fallback = false }), "unconfirmed adapter reported a traversal")
	equal(before.index, tab_first.history_snapshot().index, "unconfirmed adapter advanced the history index")
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

test("disabling populated history delegates to the native fallback", function()
	reset_editor()
	local first = make_file("disabled-populated-first")
	local second = make_file("disabled-populated-second")
	vim.cmd("edit! " .. vim.fn.fnameescape(first))
	tab_first.open(second)
	local fallback
	tab_first.setup({
		history = {
			enabled = false,
			native_fallback = function(direction, count)
				fallback = { direction, count }
			end,
		},
	})
	assert(not tab_first.back({ count = 3 }), "disabled populated history reported a semantic traversal")
	equal({ -1, 3 }, fallback, "disabled populated history did not delegate the native count")
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
