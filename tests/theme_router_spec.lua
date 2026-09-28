vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
local failures = {}
local count = 0

local function equal(expected, actual, message)
	if expected ~= actual then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
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

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p", 448) == 1, "could not create temporary directory")
	return path
end

local function profile_path(root, appname)
	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"-i",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"--cmd",
		"set runtimepath^=" .. repo .. "/local-plugins/theme-router.nvim",
		"-c",
		'lua io.write(require("config.theme").state_path())',
		"-c",
		"quitall!",
	}, {
		text = true,
		env = {
			NVIM_APPNAME = appname,
			XDG_STATE_HOME = vim.fs.joinpath(root, "state"),
			XDG_CACHE_HOME = vim.fs.joinpath(root, "cache"),
			XDG_CONFIG_HOME = vim.fs.joinpath(root, "config"),
			NVIM_LOG_FILE = vim.fs.joinpath(root, appname .. ".log"),
		},
	}):wait()
	assert(result.code == 0, result.stderr)
	return result.stdout
end

test("editor and pager resolve one physical canonical nvim state path", function()
	local root = temp_dir()
	local expected = vim.fs.joinpath(root, "state", "nvim", "theme.yaml")
	equal(expected, profile_path(root, "nvim"), "editor resolved the wrong theme state")
	equal(expected, profile_path(root, "nvimpager"), "pager resolved a profile-local theme state")
	vim.fn.delete(root, "rf")
end)

test("host adapter retains commands and UI while legacy Lua is never imported", function()
	local source_path = vim.fs.joinpath(repo, "lua", "config", "theme.lua")
	local contents = table.concat(vim.fn.readfile(source_path), "\n")
	local colorscheme_path = vim.fs.joinpath(repo, "lua", "plugins", "colorscheme.lua")
	local colorscheme_contents = table.concat(vim.fn.readfile(colorscheme_path), "\n")
	assert(contents:find('nvim_create_user_command("Theme"', 1, true), "Theme command left the host adapter")
	assert(contents:find('nvim_create_user_command("ThemeReset"', 1, true), "ThemeReset command left the host adapter")
	assert(contents:find("snacks.picker.colorschemes", 1, true), "theme picker left the host adapter")
	assert(not contents:find('require("localconfig.theme")', 1, true), "host adapter still executes legacy theme Lua")
	assert(
		not colorscheme_contents:find('nvim_create_autocmd("OptionSet"', 1, true),
		"colorscheme plugin retained a second background repaint owner"
	)
end)

