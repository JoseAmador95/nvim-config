vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local session = require("plugins.auto-session")
local pre_save = session.opts.pre_save_cmds[1]
local original_code_review = package.loaded["config.code_review"]
local original_code_review_preload = package.preload["config.code_review"]
local original_schedule = vim.schedule
local original_create_autocmd = vim.api.nvim_create_autocmd
local original_auto_session = package.loaded["auto-session"]
local original_restore_env = vim.env.NVIM_TMUX_REFRESH_RESTORE

test("autosave leaves transient teardown to the review pre-save hook", function()
	equal(false, session.opts.close_unsupported_windows, "auto-session can close a composer before review suspension")
end)

local function reset_editor()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.bo[buf].modified = false
		end
	end
	pcall(vim.cmd, "silent! tabonly!")
	pcall(vim.cmd, "silent! only!")
	vim.cmd("enew!")
end

test("pre-save remains harmless without code review and preserves skip-empty", function()
	reset_editor()
	local attempted_loads = 0
	package.loaded["config.code_review"] = nil
	package.preload["config.code_review"] = function()
		attempted_loads = attempted_loads + 1
		error("fixture module unavailable")
	end
	equal(false, pre_save(), "empty editor was no longer skipped")

	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-normal.lua")
	equal(true, pre_save(), "normal file window was unexpectedly skipped")
	equal(0, attempted_loads, "session save activated an unloaded review adapter")
end)

test("automatic pre-save suspends synchronously and never restores review UI", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-review.lua")
	local suspended = 0
	local restored = 0
	local scheduled = {}
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			suspended = suspended + 1
			return true
		end,
		restore_after_session = function()
			restored = restored + 1
			return true
		end,
	}
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end

	equal(true, pre_save(), "review suspension changed the normal-file save result")
	equal(1, suspended, "review was not suspended before returning from pre-save")
	equal(0, restored, "review restored synchronously before session serialization")
	equal(0, #scheduled, "automatic save scheduled review tab reacquisition")

	vim.schedule = original_schedule
end)

test("pre-save vetoes session serialization when review suspension fails", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-failed-review.lua")
	local scheduled = {}
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			return nil, "fixture close failed"
		end,
		restore_after_session = function()
			error("restore must not be scheduled")
		end,
	}
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end

	equal(false, pre_save(), "failed review suspension did not veto session save")
	equal(0, #scheduled, "restore was scheduled after failed suspension")
	vim.schedule = original_schedule
end)

test("manual save suspends before calling the plugin and bypasses its ignored veto", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-manual-session.lua")
	local suspended = 0
	local saved = 0
	local restored = 0
	local lease_active = true
	local scheduled = {}
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			suspended = suspended + 1
			lease_active = false
			return true
		end,
		restore_after_session = function()
			restored = restored + 1
			lease_active = true
			return true
		end,
	}
	package.loaded["auto-session"] = {
		save_session = function()
			saved = saved + 1
			equal(false, lease_active, "review lease survived into session serialization")
			equal(true, pre_save(), "manual plugin save tried to suspend the review twice")
			return true
		end,
	}
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end

	equal(true, session.keys[1][2](), "manual save failed")
	equal(1, suspended, "manual save did not suspend before serialization")
	equal(1, saved, "manual save did not call the plugin exactly once")
	equal(1, #scheduled, "manual save did not schedule review restoration")
	equal(0, restored, "manual save restored before successful serialization returned")
	equal(false, lease_active, "review lease was reacquired before the scheduled restore")
	scheduled[1]()
	equal(1, restored, "successful manual save did not restore the review UI")
	equal(true, lease_active, "successful manual save did not reacquire review UI")
	vim.schedule = original_schedule
end)

test("failed manual save leaves review UI suspended and schedules no restore", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-failed-manual-session.lua")
	local suspended = 0
	local restored = 0
	local scheduled = {}
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			suspended = suspended + 1
			return true
		end,
		restore_after_session = function()
			restored = restored + 1
			return true
		end,
	}
	package.loaded["auto-session"] = {
		save_session = function()
			return false
		end,
	}
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end

	equal(false, session.keys[1][2](), "failed upstream save was reported as successful")
	equal(1, suspended, "failed manual save did not suspend before serialization")
	equal(0, restored, "failed manual save restored the review UI")
	equal(0, #scheduled, "failed manual save scheduled review tab reacquisition")
	vim.schedule = original_schedule
end)

