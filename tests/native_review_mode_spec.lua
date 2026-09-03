-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local mode = require("config.native_review").mode
local review_lsp = require("config.native_review").lsp
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
local path = fixture .. "/current.lua"
assert(vim.fn.writefile({ "one", "two" }, path) == 0)
local late_path = fixture .. "/late.lua"
assert(vim.fn.writefile({ "late" }, late_path) == 0)

local function reset()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modified = false
		end
	end
	vim.cmd("silent! only")
	vim.cmd("enew!")
	vim.cmd("edit! " .. vim.fn.fnameescape(path))
end

local function workspace()
	return {
		root = vim.uv.fs_realpath(fixture),
		model = { entries = { { old_path = "current.lua", new_path = "current.lua" } } },
	}
end

local function buffer_mapping(buf, lhs)
	local mapping
	vim.api.nvim_buf_call(buf, function()
		mapping = vim.fn.maparg(lhs, "n", false, true)
	end)
	return mapping
end

test("enable protects affected real buffers and restores exact local mappings", function()
	reset()
	local buf = vim.api.nvim_get_current_buf()
	vim.keymap.set("n", "[h", "gg", { buffer = buf, silent = false, nowait = true, desc = "Previous custom map" })
	vim.keymap.set("n", "]h", "G", { buffer = buf, silent = true, desc = "Next custom map" })
	local before_left = vim.fn.maparg("[h", "n", false, true)
	local before_right = vim.fn.maparg("]h", "n", false, true)
	local state = mode.new(workspace())
	local enabled, err = mode.enable(state)
	assert(enabled, err)
	assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable)
	assert(mode.active_for_buffer(buf) == state)
	assert(vim.fn.maparg("[h", "n", false, true).desc == "Previous review hunk")
	mode.disable(state)
	assert(not vim.bo[buf].readonly and vim.bo[buf].modifiable and mode.active_for_buffer(buf) == nil)
	local after_left = vim.fn.maparg("[h", "n", false, true)
	local after_right = vim.fn.maparg("]h", "n", false, true)
	for _, key in ipairs({ "rhs", "noremap", "silent", "nowait", "desc" }) do
		assert(before_left[key] == after_left[key], "left mapping field changed: " .. key)
		assert(before_right[key] == after_right[key], "right mapping field changed: " .. key)
	end
	vim.keymap.del("n", "[h", { buffer = buf })
	vim.keymap.del("n", "]h", { buffer = buf })
end)

test("active protection immediately rejects local option escapes", function()
	reset()
	local buf = vim.api.nvim_get_current_buf()
	local state = mode.new(workspace())
	assert(mode.enable(state))
	vim.cmd("noautocmd setlocal noreadonly")
	vim.api.nvim_exec_autocmds("OptionSet", { pattern = "readonly" })
	assert(vim.bo[buf].readonly, "readonly escape survived OptionSet")
	vim.cmd("noautocmd setlocal modifiable")
	vim.api.nvim_exec_autocmds("OptionSet", { pattern = "modifiable" })
	assert(not vim.bo[buf].modifiable, "modifiable escape survived OptionSet")
	local changed = pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { "mutated" })
	assert(not changed and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "one")

	vim.cmd("noautocmd setlocal noreadonly modifiable")
	assert(mode.enroll(state, buf), "reenrolling did not repair protected options")
	assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable)
	mode.disable(state)
	assert(not vim.bo[buf].readonly and vim.bo[buf].modifiable, "disable did not restore ordinary options")
end)