test("host coalesces focus and terminal refreshes with reload priority", function()
	local original_defer = vim.defer_fn
	local original_router = package.loaded.theme_router
	local original_local_config = package.loaded["config.local_config"]
	local original_theme = package.loaded["config.theme"]
	local deferred = {}
	local reloads = 0
	local repaints = 0
	local synchronous = { apply = 0, select = 0, reset = 0 }
	vim.defer_fn = function(callback, delay)
		deferred[#deferred + 1] = { callback = callback, delay = delay }
	end
	package.loaded.theme_router = {
		setup = function()
			return { colorscheme = "vscode", source = "default", validity = { valid = true } }
		end,
		reload = function()
			reloads = reloads + 1
			return true, "vscode"
		end,
		repaint = function()
			repaints = repaints + 1
			return true, "vscode"
		end,
		apply = function()
			synchronous.apply = synchronous.apply + 1
			return true, "vscode"
		end,
		select = function()
			synchronous.select = synchronous.select + 1
			return true, "vscode"
		end,
		reset = function()
			synchronous.reset = synchronous.reset + 1
			return true, "vscode"
		end,
		selection = function()
			return { colorscheme = "vscode", source = "default", validity = { valid = true } }
		end,
	}
	package.loaded["config.local_config"] = {
		plugin = function()
			return { reload_on_focus = true }
		end,
	}
	package.loaded["config.theme"] = nil
	local theme = require("config.theme")
	vim.defer_fn = original_defer
	theme.setup()

	local function flush(message)
		assert(#deferred == 1, message .. " did not use one coalescer")
		local pending = table.remove(deferred, 1)
		equal(100, pending.delay, message .. " used the wrong coalescing window")
		pending.callback()
	end

	vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]10;rgb:0000/0000/0000" } })
	equal(0, #deferred, "unrelated terminal response queued a theme repaint")
	vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:0000/0000/0000" } })
	vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgba:0000/0000/0000/ffff" } })
	equal(0, repaints, "OSC response repainted before the coalescing window")
	flush("OSC response")
	equal(1, repaints, "coalesced OSC response did not repaint once")

	vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
	vim.api.nvim_exec_autocmds("FocusGained", {})
	flush("background then focus")
	equal(1, reloads, "focus reload did not outrank a queued repaint")
	equal(1, repaints, "reload priority also ran the queued repaint")

	vim.api.nvim_exec_autocmds("FocusGained", {})
	vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27]11;rgb:ffff/ffff/ffff" } })
	flush("focus then OSC")
	equal(2, reloads, "queued repaint downgraded a focus reload")
	equal(1, repaints, "focus-first batch also repainted")

	vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
	flush("background")
	equal(2, repaints, "background change did not repaint")
	vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
	assert(theme.repaint(), "explicit host repaint failed")
	equal(3, repaints, "explicit repaint was coalesced")
	equal(1, #deferred, "explicit repaint unexpectedly created another timer")
	table.remove(deferred, 1).callback()
	equal(3, repaints, "stale OptionSet timer repainted after an explicit repaint")

	for label, action in pairs({
		apply = function()
			return theme.apply("vscode")
		end,
		select = function()
			return theme.select("vscode")
		end,
		reload = theme.reload,
		reset = theme.reset,
	}) do
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
		equal(1, #deferred, label .. " fixture did not queue a repaint")
		local repaint_count = repaints
		assert(action(), label .. " synchronous operation failed")
		table.remove(deferred, 1).callback()
		equal(repaint_count, repaints, label .. " left a stale repaint alive")
	end
	equal(1, synchronous.apply, "apply fixture did not run")
	equal(1, synchronous.select, "select fixture did not run")
	equal(1, synchronous.reset, "reset fixture did not run")

	pcall(vim.api.nvim_del_augroup_by_name, "NvimConfigThemeReload")
	pcall(vim.api.nvim_del_user_command, "Theme")
	pcall(vim.api.nvim_del_user_command, "ThemeReset")
	package.loaded["config.theme"] = original_theme
	package.loaded.theme_router = original_router
	package.loaded["config.local_config"] = original_local_config
	vim.defer_fn = original_defer
end)

test("registered painters propagate failure before palette repaint", function()
	local original_router = package.loaded.theme_router
	local original_local_config = package.loaded["config.local_config"]
	local original_palette = package.loaded["config.palette"]
	local original_theme = package.loaded["config.theme"]
	local registered = {}
	local palette_calls = 0
	local palette_result = true
	package.loaded.theme_router = {
		setup = function()
			return { colorscheme = "vscode", source = "default", validity = { valid = true } }
		end,
		register = function(name, painter)
			registered[name] = painter
			return true
		end,
	}
	package.loaded["config.local_config"] = {
		plugin = function()
			return { reload_on_focus = false }
		end,
	}
	package.loaded["config.palette"] = {
		apply = function()
			palette_calls = palette_calls + 1
			return palette_result, palette_result and nil or "palette rejected"
		end,
	}
	package.loaded["config.theme"] = nil
	local theme = require("config.theme")
	assert(theme.register("reject", function()
		return false, "painter rejected"
	end))
	local painted, paint_err = registered.reject("reject", { background = "dark" })
	assert(not painted and paint_err == "painter rejected", "painter false/error was not propagated exactly")
	equal(0, palette_calls, "palette ran after a rejected painter")

	assert(theme.register("throw", function()
		error("painter exploded")
	end))
	painted, paint_err = registered.throw("throw", { background = "dark" })
	assert(not painted and paint_err:find("painter exploded", 1, true), "painter exception was not propagated")
	equal(0, palette_calls, "palette ran after a throwing painter")

	assert(theme.register("success", function() end))
	assert(registered.success("success", { background = "light" }))
	equal(1, palette_calls, "palette did not run after a successful painter")
	palette_result = false
	painted, paint_err = registered.success("success", { background = "light" })
	assert(not painted and paint_err == "palette rejected", "palette false/error was not propagated")

	package.loaded["config.theme"] = original_theme
	package.loaded.theme_router = original_router
	package.loaded["config.local_config"] = original_local_config
	package.loaded["config.palette"] = original_palette
end)

test("every host operation invalidates queued refreshes on false returns and exceptions", function()
	local original_defer = vim.defer_fn
	local original_router = package.loaded.theme_router
	local original_local_config = package.loaded["config.local_config"]
	local original_theme = package.loaded["config.theme"]
	local original_notify = vim.notify
	local deferred = {}
	local responses = {}
	local calls = {}
	local notifications = {}
	vim.defer_fn = function(callback, delay)
		deferred[#deferred + 1] = { callback = callback, delay = delay }
	end
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	local function operation(name, value)
		calls[name] = (calls[name] or 0) + 1
		if responses[name] == "false" then
			return false, name .. " rejected"
		end
		if responses[name] == "throw" then
			error(name .. " exploded")
		end
		return true, value
	end
	package.loaded.theme_router = {
		setup = function()
			return { colorscheme = "vscode", source = "default", validity = { valid = true } }
		end,
		apply = function()
			return operation("apply", "vscode")
		end,
		repaint = function()
			return operation("repaint", "vscode")
		end,
		persist = function()
			return operation("persist")
		end,
		select = function()
			return operation("select")
		end,
		reload = function()
			return operation("reload", "vscode")
		end,
		reset = function()
			return operation("reset", "vscode")
		end,
		selection = function()
			return { colorscheme = "vscode", source = "default", validity = { valid = true } }
		end,
	}
	package.loaded["config.local_config"] = {
		plugin = function()
			return { reload_on_focus = false }
		end,
	}
	package.loaded["config.theme"] = nil
	local theme = require("config.theme")
	vim.defer_fn = original_defer
	theme.setup()

	local actions = {
		apply = function()
			return theme.apply("vscode")
		end,
		repaint = theme.repaint,
		persist = function()
			return theme.save("vscode")
		end,
		select = function()
			return theme.select("vscode")
		end,
		reload = theme.reload,
		reset = theme.reset,
	}
	local function queue()
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
		equal(1, #deferred, "background change did not queue exactly one refresh")
		return table.remove(deferred, 1).callback
	end
	for _, mode in ipairs({ "false", "throw" }) do
		for name, action in pairs(actions) do
			local stale = queue()
			responses[name] = mode
			local ok, err = action()
			assert(not ok, name .. " " .. mode .. " result was accepted")
			local expected = name .. (mode == "false" and " rejected" or " exploded")
			assert(tostring(err):find(expected, 1, true), name .. " did not propagate its exact failure")
			responses[name] = nil
			local repaint_before = calls.repaint or 0
			stale()
			equal(repaint_before, calls.repaint or 0, name .. " left a stale refresh after " .. mode)
			local fresh = queue()
			fresh()
			equal(repaint_before + 1, calls.repaint or 0, name .. " left the coalescer wedged after " .. mode)
		end
	end

	responses.repaint = "false"
	queue()()
	assert(
		table.concat(notifications, "\n"):find("Theme refresh failed: repaint rejected", 1, true),
		"scheduled false/error was not notified"
	)
	responses.repaint = "throw"
	queue()()
	assert(
		table.concat(notifications, "\n"):find("Theme refresh failed:", 1, true)
			and table.concat(notifications, "\n"):find("repaint exploded", 1, true),
		"scheduled exception was not notified"
	)

	pcall(vim.api.nvim_del_augroup_by_name, "NvimConfigThemeReload")
	pcall(vim.api.nvim_del_user_command, "Theme")
	pcall(vim.api.nvim_del_user_command, "ThemeReset")
	package.loaded["config.theme"] = original_theme
	package.loaded.theme_router = original_router
	package.loaded["config.local_config"] = original_local_config
	vim.defer_fn = original_defer
	vim.notify = original_notify
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("theme_router host spec: %d tests passed"):format(count))