test("VimLeavePre is registered before auto-session and suppresses scheduled restoration", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-exit.lua")
	local order = {}
	local leave_callback
	local scheduled = {}
	local suspended = 0
	local restored = 0
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			suspended = suspended + 1
			return true
		end,
		restore_after_session = function()
			restored = restored + 1
			return true
		end,
	}
	package.loaded["auto-session"] = {
		save_session = function()
			return true
		end,
		setup = function()
			order[#order + 1] = "setup"
		end,
	}
	vim.api.nvim_create_autocmd = function(event, options)
		order[#order + 1] = "autocmd:" .. event
		if event == "VimLeavePre" then
			leave_callback = options.callback
		end
		return 1
	end
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	vim.env.NVIM_TMUX_REFRESH_RESTORE = nil

	session.config(nil, session.opts)
	equal({ "autocmd:VimLeavePre", "setup" }, order, "exit flag was not registered before auto-session setup")
	assert(type(leave_callback) == "function", "VimLeavePre callback is missing")
	equal(true, package.loaded["auto-session"].save_session(), "manual save unexpectedly failed")
	equal(1, #scheduled, "successful manual save did not initially schedule restoration")
	leave_callback()
	scheduled[1]()
	equal(1, suspended, "review was not suspended for the exit save")
	equal(0, restored, "review was restored while Neovim was exiting")
end)

test("manual save wrapper preserves upstream options", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-options.lua")
	local captured
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			return true
		end,
	}
	package.loaded["auto-session"] = {
		save_session = function(name, options)
			captured = { name = name, options = options }
			return true
		end,
		setup = function() end,
	}
	session.config(nil, session.opts)
	local options = { show_message = false }
	equal(true, package.loaded["auto-session"].save_session("named", options), "wrapped save failed")
	equal({ name = "named", options = options }, captured, "wrapped save changed upstream options")
end)

test("repeated config keeps one wrapper around the same upstream save", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-session-idempotent.lua")
	local upstream_calls = 0
	local setup_calls = 0
	package.loaded["config.code_review"] = {
		suspend_for_session = function()
			return true
		end,
	}
	local auto_session = {
		save_session = function(name, options)
			upstream_calls = upstream_calls + 1
			equal("idempotent", name, "repeated config changed the session name")
			equal(false, options.show_message, "repeated config changed save options")
			return true
		end,
		setup = function()
			setup_calls = setup_calls + 1
		end,
	}
	package.loaded["auto-session"] = auto_session
	session.config(nil, session.opts)
	local wrapper = auto_session.save_session
	session.config(nil, session.opts)
	equal(wrapper, auto_session.save_session, "repeated config wrapped its own save wrapper")
	local alternate = {
		save_session = function()
			return true
		end,
		setup = function() end,
	}
	package.loaded["auto-session"] = alternate
	session.config(nil, session.opts)
	package.loaded["auto-session"] = auto_session
	session.config(nil, session.opts)
	equal(wrapper, auto_session.save_session, "module replacement caused an old wrapper to wrap itself")
	equal(
		true,
		auto_session.save_session("idempotent", { show_message = false }),
		"idempotent wrapper declined the upstream save"
	)
	equal(1, upstream_calls, "idempotent wrapper did not call upstream exactly once")
	equal(3, setup_calls, "repeated config skipped upstream setup")
end)

test("session serialization cannot resurrect tagged ephemeral terminals", function()
	reset_editor()
	vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. "-durable-session.lua")
	package.loaded["auto-session"] = {
		save_session = function()
			return true
		end,
		setup = function() end,
	}
	session.config(nil, session.opts)
	local configured = vim.opt.sessionoptions:get()
	assert(not vim.tbl_contains(configured, "terminal"), "sessionoptions still permits terminal resurrection")

	vim.cmd("botright new")
	local terminal_buf = vim.api.nvim_get_current_buf()
	local job = vim.fn.jobstart({ vim.o.shell, "-c", "sleep 30" }, { term = true })
	assert(job > 0 and vim.bo[terminal_buf].buftype == "terminal", "terminal fixture did not start")
	vim.b[terminal_buf].terminal_lifecycle = { key = "fixture", ephemeral = true }
	vim.b[terminal_buf].terminal_lifecycle_ephemeral = true
	local terminal_name = vim.api.nvim_buf_get_name(terminal_buf)
	assert(terminal_name ~= "", "terminal fixture has no session identity")

	local session_path = vim.fn.tempname() .. ".vim"
	vim.cmd("silent! mksession! " .. vim.fn.fnameescape(session_path))
	local serialized = table.concat(vim.fn.readfile(session_path), "\n")
	assert(not serialized:find(terminal_name, 1, true), "ephemeral terminal was serialized into the session")
	vim.fn.jobstop(job)
	vim.bo[terminal_buf].modified = false
	vim.api.nvim_buf_delete(terminal_buf, { force = true })

	vim.cmd("silent! tabonly!")
	vim.cmd("silent! only!")
	vim.cmd("silent! source " .. vim.fn.fnameescape(session_path))
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			assert(vim.bo[buf].buftype ~= "terminal", "session restore resurrected a terminal process buffer")
		end
	end
	vim.fn.delete(session_path)
end)

package.loaded["config.code_review"] = original_code_review
package.preload["config.code_review"] = original_code_review_preload
package.loaded["auto-session"] = original_auto_session
vim.schedule = original_schedule
vim.api.nvim_create_autocmd = original_create_autocmd
vim.env.NVIM_TMUX_REFRESH_RESTORE = original_restore_env

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("auto_session_spec: %d tests passed", count))
vim.cmd("quitall!")