test("transient protection rejects escapes without active-buffer roles and releases every owner", function()
	reset()
	local state = mode.new(workspace())
	assert(mode.enable(state))
	local transient = vim.api.nvim_create_buf(false, true)
	vim.bo[transient].buftype = "nofile"
	assert(mode.protect_transient(state, transient))
	assert(vim.bo[transient].readonly and not vim.bo[transient].modifiable)
	assert(mode.active_for_buffer(transient) == nil, "transient became an active current review buffer")
	assert(vim.b[transient].nvim_review_role == nil, "transient protection assigned an LSP role")
	assert(buffer_mapping(transient, "[h").buffer ~= 1 and buffer_mapping(transient, "]h").buffer ~= 1)

	vim.api.nvim_buf_call(transient, function()
		vim.cmd("noautocmd setlocal noreadonly")
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "readonly" })
		vim.cmd("noautocmd setlocal modifiable")
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "modifiable" })
	end)
	assert(vim.bo[transient].readonly and not vim.bo[transient].modifiable, "transient option escape survived")
	assert(not pcall(vim.api.nvim_buf_set_lines, transient, 0, -1, false, { "mutated" }))

	assert(mode.release_transient(state, transient))
	assert(next(state.protected_transients) == nil and mode.enforce_protection(transient) == false)
	vim.api.nvim_buf_call(transient, function()
		vim.cmd("noautocmd setlocal noreadonly modifiable")
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "modifiable" })
	end)
	assert(not vim.bo[transient].readonly and vim.bo[transient].modifiable, "released transient stayed owned")

	assert(mode.protect_transient(state, transient))
	vim.api.nvim_buf_delete(transient, { force = true })
	assert(next(state.protected_transients) == nil, "BufWipeout retained transient ownership")
	assert(mode.enforce_protection(transient) == false)

	local lingering = vim.api.nvim_create_buf(false, true)
	vim.bo[lingering].buftype = "nofile"
	assert(mode.protect_transient(state, lingering))
	mode.disable(state)
	assert(next(state.protected_transients) == nil, "disable retained transient ownership")
	assert(mode.active_for_buffer(lingering) == nil and mode.enforce_protection(lingering) == false)
	vim.api.nvim_buf_delete(lingering, { force = true })
end)

test("modified affected buffers are refused without partial state", function()
	reset()
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "modified" })
	local state = mode.new(workspace())
	local enabled, err = mode.enable(state)
	assert(enabled == nil and err:find("unsaved changes", 1, true))
	assert(not state.enabled and mode.active_for_buffer(buf) == nil and vim.bo[buf].modifiable)
	vim.bo[buf].modified = false
end)

test("non-current buffer mappings are captured and restored in that buffer", function()
	reset()
	local origin = vim.api.nvim_get_current_buf()
	local hidden = vim.api.nvim_create_buf(true, true)
	vim.keymap.set("n", "[h", "gg", { buffer = hidden, silent = false, nowait = true, desc = "Hidden previous" })
	vim.keymap.set("n", "]h", "G", { buffer = hidden, silent = true, desc = "Hidden next" })
	local before_left
	local before_right
	vim.api.nvim_buf_call(hidden, function()
		before_left = vim.fn.maparg("[h", "n", false, true)
		before_right = vim.fn.maparg("]h", "n", false, true)
	end)
	local state = mode.new(workspace())
	state.enabled = true
	assert(mode.enroll(state, hidden))
	assert(vim.api.nvim_get_current_buf() == origin, "enrolling a hidden buffer changed focus")
	mode.disable(state)
	vim.api.nvim_buf_call(hidden, function()
		local after_left = vim.fn.maparg("[h", "n", false, true)
		local after_right = vim.fn.maparg("]h", "n", false, true)
		for _, key in ipairs({ "rhs", "noremap", "silent", "nowait", "desc" }) do
			assert(before_left[key] == after_left[key], "hidden left mapping field changed: " .. key)
			assert(before_right[key] == after_right[key], "hidden right mapping field changed: " .. key)
		end
	end)
	vim.api.nvim_buf_delete(hidden, { force = true })
end)

