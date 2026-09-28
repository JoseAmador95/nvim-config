vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

local original_local_config = package.loaded["config.local_config"]
local profile = "low-bandwidth"
local inline_mode
local ui_overrides = {}
package.loaded["config.local_config"] = {
	get = function(name)
		assert(name == "ui")
		return vim.tbl_extend("force", {
			redraw_profile = profile,
			inline_diagnostics = inline_mode,
		}, ui_overrides)
	end,
}
package.loaded["config.redraw_profile"] = nil

local redraw = require("config.redraw_profile")
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

local function event(name)
	vim.api.nvim_exec_autocmds(name, { modeline = false })
end

test("the selected profile is frozen for the process", function()
	redraw._reset_for_tests()
	assert(redraw.current() == "low-bandwidth")
	profile = "full"
	assert(redraw.configured() == "low-bandwidth")
	assert(redraw.current() == "low-bandwidth")
end)

test("full-profile presentation costs adapt to SSH and accept explicit host overrides", function()
	local original_ssh_tty = vim.env.SSH_TTY
	local original_ssh_connection = vim.env.SSH_CONNECTION
	local original_appname = vim.env.NVIM_APPNAME
	local original_vscode = vim.g.vscode
	profile = "full"
	inline_mode = nil
	ui_overrides = {}
	vim.g.vscode = nil
	vim.env.NVIM_APPNAME = nil
	vim.env.SSH_TTY = ""
	vim.env.SSH_CONNECTION = ""
	redraw._reset_for_tests()
	assert(not redraw.remote_transport())
	assert(redraw.refresh_ms() == 16)
	assert(redraw.noice_progress_throttle_ms() == 1000 / 30)
	assert(redraw.bufferline_diagnostics() and redraw.bufferline_hover())

	vim.env.SSH_CONNECTION = "fixture"
	redraw._reset_for_tests()
	assert(redraw.current() == "full" and redraw.remote_transport())
	assert(redraw.refresh_ms() == 50)
	assert(redraw.noice_progress_throttle_ms() == 100)
	assert(not redraw.bufferline_diagnostics() and not redraw.bufferline_hover())

	ui_overrides = {
		full_refresh_ms = 75,
		noice_progress_throttle_ms = 125,
		bufferline_diagnostics = true,
		bufferline_hover = true,
	}
	redraw._reset_for_tests()
	assert(redraw.refresh_ms() == 75)
	assert(redraw.noice_progress_throttle_ms() == 125)
	assert(redraw.bufferline_diagnostics() and redraw.bufferline_hover())

	profile = "low-bandwidth"
	ui_overrides = {}
	redraw._reset_for_tests()
	assert(redraw.refresh_ms() == 100 and redraw.noice_progress_throttle_ms() == 100)
	assert(not redraw.bufferline_diagnostics() and not redraw.bufferline_hover())

	vim.env.SSH_TTY = original_ssh_tty
	vim.env.SSH_CONNECTION = original_ssh_connection
	vim.env.NVIM_APPNAME = original_appname
	vim.g.vscode = original_vscode
	profile = "low-bandwidth"
	inline_mode = nil
	ui_overrides = {}
	redraw._reset_for_tests()
end)

test("inline defaults are transport-aware without changing the redraw profile", function()
	local original_ssh_tty = vim.env.SSH_TTY
	local original_ssh_connection = vim.env.SSH_CONNECTION
	local original_appname = vim.env.NVIM_APPNAME
	local original_vscode = vim.g.vscode

	local function select(expected_profile, expected_inline)
		redraw._reset_for_tests()
		assert(redraw.current() == expected_profile)
		assert(redraw.inline_diagnostics() == expected_inline)
	end

	profile = "full"
	inline_mode = nil
	vim.g.vscode = nil
	vim.env.NVIM_APPNAME = nil
	vim.env.SSH_TTY = ""
	vim.env.SSH_CONNECTION = ""
	select("full", "current-line")

	vim.env.SSH_CONNECTION = "fixture"
	select("full", "settled-line")

	vim.env.SSH_CONNECTION = nil
	profile = "low-bandwidth"
	select("low-bandwidth", "off")

	inline_mode = "current-line"
	select("low-bandwidth", "current-line")

	profile = "low-bandwidth"
	inline_mode = "settled-line"
	vim.g.vscode = 1
	select("full", "off")

	vim.g.vscode = nil
	vim.env.NVIM_APPNAME = "nvimpager"
	select("full", "off")

	vim.env.SSH_TTY = original_ssh_tty
	vim.env.SSH_CONNECTION = original_ssh_connection
	vim.env.NVIM_APPNAME = original_appname
	vim.g.vscode = original_vscode
	profile = "low-bandwidth"
	inline_mode = nil
	redraw._reset_for_tests()
end)

