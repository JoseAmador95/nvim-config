vim.o.shadafile = "NONE"
vim.o.swapfile = false

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
vim.opt.runtimepath:prepend(plugin_root)

local theme_router = require("theme_router")
local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
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

local function write(path, lines)
	assert(vim.fn.writefile(lines, path) == 0, "could not write " .. path)
end

local function callbacks(overrides)
	overrides = overrides or {}
	return {
		notifications = {},
		events = {},
		notify = overrides.notify,
		event = overrides.event,
		paint = overrides.paint,
		context = overrides.context,
	}
end

local function setup(path, observed, extra)
	extra = extra or {}
	observed.notify = observed.notify
		or function(message, level)
			observed.notifications[#observed.notifications + 1] = { message = tostring(message), level = level }
		end
	observed.event = observed.event or function(event)
		observed.events[#observed.events + 1] = event
	end
	observed.paint = observed.paint or function()
		return true
	end
	local selection, err = theme_router.setup({
		state_path = path,
		legacy_path = extra.legacy_path,
		default = extra.default or "vscode",
		fallback = extra.fallback or "habamax",
		notify = observed.notify,
		event = observed.event,
		paint = observed.paint,
		context = observed.context,
	})
	assert(selection, err)
	return selection
end

local function has_message(observed, needle)
	for _, item in ipairs(observed.notifications) do
		if item.message:find(needle, 1, true) then
			return true
		end
	end
	return false
end

test("manual YAML accepts comments and returns independent selections", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 493) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	write(path, {
		"# edited by hand",
		"",
		"version: 1 # current schema",
		"colorscheme: 'catppuccin-mocha' # preferred theme",
	})
	local observed = callbacks()
	local selection = setup(path, observed)
	equal("catppuccin-mocha", selection.colorscheme, "manual YAML selection was not loaded")
	equal("local", selection.source, "manual YAML source is incorrect")
	equal(true, selection.validity.valid, "manual YAML was marked invalid")
	selection.colorscheme = "mutated"
	selection.validity.valid = false
	local independent = theme_router.selection()
	equal("catppuccin-mocha", independent.colorscheme, "selection shares colorscheme state")
	equal(true, independent.validity.valid, "selection shares validity state")
	equal("rwx------", vim.fn.getfperm(state_dir), "state directory was not repaired to 0700")
	equal("rw-------", vim.fn.getfperm(path), "state file was not repaired to 0600")
	vim.fn.delete(root, "rf")
end)

test("strict YAML rejects malformed, duplicate, unknown, missing, and future data", function()
	local fixtures = {
		{ name = "malformed scalar", lines = { "version: 1", "colorscheme: [vscode]" }, error = "malformed" },
		{
			name = "duplicate key",
			lines = { "version: 1", "colorscheme: vscode", "colorscheme: habamax" },
			error = "duplicate",
		},
		{ name = "unknown key", lines = { "version: 1", "colorscheme: vscode", "theme: dark" }, error = "unknown" },
		{ name = "future version", lines = { "version: 2", "colorscheme: vscode" }, error = "Unsupported" },
		{ name = "missing version", lines = { "colorscheme: vscode" }, error = "missing" },
		{ name = "nested key", lines = { "version: 1", " colorscheme: vscode" }, error = "top-level" },
	}
	for _, fixture in ipairs(fixtures) do
		local root = temp_dir()
		local state_dir = vim.fs.joinpath(root, "state")
		assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
		local path = vim.fs.joinpath(state_dir, "theme.yaml")
		write(path, fixture.lines)
		local observed = callbacks()
		local selection = setup(path, observed)
		equal("vscode", selection.colorscheme, fixture.name .. " did not fall back to default")
		equal("default", selection.source, fixture.name .. " reported the wrong source")
		equal(false, selection.validity.valid, fixture.name .. " was marked valid")
		assert(has_message(observed, fixture.error), fixture.name .. " did not report its parse error")
		vim.fn.delete(root, "rf")
	end
end)

test("persist and reset use atomic owner-only YAML", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "nvim")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local painted = {}
	local observed = callbacks({
		paint = function(name)
			painted[#painted + 1] = name
			return true
		end,
	})
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "persist failed")
	equal("catppuccin", theme_router.selection().colorscheme, "persist did not update selection")
	equal("rwx------", vim.fn.getfperm(state_dir), "persisted state directory is not 0700")
	equal("rw-------", vim.fn.getfperm(path), "persisted YAML is not 0600")
	local contents = table.concat(vim.fn.readfile(path), "\n")
	assert(contents:find("version: 1", 1, true), "persisted YAML omitted version")
	assert(contents:find('colorscheme: "catppuccin"', 1, true), "persisted YAML omitted selection")

	assert(theme_router.reset(), "reset failed")
	equal("vscode", theme_router.selection().colorscheme, "reset did not restore default")
	equal("vscode", painted[#painted], "reset did not repaint default")
	contents = table.concat(vim.fn.readfile(path), "\n")
	assert(contents:find('colorscheme: "vscode"', 1, true), "reset did not persist the default")
	vim.fn.delete(root, "rf")
end)

test("write failures and symlink targets preserve the current selection", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(vim.fn.mkdir(path, "p", 448) == 1)
	assert(not theme_router.persist("catppuccin"), "directory target accepted a write")
	equal("vscode", theme_router.selection().colorscheme, "failed write changed selection")
	assert(has_message(observed, "regular file"), "non-regular write failure was not reported")

	vim.fn.delete(path, "d")
	local outside = vim.fs.joinpath(root, "outside.yaml")
	write(outside, { "outside" })
	assert(vim.uv.fs_symlink(outside, path))
	observed = callbacks()
	local selection = setup(path, observed)
	equal("vscode", selection.colorscheme, "symlink state changed selection")
	equal(false, selection.validity.valid, "symlink state was marked valid")
	assert(not theme_router.persist("catppuccin"), "symlink target accepted a write")
	equal("outside", vim.fn.readfile(outside)[1], "symlink target was overwritten")
	equal("vscode", theme_router.selection().colorscheme, "symlink write changed selection")
	vim.fn.delete(root, "rf")
end)

test("only the exact generated legacy Lua is migrated and retained", function()
	local root = temp_dir()
	local state_path = vim.fs.joinpath(root, "nvim", "theme.yaml")
	local legacy = vim.fs.joinpath(root, "legacy.lua")
	local legacy_lines = {
		"-- lua/localconfig/theme.lua -- machine-local theme selection.",
		"-- Written by :Theme. NOT under version control; see .gitignore.",
		"-- The versioned starting point lives in lua/config/theme_default.lua,",
		"-- and :ThemeReset deletes this file to come back to it.",
		"",
		"return {",
		'\tcolorscheme = "catppuccin",',
		"}",
	}
	write(legacy, legacy_lines)
	local observed = callbacks()
	local selection = setup(state_path, observed, { legacy_path = legacy })
	equal("catppuccin", selection.colorscheme, "exact legacy selection was not migrated")
	equal(true, selection.validity.migrated, "migration was not reported")
	assert(vim.fn.filereadable(state_path) == 1, "migration did not write YAML")
	equal(legacy_lines, vim.fn.readfile(legacy), "migration modified the legacy recovery file")

	local malformed_root = temp_dir()
	local malformed = vim.fs.joinpath(malformed_root, "legacy.lua")
	write(malformed, {
		"vim.g.theme_router_legacy_executed = true",
		"return { colorscheme = 'catppuccin' }",
	})
	vim.g.theme_router_legacy_executed = nil
	observed = callbacks()
	selection = setup(vim.fs.joinpath(malformed_root, "nvim", "theme.yaml"), observed, { legacy_path = malformed })
	equal("vscode", selection.colorscheme, "unrecognized legacy text was accepted")
	assert(vim.g.theme_router_legacy_executed == nil, "legacy Lua was executed")
	assert(has_message(observed, "did not match"), "unrecognized legacy text was not reported")
	assert(vim.fn.filereadable(vim.fs.joinpath(malformed_root, "nvim", "theme.yaml")) == 0)

	vim.fn.delete(root, "rf")
	vim.fn.delete(malformed_root, "rf")
end)

test("painter failures fall back and emit caller-owned events", function()
	local root = temp_dir()
	local painted = {}
	local events = {}
	local context = { background = "dark" }
	local observed = callbacks({
		paint = function(name, received)
			painted[#painted + 1] = name
			received.background = "mutated"
			if name == "missing" then
				return false, "not installed"
			end
			return true
		end,
		context = function()
			return context
		end,
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.kind = "mutated"
		end,
	})
	setup(vim.fs.joinpath(root, "state", "theme.yaml"), observed, { default = "missing", fallback = "habamax" })
	local ok, applied = theme_router.repaint()
	assert(ok, "fallback repaint failed")
	equal("habamax", applied, "fallback repaint chose the wrong theme")
	equal({ "missing", "habamax" }, painted, "fallback painter order is incorrect")
	equal("dark", context.background, "painter received shared context")
	assert(has_message(observed, "not installed"), "painter rejection was not reported")
	assert(events[#events].kind == "fallback", "fallback event was not emitted")

	assert(theme_router.register("broken", function()
		error("exploded")
	end))
	assert(not theme_router.apply("broken"), "throwing registered painter succeeded")
	assert(has_message(observed, "exploded"), "registered painter error was not reported")
	assert(theme_router.register("custom", function(name, received)
		equal("custom", name, "registered painter received wrong name")
		equal("dark", received.background, "registered painter received wrong context")
		painted[#painted + 1] = name
	end))
	assert(theme_router.apply("custom"), "registered painter did not apply")
	assert(events[#events].kind == "applied", "apply event was not emitted")
	vim.fn.delete(root, "rf")
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("theme_router plugin spec: %d tests passed"):format(count))