test("suspend restores and reenrolls while disable closes only owned auxiliary windows", function()
	reset()
	local state = mode.new(workspace())
	assert(mode.enable(state))
	local buf = vim.api.nvim_get_current_buf()
	local suspended = mode.suspend(state)
	assert(vim.bo[buf].modifiable and mode.active_for_buffer(buf) == nil)
	assert(mode.restore(state, suspended))
	assert(not vim.bo[buf].modifiable and mode.active_for_buffer(buf) == state)

	local unrelated_buf = vim.api.nvim_create_buf(false, true)
	local unrelated_win = vim.api.nvim_open_win(unrelated_buf, false, { split = "left", win = state.origin.win })
	local aux_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[aux_buf].buftype = "nofile"
	local aux_win = vim.api.nvim_open_win(aux_buf, false, { split = "right", win = state.origin.win })
	mode.set_auxiliary(state, "fixture", aux_win, aux_buf)
	local tabs_before = #vim.api.nvim_list_tabpages()
	mode.disable(state)
	assert(not vim.api.nvim_win_is_valid(aux_win), "owned auxiliary window survived")
	assert(vim.api.nvim_win_is_valid(unrelated_win), "unrelated window was closed")
	assert(#vim.api.nvim_list_tabpages() == tabs_before, "ordinary review created or closed a tab")
	vim.api.nvim_win_close(unrelated_win, true)
end)

test("suspend and disable invalidate CURRENT definition routing metadata", function()
	reset()
	local buf = vim.api.nvim_get_current_buf()
	local state = mode.new(workspace())
	state.handlers.definition_options = function()
		return {
			valid = function()
				return true
			end,
			route = function()
				return true
			end,
		}
	end
	assert(mode.enable(state))
	local pending = assert(review_lsp.definition_options(buf, vim.api.nvim_get_current_win()))
	assert(pending.valid() and review_lsp._metadata[buf] ~= nil)
	local suspended = mode.suspend(state)
	assert(not pending.valid(), "suspending review left a CURRENT definition response live")
	assert(review_lsp._metadata[buf] == nil and review_lsp.definition_options(buf) == nil)
	assert(mode.restore(state, suspended))
	local restored = assert(review_lsp.definition_options(buf, vim.api.nvim_get_current_win()))
	assert(restored.valid())
	mode.disable(state)
	assert(not restored.valid(), "disabling review left a CURRENT definition response live")
	assert(review_lsp._metadata[buf] == nil and review_lsp.definition_options(buf) == nil)
end)

test("restore enrolls affected buffers opened while review mode is suspended", function()
	reset()
	local state = mode.new({
		root = vim.uv.fs_realpath(fixture),
		model = {
			entries = {
				{ old_path = "current.lua", new_path = "current.lua" },
				{ old_path = "late.lua", new_path = "late.lua" },
			},
		},
	})
	assert(mode.enable(state))
	local origin = vim.api.nvim_get_current_buf()
	local suspended = mode.suspend(state)
	assert(vim.bo[origin].modifiable and mode.active_for_buffer(origin) == nil)

	vim.cmd("edit " .. vim.fn.fnameescape(late_path))
	local late = vim.api.nvim_get_current_buf()
	assert(vim.bo[late].modifiable and mode.active_for_buffer(late) == nil)
	assert(mode.restore(state, suspended))
	for _, buf in ipairs({ origin, late }) do
		assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable, "restore left an affected buffer writable")
		assert(mode.active_for_buffer(buf) == state, "restore did not enroll an affected buffer")
	end
	mode.disable(state)
	for _, buf in ipairs({ origin, late }) do
		assert(not vim.bo[buf].readonly and vim.bo[buf].modifiable, "disable did not restore an affected buffer")
		assert(mode.active_for_buffer(buf) == nil)
	end
	vim.api.nvim_buf_delete(late, { force = true })
end)

test("restore preflight failure leaves every affected buffer in its prior ordinary state", function()
	reset()
	local state = mode.new({
		root = vim.uv.fs_realpath(fixture),
		model = {
			entries = {
				{ old_path = "current.lua", new_path = "current.lua" },
				{ old_path = "late.lua", new_path = "late.lua" },
			},
		},
	})
	assert(mode.enable(state))
	local origin = vim.api.nvim_get_current_buf()
	local suspended = mode.suspend(state)
	vim.cmd("edit " .. vim.fn.fnameescape(late_path))
	local late = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(late, 0, 1, false, { "changed while suspended" })

	local restored, restore_err = mode.restore(state, suspended)
	assert(restored == nil and restore_err:find("unsaved changes", 1, true), restore_err)
	assert(not state.enabled, "failed restore left review mode enabled")
	for _, buf in ipairs({ origin, late }) do
		assert(vim.bo[buf].modifiable and not vim.bo[buf].readonly, "failed restore partially enrolled a buffer")
		assert(mode.active_for_buffer(buf) == nil, "failed restore retained active buffer ownership")
	end
	vim.cmd("edit!")
	vim.api.nvim_buf_delete(late, { force = true })
end)