test("only a last detach followed by a reconnect schedules recovery", function()
	redraw._reset_for_tests()
	profile = "low-bandwidth"
	local uis = 0
	local scheduled = {}
	local recovered = {}
	redraw.setup({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end,
		recover = function(selected)
			recovered[#recovered + 1] = selected
		end,
	})

	uis = 1
	event("UIEnter")
	assert(#scheduled == 0, "initial UI attach was treated as a reconnect")
	uis = 2
	event("UIEnter")
	uis = 1
	event("UILeave")
	assert(not redraw.status().detached, "one remaining UI was treated as detached")
	uis = 0
	event("UILeave")
	assert(redraw.status().detached, "last UI detach was not recorded")

	uis = 1
	event("UIEnter")
	uis = 2
	event("UIEnter")
	assert(#scheduled == 1 and redraw.status().pending, "reconnect recovery was not coalesced")
	scheduled[1]()
	assert(vim.deep_equal(recovered, { "low-bandwidth" }), "reconnect did not recover the fixed profile")
	assert(not redraw.status().pending and not redraw.status().detached)
end)

test("detach and teardown invalidate stale scheduled recovery", function()
	redraw._reset_for_tests()
	profile = "low-bandwidth"
	local uis = 1
	local scheduled = {}
	local recoveries = 0
	redraw.setup({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end,
		recover = function()
			recoveries = recoveries + 1
		end,
	})

	uis = 0
	event("UILeave")
	uis = 1
	event("UIEnter")
	local stale = assert(scheduled[1])
	uis = 0
	event("UILeave")
	stale()
	assert(recoveries == 0, "recovery survived a second detach")

	uis = 1
	event("UIEnter")
	local cancelled = assert(scheduled[2])
	assert(redraw.teardown())
	cancelled()
	assert(recoveries == 0, "recovery survived teardown")
end)

test("failed recovery stays detached and can be retried explicitly", function()
	redraw._reset_for_tests()
	local uis = 1
	local scheduled = {}
	local attempts = 0
	redraw.setup({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end,
		recover = function()
			attempts = attempts + 1
			if attempts == 1 then
				error("transient repaint failure")
			end
			return true
		end,
	})

	uis = 0
	event("UILeave")
	uis = 1
	event("UIEnter")
	local ok, err = pcall(scheduled[1])
	assert(ok, "recovery error escaped the scheduled lifecycle: " .. tostring(err))
	local failed = redraw.status()
	assert(failed.detached and not failed.pending)
	assert(failed.last_error:find("transient repaint failure", 1, true))
	assert(redraw.retry() and #scheduled == 2, "failed recovery was not retryable")
	scheduled[2]()
	local recovered = redraw.status()
	assert(not recovered.detached and recovered.last_error == nil and attempts == 2)
end)

test("loaded repaint hooks are protected and cannot suppress the final redraw", function()
	redraw._reset_for_tests()
	local uis = 1
	local scheduled = {}
	local healthy_calls = 0
	local redraw_calls = 0
	local remove_broken = redraw.register_repaint("broken", function()
		error("broken painter")
	end)
	redraw.register_repaint("healthy", function(selected)
		assert(selected == "low-bandwidth")
		healthy_calls = healthy_calls + 1
	end)
	redraw.setup({
		ui_count = function()
			return uis
		end,
		schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end,
	})

	local original_cmd = vim.cmd
	vim.cmd = function(command)
		assert(command == "redraw!")
		redraw_calls = redraw_calls + 1
	end
	uis = 0
	event("UILeave")
	uis = 1
	event("UIEnter")
	scheduled[1]()
	vim.cmd = original_cmd
	local failed = redraw.status()
	assert(healthy_calls == 1 and redraw_calls == 1, "one failing painter suppressed another repaint stage")
	assert(failed.detached and failed.last_error:find("repaint hook broken failed", 1, true))

	remove_broken()
	assert(redraw.retry())
	scheduled[2]()
	assert(healthy_calls == 2 and not redraw.status().detached)
end)

redraw._reset_for_tests()
package.loaded["config.redraw_profile"] = nil
package.loaded["config.local_config"] = original_local_config

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("redraw_profile_lifecycle_spec: %d tests passed", count))
vim.cmd("quitall!")
