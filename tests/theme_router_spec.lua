vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
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
	assert(contents:find('nvim_create_user_command("Theme"', 1, true), "Theme command left the host adapter")
	assert(contents:find('nvim_create_user_command("ThemeReset"', 1, true), "ThemeReset command left the host adapter")
	assert(contents:find("snacks.picker.colorschemes", 1, true), "theme picker left the host adapter")
	assert(not contents:find('require("localconfig.theme")', 1, true), "host adapter still executes legacy theme Lua")
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("theme_router host spec: %d tests passed"):format(count))