test("restore rolls back exact buffer state when reenrollment fails partway", function()
	reset()
	local state = mode.new({
		root = vim.uv.fs_realpath(fixture),
		model = {
			entries = {
				{ old_path = "current.lua", new_path = "current.lua" },
				{ old_path = "late.lua", new_path = "late.lua" },
			},
		},
	})
	assert(mode.enable(state))
	local origin = vim.api.nvim_get_current_buf()
	local suspended = mode.suspend(state)
	vim.keymap.set("n", "[h", "gg", { buffer = origin, silent = false, desc = "Suspended origin map" })
	vim.cmd("edit " .. vim.fn.fnameescape(late_path))
	local late = vim.api.nvim_get_current_buf()
	vim.bo[late].readonly = true
	vim.keymap.set("n", "[h", "G", { buffer = late, silent = true, desc = "Suspended late map" })
	local before = {
		[origin] = buffer_mapping(origin, "[h"),
		[late] = buffer_mapping(late, "[h"),
	}

	local original_enroll = mode.enroll
	local enroll_calls = 0
	mode.enroll = function(...)
		enroll_calls = enroll_calls + 1
		if enroll_calls == 2 then
			return nil, "simulated reenrollment failure"
		end
		return original_enroll(...)
	end
	local called, restored, restore_err = pcall(mode.restore, state, suspended)
	mode.enroll = original_enroll
	assert(called, restored)
	assert(restored == nil and restore_err == "simulated reenrollment failure", restore_err)
	assert(not state.enabled, "failed reenrollment left review mode enabled")
	for _, buf in ipairs({ origin, late }) do
		assert(vim.bo[buf].modifiable and mode.active_for_buffer(buf) == nil, "reenrollment rollback was partial")
		local after = buffer_mapping(buf, "[h")
		assert(after.rhs == before[buf].rhs and after.desc == before[buf].desc, "rollback changed a prior mapping")
	end
	assert(not vim.bo[origin].readonly and vim.bo[late].readonly, "rollback changed prior readonly values")
	vim.keymap.del("n", "[h", { buffer = origin })
	vim.keymap.del("n", "[h", { buffer = late })
	vim.api.nvim_buf_delete(late, { force = true })
end)

test("suspend restore disable preserves exact manual fold states", function()
	reset()
	local lines = { "one", "two", "three", "four", "five", "six", "seven", "eight" }
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	vim.bo.modified = false
	local win = vim.api.nvim_get_current_win()
	vim.wo[win].foldmethod = "manual"
	vim.wo[win].foldenable = true
	vim.wo[win].foldlevel = 0
	vim.cmd("silent! normal! zE")
	vim.cmd("1,2fold")
	vim.cmd("5,6fold")
	vim.cmd("normal! ggzo")
	local state = mode.new(workspace())
	assert(mode.enable(state))
	local suspended = mode.suspend(state)
	vim.cmd("normal! zM")
	assert(mode.restore(state, suspended))
	mode.disable(state)
	assert(vim.wo[win].foldmethod == "manual" and vim.wo[win].foldenable and vim.wo[win].foldlevel == 0)
	assert(vim.fn.foldclosed(1) == -1, "disable closed the manually opened fold")
	assert(vim.fn.foldclosed(5) == 5, "disable opened the manually closed fold")
end)

test("window restoration leaves non-manual fold definitions derived from the buffer", function()
	reset()
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "-- {{{", "inside", "-- }}}", "outside" })
	vim.bo.modified = false
	local win = vim.api.nvim_get_current_win()
	vim.wo[win].foldmethod = "marker"
	vim.wo[win].foldenable = true
	vim.wo[win].foldlevel = 0
	assert(vim.fn.foldclosedend(1) == 3, "marker fold fixture is not closed")
	local state = mode.new(workspace())
	assert(mode.enable(state))
	vim.wo[win].foldmethod = "manual"
	vim.cmd("silent! normal! zE")
	vim.wo[win].foldenable = false
	mode.disable(state)
	assert(vim.wo[win].foldmethod == "marker" and vim.wo[win].foldenable and vim.wo[win].foldlevel == 0)
	assert(vim.fn.foldclosedend(1) == 3, "non-manual fold definition or state changed")
end)

test("window snapshots are consumed so later cycles preserve newer ordinary state", function()
	reset()
	local win = vim.api.nvim_get_current_win()
	vim.wo[win].wrap = true
	local state = mode.new(workspace())
	assert(mode.enable(state))
	vim.wo[win].wrap = false
	mode.disable(state)
	assert(vim.wo[win].wrap, "first cycle did not restore its window snapshot")
	assert(state.window_snapshots[win] == nil, "restored snapshot was retained")

	vim.wo[win].wrap = false
	assert(mode.enable(state))
	mode.capture_window(state, win)
	vim.wo[win].wrap = true
	mode.disable(state)
	assert(not vim.wo[win].wrap, "second cycle clobbered the newer ordinary option")
	assert(state.window_snapshots[win] == nil, "second restored snapshot was retained")
end)

