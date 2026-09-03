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

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("theme_router host spec: %d tests passed"):format(count))