test("window snapshots restore the exact local winbar across review cycles", function()
	reset()
	local win = vim.api.nvim_get_current_win()
	local first = "%#Title#ordinary %% first%*"
	vim.wo[win].winbar = first
	local state = mode.new(workspace())
	assert(mode.enable(state))
	vim.wo[win].winbar = " REV ON · inline/hunks "
	mode.disable(state)
	assert(vim.wo[win].winbar == first, "first review cycle did not restore winbar")

	local second = "%#Comment#ordinary %% second%*"
	vim.wo[win].winbar = second
	assert(mode.enable(state))
	mode.capture_window(state, win)
	assert(state.window_snapshots[win], "later review cycle did not capture the window")
	vim.wo[win].winbar = " REV OFF · split/full "
	mode.disable(state)
	assert(vim.wo[win].winbar == second, "later review cycle restored a stale winbar")
	assert(state.window_snapshots[win] == nil, "restored winbar snapshot was retained")
end)

test("window snapshots restore gutter options and inherited fillchars exactly", function()
	reset()
	local win = vim.api.nvim_get_current_win()
	local previous_global_fillchars = vim.o.fillchars
	local previous_local_fillchars = vim.api.nvim_get_option_value("fillchars", { scope = "local", win = win })
	local previous = {
		number = vim.wo[win].number,
		numberwidth = vim.wo[win].numberwidth,
		relativenumber = vim.wo[win].relativenumber,
		signcolumn = vim.wo[win].signcolumn,
		statuscolumn = vim.wo[win].statuscolumn,
	}
	local ok, err = xpcall(function()
		vim.o.fillchars = "diff:-,eob:~"
		vim.api.nvim_set_option_value("fillchars", "", { scope = "local", win = win })
		vim.wo[win].number = false
		vim.wo[win].relativenumber = true
		vim.wo[win].numberwidth = 6
		vim.wo[win].signcolumn = "yes:2"
		vim.wo[win].statuscolumn = "%=%l "
		local state = mode.new(workspace())
		assert(state.window_snapshots[win].local_options.fillchars == "")
		assert(mode.enable(state))
		vim.api.nvim_win_call(win, function()
			vim.opt_local.fillchars = { diff = " ", eob = "!" }
		end)
		vim.wo[win].number = true
		vim.wo[win].relativenumber = false
		vim.wo[win].numberwidth = 2
		vim.wo[win].signcolumn = "auto:1-9"
		vim.wo[win].statuscolumn = "%s%l"
		mode.disable(state)
		assert(vim.api.nvim_get_option_value("fillchars", { scope = "local", win = win }) == "")
		assert(vim.opt_local.fillchars:get().diff == "-", "restored window stopped inheriting global fillchars")
		assert(not vim.wo[win].number and vim.wo[win].relativenumber)
		assert(vim.wo[win].numberwidth == 6)
		assert(vim.wo[win].signcolumn == "yes:2")
		assert(vim.wo[win].statuscolumn == "%=%l ")
	end, debug.traceback)
	vim.o.fillchars = previous_global_fillchars
	vim.api.nvim_set_option_value("fillchars", previous_local_fillchars, { scope = "local", win = win })
	for name, value in pairs(previous) do
		vim.wo[win][name] = value
	end
	assert(ok, err)
end)

test("late affected buffers enroll only while enabled and refuse unsaved changes", function()
	reset()
	local state = mode.new({
		root = vim.uv.fs_realpath(fixture),
		model = { entries = { { old_path = "late.lua", new_path = "late.lua" } } },
	})
	local origin = vim.api.nvim_get_current_buf()
	assert(mode.enable(state))
	assert(mode.active_for_buffer(origin) == nil, "unaffected origin buffer was enrolled")
	assert(mode.enroll_affected_buffer(state, origin) == false)

	vim.cmd("edit " .. vim.fn.fnameescape(late_path))
	local late = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(late, 0, 1, false, { "changed" })
	local enrolled, err = mode.enroll_affected_buffer(state, late)
	assert(enrolled == nil and err:find("unsaved changes", 1, true), err)
	assert(mode.active_for_buffer(late) == nil and vim.bo[late].modifiable)

	vim.cmd("edit!")
	enrolled, err = mode.enroll_affected_buffer(state, late)
	assert(enrolled, err)
	assert(mode.active_for_buffer(late) == state)
	assert(vim.bo[late].readonly and not vim.bo[late].modifiable)
	mode.disable(state)
	assert(mode.enroll_affected_buffer(state, late) == false)
	assert(mode.active_for_buffer(late) == nil and vim.bo[late].modifiable)
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_mode_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
