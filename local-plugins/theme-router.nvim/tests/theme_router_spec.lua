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

local function read_bytes(path)
	local stat = assert(vim.uv.fs_stat(path))
	local fd = assert(vim.uv.fs_open(path, "r", 0))
	local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return contents
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
		on_state_change = extra.on_state_change,
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

local function legacy_lines(name)
	return {
		"-- lua/localconfig/theme.lua -- machine-local theme selection.",
		"-- Written by :Theme. NOT under version control; see .gitignore.",
		"-- The versioned starting point lives in lua/config/theme_default.lua,",
		"-- and :ThemeReset deletes this file to come back to it.",
		"",
		"return {",
		('\tcolorscheme = "%s",'):format(name),
		"}",
	}
end

local function same_object(left, right)
	return left and right and left.type == right.type and left.dev == right.dev and left.ino == right.ino
end

local function with_uv_override(name, replacement, callback)
	local original = assert(vim.uv[name], "missing uv function " .. name)
	vim.uv[name] = function(...)
		return replacement(original, ...)
	end
	local result = { xpcall(callback, debug.traceback) }
	vim.uv[name] = original
	if not result[1] then
		error(result[2])
	end
	return unpack(result, 2)
end

local function make_fifo(path)
	local result = vim.system({ "mkfifo", path }, { text = true }):wait()
	assert(result.code == 0, "could not create FIFO: " .. tostring(result.stderr))
end

if vim.env.THEME_ROUTER_EXCHANGE_CRASH_CHILD == "1" then
	local path = assert(vim.env.THEME_ROUTER_EXCHANGE_CRASH_PATH)
	local ready = assert(vim.env.THEME_ROUTER_EXCHANGE_CRASH_READY)
	setup(path, callbacks())
	theme_router._set_test_hook(function(phase)
		if phase ~= "after_exchange" then
			return
		end
		assert(vim.fn.writefile({ "ready" }, ready) == 0)
		vim.wait(60000, function()
			return false
		end, 10)
		error("exchange crash child was not killed")
	end)
	theme_router.persist("tokyonight")
	error("exchange crash child unexpectedly completed")
end

if vim.env.THEME_ROUTER_LOCK_CHILD == "1" then
	local path = assert(vim.env.THEME_ROUTER_LOCK_PATH)
	local ready = assert(vim.env.THEME_ROUTER_LOCK_READY)
	theme_router._set_test_hook(function(phase)
		if phase ~= "lock_acquired" then
			return
		end
		assert(vim.fn.writefile({ "ready" }, ready) == 0)
		vim.wait(60000, function()
			return false
		end, 10)
		error("theme namespace lock child was not killed")
	end)
	setup(path, callbacks())
	error("theme namespace lock child unexpectedly completed")
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

test("persist and reset use owner-only state and a migration tombstone", function()
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
	assert(vim.fn.filereadable(path) == 0, "reset persisted the default instead of removing YAML")
	local marker = vim.fs.joinpath(state_dir, ".legacy-migrated")
	equal({ "version: 1" }, vim.fn.readfile(marker), "reset wrote an invalid migration marker")
	equal("rw-------", vim.fn.getfperm(marker), "migration marker is not 0600")
	local legacy = vim.fs.joinpath(root, "legacy.lua")
	write(legacy, legacy_lines("catppuccin"))
	local reloaded = setup(path, callbacks(), { legacy_path = legacy, default = "habamax" })
	equal("habamax", reloaded.colorscheme, "reset marker did not use the new default on the next setup")
	equal("default", reloaded.source, "reset marker reported the wrong source")
	assert(vim.fn.filereadable(path) == 0, "reset marker allowed legacy YAML remigration")
	vim.fn.delete(root, "rf")
end)

test("persistent namespace lock serializes processes with bounded contention", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local ready = vim.fs.joinpath(root, "lock.ready")
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			THEME_ROUTER_LOCK_CHILD = "1",
			THEME_ROUTER_LOCK_PATH = path,
			THEME_ROUTER_LOCK_READY = ready,
		},
		text = true,
	})
	local reached = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not reached then
		child:kill(9)
		local failed = child:wait(5000)
		error("child did not acquire the theme namespace lock: " .. tostring(failed.stderr))
	end

	local observed = callbacks()
	local started = vim.uv.hrtime()
	local selection = setup(path, observed)
	local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
	equal(false, selection.validity.valid, "contended setup was marked valid")
	assert(has_message(observed, "locked by another process"), "bounded lock contention was not reported")
	assert(elapsed_ms >= 200 and elapsed_ms < 2000, "lock acquisition was not bounded: " .. tostring(elapsed_ms))
	local lock_path = vim.fs.joinpath(state_dir, ".theme-router.lock")
	local lock_stat = assert(vim.uv.fs_lstat(lock_path))
	equal("file", lock_stat.type, "theme namespace lock is not a regular file")
	equal(1, lock_stat.nlink, "theme namespace lock is hard-linked")
	equal("rw-------", vim.fn.getfperm(lock_path), "theme namespace lock is not 0600")

	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "theme namespace lock child was not killed")
	selection = setup(path, callbacks())
	equal(true, selection.validity.valid, "released namespace lock did not permit setup")
	assert(theme_router.persist("catppuccin"), "released namespace lock did not permit persistence")
	assert(vim.uv.fs_lstat(lock_path), "theme namespace lock was unlinked after release")
	vim.fn.delete(root, "rf")
end)

test("namespace lock rejects symlinks and hardlinks without touching peers", function()
	for _, kind in ipairs({ "symlink", "hardlink" }) do
		local root = temp_dir()
		local state_dir = vim.fs.joinpath(root, "state")
		assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
		local path = vim.fs.joinpath(state_dir, "theme.yaml")
		local lock_path = vim.fs.joinpath(state_dir, ".theme-router.lock")
		local peer = vim.fs.joinpath(root, kind .. ".peer")
		write(peer, { "peer" })
		assert(vim.uv.fs_chmod(peer, 384))
		if kind == "symlink" then
			assert(vim.uv.fs_symlink(peer, lock_path))
		else
			assert(vim.uv.fs_link(peer, lock_path))
		end
		local before = assert(vim.uv.fs_lstat(peer))
		local observed = callbacks()
		local selection = setup(path, observed)
		equal(false, selection.validity.valid, kind .. " lock was accepted")
		assert(has_message(observed, "namespace lock"), kind .. " lock rejection was not reported")
		equal({ "peer" }, vim.fn.readfile(peer), kind .. " lock changed peer contents")
		local after = assert(vim.uv.fs_lstat(peer))
		equal(before.mode, after.mode, kind .. " lock changed peer permissions")
		assert(vim.uv.fs_lstat(path) == nil, kind .. " lock allowed theme publication")
		vim.fn.delete(root, "rf")
	end
end)

test("namespace lock close failure is a postcommit persistence warning", function()
	local root = temp_dir()
	local path = vim.fs.joinpath(root, "state", "theme.yaml")
	local observed = callbacks()
	setup(path, observed)
	local lock_fd
	theme_router._set_test_hook(function(phase, details)
		if phase == "lock_acquired" then
			lock_fd = details.fd
		end
	end)
	local persisted, warning = with_uv_override("fs_close", function(original, fd)
		if fd == lock_fd then
			local closed, close_err = original(fd)
			assert(closed, close_err)
			return nil, "simulated namespace lock close failure"
		end
		return original(fd)
	end, function()
		return theme_router.persist("catppuccin")
	end)
	theme_router._set_test_hook(nil)
	assert(persisted, "lock close warning turned a committed persist into failure")
	assert(tostring(warning):find("lock close failure", 1, true), "lock close warning was not returned")
	equal("catppuccin", theme_router.selection().colorscheme, "lock close warning did not advance selection")
	assert(read_bytes(path):find("catppuccin", 1, true), "lock close warning lost committed theme")
	assert(has_message(observed, "durability warning"), "lock close warning was not notified")
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

test("pre-commit file fsync failures do not publish or advance the selection", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local observed = callbacks()
	setup(path, observed)
	local failed = false
	local persisted = with_uv_override("fs_fsync", function(original, fd)
		local info = vim.uv.fs_fstat(fd)
		if not failed and info and info.type == "file" then
			failed = true
			return nil, "simulated file fsync failure"
		end
		return original(fd)
	end, function()
		return theme_router.persist("catppuccin")
	end)
	assert(failed and not persisted, "a failed pre-commit file fsync published the theme")
	assert(vim.uv.fs_lstat(path) == nil, "failed pre-commit fsync left a visible theme")
	equal("vscode", theme_router.selection().colorscheme, "failed pre-commit fsync advanced memory")
	assert(has_message(observed, "Could not flush temporary theme state"), "file fsync failure was not reported")
	vim.fn.delete(root, "rf")
end)

test("only the exact generated legacy Lua is migrated and retained", function()
	local root = temp_dir()
	local state_path = vim.fs.joinpath(root, "nvim", "theme.yaml")
	local legacy = vim.fs.joinpath(root, "legacy.lua")
	local generated = legacy_lines("catppuccin")
	write(legacy, generated)
	local observed = callbacks()
	local selection = setup(state_path, observed, { legacy_path = legacy })
	equal("catppuccin", selection.colorscheme, "exact legacy selection was not migrated")
	equal(true, selection.validity.migrated, "migration was not reported")
	assert(vim.fn.filereadable(state_path) == 1, "migration did not write YAML")
	equal(generated, vim.fn.readfile(legacy), "migration modified the legacy recovery file")

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

test("migration markers repair permissions and fail closed when invalid", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local marker = vim.fs.joinpath(state_dir, ".legacy-migrated")
	local legacy = vim.fs.joinpath(root, "legacy.lua")
	write(legacy, legacy_lines("catppuccin"))
	write(marker, { "version: 1" })
	assert(vim.uv.fs_chmod(marker, 420))
	local selection = setup(path, callbacks(), { legacy_path = legacy })
	equal("vscode", selection.colorscheme, "valid marker did not suppress legacy migration")
	equal("rw-------", vim.fn.getfperm(marker), "valid marker was not repaired to 0600")
	assert(vim.fn.filereadable(path) == 0, "valid marker created YAML")

	write(marker, { "version: 2" })
	local observed = callbacks()
	selection = setup(path, observed, { legacy_path = legacy })
	equal(false, selection.validity.valid, "invalid marker was accepted")
	assert(has_message(observed, "marker is invalid"), "invalid marker was not reported")
	assert(vim.fn.filereadable(path) == 0, "invalid marker allowed legacy migration")

	vim.fn.delete(marker)
	local outside = vim.fs.joinpath(root, "outside")
	write(outside, { "do not touch" })
	assert(vim.uv.fs_symlink(outside, marker))
	observed = callbacks()
	selection = setup(path, observed, { legacy_path = legacy })
	equal(false, selection.validity.valid, "symlink marker was accepted")
	equal("do not touch", vim.fn.readfile(outside)[1], "symlink marker target was modified")
	assert(vim.fn.filereadable(path) == 0, "symlink marker allowed legacy migration")

	vim.fn.delete(marker)
	assert(vim.fn.mkdir(marker, "p", 448) == 1)
	observed = callbacks()
	selection = setup(path, observed, { legacy_path = legacy })
	equal(false, selection.validity.valid, "non-regular marker was accepted")
	assert(has_message(observed, "regular file"), "non-regular marker was not reported")
	assert(vim.fn.filereadable(path) == 0, "non-regular marker allowed legacy migration")
	vim.fn.delete(root, "rf")
end)

test("reset failures preserve the current selection and YAML", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local marker = vim.fs.joinpath(state_dir, ".legacy-migrated")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "persist failed")
	local before = vim.fn.readfile(path)

	local marker_result = with_uv_override("fs_write", function()
		return nil, "forced marker write failure"
	end, function()
		return theme_router.reset()
	end)
	assert(not marker_result, "reset ignored the marker write failure")
	equal("catppuccin", theme_router.selection().colorscheme, "marker failure changed selection")
	equal(before, vim.fn.readfile(path), "marker failure changed YAML")
	assert(vim.fn.filereadable(marker) == 0, "failed marker write left a marker")

	local yaml_identity = assert(vim.uv.fs_lstat(path))
	local delete_result = with_uv_override("fs_fchmod", function(original, fd, mode)
		local opened = vim.uv.fs_fstat(fd)
		if same_object(yaml_identity, opened) then
			return nil, "forced YAML delete failure"
		end
		return original(fd, mode)
	end, function()
		return theme_router.reset()
	end)
	assert(not delete_result, "reset ignored the YAML delete failure")
	equal("catppuccin", theme_router.selection().colorscheme, "delete failure changed selection")
	equal(before, vim.fn.readfile(path), "delete failure changed YAML")
	equal({ "version: 1" }, vim.fn.readfile(marker), "delete failure corrupted the completed marker")

	local backup_dir = vim.fs.joinpath(root, "state.backup")
	local outside_dir = vim.fs.joinpath(root, "outside")
	assert(vim.fn.mkdir(outside_dir, "p", 448) == 1)
	local swapped = false
	local swap_result = with_uv_override("fs_fchmod", function(original, fd, mode)
		local opened = vim.uv.fs_fstat(fd)
		local result, chmod_err = original(fd, mode)
		if not swapped and same_object(yaml_identity, opened) then
			swapped = true
			assert(vim.uv.fs_rename(state_dir, backup_dir))
			assert(vim.uv.fs_symlink(outside_dir, state_dir))
		end
		return result, chmod_err
	end, function()
		return theme_router.reset()
	end)
	assert(swapped, "reset ancestor-swap hook did not run: " .. vim.inspect(observed.notifications))
	assert(not swap_result, "reset deleted through an ancestor swap")
	assert(vim.fn.filereadable(vim.fs.joinpath(outside_dir, "theme.yaml")) == 0, "reset touched swapped directory")
	assert(vim.uv.fs_unlink(state_dir))
	assert(vim.uv.fs_rename(backup_dir, state_dir))
	equal("catppuccin", theme_router.selection().colorscheme, "delete ancestor swap changed selection")
	equal(before, vim.fn.readfile(path), "delete ancestor swap changed YAML")
	vim.fn.delete(root, "rf")
end)

test("FIFO state and marker targets fail without blocking", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local marker = vim.fs.joinpath(state_dir, ".legacy-migrated")
	setup(path, callbacks())
	make_fifo(path)
	assert(not theme_router.persist("catppuccin"), "FIFO state target accepted a write")
	equal("vscode", theme_router.selection().colorscheme, "FIFO state target changed selection")
	assert(vim.fn.delete(path) == 0)

	assert(theme_router.persist("catppuccin"), "persist before marker FIFO failed")
	local before = vim.fn.readfile(path)
	make_fifo(marker)
	assert(not theme_router.reset(), "FIFO marker target accepted reset")
	equal("catppuccin", theme_router.selection().colorscheme, "FIFO marker changed selection")
	equal(before, vim.fn.readfile(path), "FIFO marker changed YAML")
	vim.fn.delete(root, "rf")
end)

test("hard-linked state is rejected without modifying its peer", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local peer = vim.fs.joinpath(root, "peer.yaml")
	local peer_lines = { "version: 1", 'colorscheme: "habamax"' }
	write(peer, peer_lines)
	assert(vim.uv.fs_chmod(peer, 420))
	assert(vim.uv.fs_link(peer, path))
	local observed = callbacks()
	local selection = setup(path, observed)
	equal(false, selection.validity.valid, "hard-linked theme state was accepted")
	assert(has_message(observed, "single-link"), "hard-linked theme state was not reported")
	assert(not theme_router.persist("catppuccin"), "hard-linked theme state accepted persistence")
	equal(peer_lines, vim.fn.readfile(peer), "theme persistence changed a hardlink peer")
	equal("rw-r--r--", vim.fn.getfperm(peer), "theme inspection changed hardlink peer permissions")
	vim.fn.delete(root, "rf")
end)

test("atomic writes fail closed across ancestor swaps", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local backup_dir = vim.fs.joinpath(root, "state.backup")
	local outside_dir = vim.fs.joinpath(root, "outside")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	assert(vim.fn.mkdir(outside_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	setup(path, callbacks())
	local swapped = false
	local persisted = with_uv_override("fs_write", function(original, fd, contents, offset)
		local written, write_err = original(fd, contents, offset)
		if not swapped then
			swapped = true
			assert(vim.uv.fs_rename(state_dir, backup_dir))
			assert(vim.uv.fs_symlink(outside_dir, state_dir))
		end
		return written, write_err
	end, function()
		return theme_router.persist("catppuccin")
	end)
	assert(not persisted, "atomic write accepted an ancestor swap")
	assert(
		vim.fn.filereadable(vim.fs.joinpath(outside_dir, "theme.yaml")) == 0,
		"atomic write touched swapped directory"
	)
	assert(vim.uv.fs_unlink(state_dir))
	assert(vim.uv.fs_rename(backup_dir, state_dir))
	equal("vscode", theme_router.selection().colorscheme, "failed atomic write changed selection")
	assert(vim.fn.filereadable(path) == 0, "failed atomic write left YAML")
	vim.fn.delete(root, "rf")
end)

test("compare-and-swap persistence preserves a rival created after the target check", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local displaced = vim.fs.joinpath(state_dir, "theme.external-previous.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "initial persist failed")

	local rival = {
		"# external writer won the race",
		"version: 1",
		'colorscheme: "habamax"',
	}
	local raced = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "target_checked" or details.path ~= path or raced then
			return
		end
		raced = true
		assert(vim.uv.fs_rename(path, displaced))
		write(path, rival)
	end)
	local called, persisted = xpcall(function()
		return theme_router.persist("tokyonight")
	end, debug.traceback)
	theme_router._set_test_hook(nil)
	assert(called, persisted)
	assert(raced, "compare-and-swap race hook did not run")
	assert(not persisted, "persist clobbered a target created after validation")
	equal(rival, vim.fn.readfile(path), "persist did not preserve the external rival")
	equal("catppuccin", theme_router.selection().colorscheme, "failed CAS advanced the in-memory selection")
	equal({}, vim.fn.glob(vim.fs.joinpath(state_dir, "*.quarantine.*"), false, true), "CAS left quarantine debris")
	assert(vim.fn.filereadable(displaced) == 1, "race fixture lost the displaced prior state")
	vim.fn.delete(root, "rf")
end)

test("compare-and-swap restores a symlink introduced at the exchange boundary", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local displaced = vim.fs.joinpath(state_dir, "theme.before-symlink.yaml")
	local outside = vim.fs.joinpath(root, "outside.yaml")
	setup(path, callbacks())
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	write(outside, { "outside unchanged" })

	local raced = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "target_checked" or details.path ~= path or raced then
			return
		end
		raced = true
		assert(vim.uv.fs_rename(path, displaced))
		assert(vim.uv.fs_symlink(outside, path))
	end)
	local called, persisted = xpcall(function()
		return theme_router.persist("tokyonight")
	end, debug.traceback)
	theme_router._set_test_hook(nil)
	assert(called, persisted)
	assert(raced and not persisted, "boundary symlink was reported as a committed theme")
	assert(assert(vim.uv.fs_lstat(path)).type == "link", "boundary symlink was not restored")
	equal(outside, vim.uv.fs_readlink(path), "boundary symlink destination changed")
	equal({ "outside unchanged" }, vim.fn.readfile(outside), "boundary symlink was followed")
	equal("catppuccin", theme_router.selection().colorscheme, "failed CAS advanced the in-memory selection")
	assert(vim.fn.filereadable(displaced) == 1, "race fixture lost the displaced prior state")
	vim.fn.delete(root, "rf")
end)

test("staging byte drift is rejected before the visible theme changes", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	setup(path, callbacks())
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local before = read_bytes(path)
	local before_identity = assert(vim.uv.fs_lstat(path))
	local changed = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "stage_ready" or details.path ~= path or changed then
			return
		end
		changed = true
		local stat = assert(vim.uv.fs_stat(details.staging_path))
		local fd = assert(vim.uv.fs_open(details.staging_path, "r+", 384))
		assert(vim.uv.fs_write(fd, string.rep("x", stat.size), 0) == stat.size)
		assert(vim.uv.fs_close(fd))
	end)
	local persisted = theme_router.persist("tokyonight")
	theme_router._set_test_hook(nil)
	assert(changed and not persisted, "same-size staging drift was published")
	equal(before, read_bytes(path), "staging drift changed the visible theme bytes")
	local after_identity = assert(vim.uv.fs_lstat(path))
	assert(same_object(before_identity, after_identity), "staging drift replaced the visible theme inode")
	equal("catppuccin", theme_router.selection().colorscheme, "staging drift advanced the in-memory selection")
	vim.fn.delete(root, "rf")
end)

test("exchange keeps the target visible and crash leaves an exact new theme", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local ready = vim.fs.joinpath(root, "exchange.ready")
	setup(path, callbacks())
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", source }, {
		env = {
			THEME_ROUTER_EXCHANGE_CRASH_CHILD = "1",
			THEME_ROUTER_EXCHANGE_CRASH_PATH = path,
			THEME_ROUTER_EXCHANGE_CRASH_READY = ready,
		},
		text = true,
	})
	local reached = vim.wait(5000, function()
		return vim.uv.fs_lstat(ready) ~= nil
	end, 5)
	if not reached then
		child:kill(9)
		local failed = child:wait(5000)
		error("child did not reach the exchange boundary: " .. tostring(failed.stderr))
	end
	assert(vim.uv.fs_lstat(path), "atomic exchange exposed a missing theme target")
	assert(read_bytes(path):find('colorscheme: "tokyonight"', 1, true), "exchange did not expose exact NEW bytes")
	child:kill(9)
	local killed = child:wait(5000)
	assert(killed.signal == 9, "exchange child was not killed")
	local reloaded = setup(path, callbacks())
	equal("tokyonight", reloaded.colorscheme, "crash after exchange did not leave a readable NEW theme")
	vim.fn.delete(root, "rf")
end)

test("post-commit cleanup preserves a replacement without reporting a false write failure", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local retained_old = vim.fs.joinpath(state_dir, "retained-old.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local replaced = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "before_displaced_cleanup" or details.path == path or replaced then
			return
		end
		replaced = true
		assert(vim.uv.fs_rename(details.reserved_path, retained_old))
		write(details.reserved_path, { "version: 1", 'colorscheme: "habamax"' })
		assert(vim.uv.fs_chmod(details.reserved_path, 384))
	end)
	local persisted = theme_router.persist("tokyonight")
	theme_router._set_test_hook(nil)
	assert(replaced and persisted, "cleanup replacement turned a committed write into failure")
	equal("tokyonight", theme_router.selection().colorscheme, "committed cleanup warning did not advance memory")
	assert(read_bytes(path):find('colorscheme: "tokyonight"', 1, true), "committed NEW theme changed")
	assert(read_bytes(retained_old):find('colorscheme: "catppuccin"', 1, true), "displaced OLD theme was lost")
	assert(has_message(observed, "deferred cleanup"), "deferred cleanup was not reported")
	local preserved_foreign = false
	for name in vim.fs.dir(state_dir) do
		local candidate = vim.fs.joinpath(state_dir, name)
		if name:find(".theme.yaml.tmp.", 1, true) == 1 and read_bytes(candidate):find("habamax", 1, true) then
			preserved_foreign = true
		end
	end
	assert(preserved_foreign, "cleanup deleted the unknown replacement")
	vim.fn.delete(root, "rf")
end)

test("cleanup quarantines a replacement introduced after its final validation", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local retained_old = vim.fs.joinpath(state_dir, "retained-after-validation.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local replaced = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "cleanup_validated_before_quarantine" or details.label ~= "Displaced Theme state" or replaced then
			return
		end
		replaced = true
		assert(vim.uv.fs_rename(details.reserved_path, retained_old))
		write(details.reserved_path, { "version: 1", 'colorscheme: "habamax"' })
		assert(vim.uv.fs_chmod(details.reserved_path, 384))
	end)
	local persisted = theme_router.persist("tokyonight")
	theme_router._set_test_hook(nil)
	assert(replaced and persisted, "post-validation replacement turned a committed persist into failure")
	assert(read_bytes(path):find("tokyonight", 1, true), "post-validation replacement changed NEW theme")
	assert(read_bytes(retained_old):find("catppuccin", 1, true), "post-validation race lost displaced OLD theme")
	local preserved_foreign = false
	for name in vim.fs.dir(state_dir) do
		local candidate = vim.fs.joinpath(state_dir, name)
		if name:find(".theme.yaml.tmp.", 1, true) == 1 and read_bytes(candidate):find("habamax", 1, true) then
			preserved_foreign = true
		end
	end
	assert(preserved_foreign, "cleanup deleted the post-validation replacement")
	assert(has_message(observed, "deferred cleanup"), "post-validation cleanup conflict was not warned")
	vim.fn.delete(root, "rf")
end)

test("directory fsync failures after exchange preserve committed success and recovery", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local injected = false
	theme_router._set_test_hook(function(phase, details)
		if phase == "directory_fsync" and details.operation == "Theme state exchange" and not injected then
			injected = true
			error("simulated directory fsync failure")
		end
	end)
	local persisted, warning = theme_router.persist("tokyonight")
	theme_router._set_test_hook(nil)
	assert(injected and persisted, "post-commit directory fsync failure was reported as a failed write")
	assert(tostring(warning):find("directory fsync hook failed", 1, true), "fsync warning was not returned")
	equal("tokyonight", theme_router.selection().colorscheme, "committed fsync warning did not advance memory")
	assert(read_bytes(path):find("tokyonight", 1, true), "committed theme bytes were lost")
	local recovery
	for name in vim.fs.dir(state_dir) do
		if name:find(".theme.yaml.tmp.", 1, true) == 1 then
			recovery = vim.fs.joinpath(state_dir, name)
			break
		end
	end
	assert(recovery and read_bytes(recovery):find("catppuccin", 1, true), "uncertain exchange lost recovery OLD")
	assert(has_message(observed, "durability warning"), "post-commit fsync warning was not notified")
	local warning_event = false
	for _, event in ipairs(observed.events) do
		warning_event = warning_event or (event.kind == "warning" and event.operation == "persist")
	end
	assert(warning_event, "post-commit fsync warning was not emitted structurally")
	vim.fn.delete(root, "rf")
end)

test("conditional reset preserves a same-path replacement", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local displaced = vim.fs.joinpath(state_dir, "theme-before-delete.yaml")
	setup(path, callbacks())
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local replacement_identity
	local replaced = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "delete_target_checked" or details.path ~= path or replaced then
			return
		end
		replaced = true
		assert(vim.uv.fs_rename(path, displaced))
		write(path, { "version: 1", 'colorscheme: "habamax"' })
		assert(vim.uv.fs_chmod(path, 384))
		replacement_identity = assert(vim.uv.fs_lstat(path))
	end)
	local reset = theme_router.reset()
	theme_router._set_test_hook(nil)
	assert(replaced and not reset, "reset deleted or accepted a same-path replacement")
	local current = assert(vim.uv.fs_lstat(path))
	assert(same_object(replacement_identity, current), "reset changed the replacement inode")
	assert(read_bytes(path):find("habamax", 1, true), "reset changed the replacement bytes")
	equal("catppuccin", theme_router.selection().colorscheme, "failed conditional reset changed selection")
	assert(vim.uv.fs_lstat(displaced), "conditional reset lost the displaced original")
	vim.fn.delete(root, "rf")
end)

test("post-operation drift is reported without claiming rollback", function()
	local root = temp_dir()
	local state_dir = vim.fs.joinpath(root, "state")
	local backup_dir = vim.fs.joinpath(root, "state.backup")
	local outside_dir = vim.fs.joinpath(root, "outside")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	assert(vim.fn.mkdir(outside_dir, "p", 448) == 1)
	local path = vim.fs.joinpath(state_dir, "theme.yaml")
	local observed = callbacks()
	setup(path, observed)
	assert(theme_router.persist("catppuccin"), "initial persist failed")
	local swapped = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "after_exchange" or details.path ~= path or swapped then
			return
		end
		swapped = true
		assert(vim.uv.fs_rename(state_dir, backup_dir))
		assert(vim.uv.fs_symlink(outside_dir, state_dir))
	end)
	local persisted = theme_router.persist("tokyonight")
	theme_router._set_test_hook(nil)
	assert(not persisted, "post-rename ancestor swap was reported as success")
	assert(has_message(observed, "no rollback is claimed"), "post-rename drift semantics were not reported")
	equal("catppuccin", theme_router.selection().colorscheme, "post-rename drift changed in-memory selection")
	assert(vim.fn.filereadable(vim.fs.joinpath(outside_dir, "theme.yaml")) == 0, "post-rename drift touched outside")
	assert(vim.uv.fs_unlink(state_dir))
	assert(vim.uv.fs_rename(backup_dir, state_dir))
	assert(vim.fn.filereadable(path) == 1, "post-rename test incorrectly claimed disk rollback")

	observed = callbacks()
	local loaded = setup(path, observed)
	equal("tokyonight", loaded.colorscheme, "committed YAML was not observable after the parent returned")
	swapped = false
	theme_router._set_test_hook(function(phase, details)
		if phase ~= "before_delete_cleanup" or details.label ~= "Reserved Theme state" or swapped then
			return
		end
		swapped = true
		assert(vim.uv.fs_rename(state_dir, backup_dir))
		assert(vim.uv.fs_symlink(outside_dir, state_dir))
	end)
	local reset = theme_router.reset()
	theme_router._set_test_hook(nil)
	assert(not reset, "post-unlink ancestor swap was reported as success")
	assert(has_message(observed, "conditionally delete"), "post-unlink drift semantics were not reported")
	equal("tokyonight", theme_router.selection().colorscheme, "post-unlink drift changed in-memory selection")
	assert(vim.fn.filereadable(vim.fs.joinpath(outside_dir, "theme.yaml")) == 0, "post-unlink drift touched outside")
	assert(vim.uv.fs_unlink(state_dir))
	assert(vim.uv.fs_rename(backup_dir, state_dir))
	assert(vim.fn.filereadable(path) == 1, "conditional delete did not restore the checked entry")
	vim.fn.delete(root, "rf")
end)

test("bounded reads reject oversize, post-read replacement, and ancestor swaps", function()
	local oversized_root = temp_dir()
	local oversized_dir = vim.fs.joinpath(oversized_root, "state")
	assert(vim.fn.mkdir(oversized_dir, "p", 448) == 1)
	local oversized = vim.fs.joinpath(oversized_dir, "theme.yaml")
	write(oversized, { string.rep("x", 64 * 1024 + 1) })
	local observed = callbacks()
	local selection = setup(oversized, observed)
	equal(false, selection.validity.valid, "oversize YAML was accepted")
	assert(has_message(observed, "64 KiB"), "oversize YAML was not reported")
	vim.fn.delete(oversized_root, "rf")

	local replaced_root = temp_dir()
	local replaced_dir = vim.fs.joinpath(replaced_root, "state")
	assert(vim.fn.mkdir(replaced_dir, "p", 448) == 1)
	local replaced = vim.fs.joinpath(replaced_dir, "theme.yaml")
	write(replaced, { "version: 1", "colorscheme: catppuccin" })
	local replaced_identity = assert(vim.uv.fs_lstat(replaced))
	local swapped = false
	observed = callbacks()
	selection = with_uv_override("fs_read", function(original, fd, size, offset)
		local contents, read_err = original(fd, size, offset)
		if not swapped and same_object(replaced_identity, vim.uv.fs_fstat(fd)) then
			swapped = true
			assert(vim.uv.fs_rename(replaced, replaced .. ".old"))
			write(replaced, { "version: 1", "colorscheme: habamax" })
		end
		return contents, read_err
	end, function()
		return setup(replaced, observed)
	end)
	equal(false, selection.validity.valid, "post-read replacement was accepted")
	assert(has_message(observed, "changed while it was read"), "post-read replacement was not reported")
	vim.fn.delete(replaced_root, "rf")

	local swapped_root = temp_dir()
	local state_dir = vim.fs.joinpath(swapped_root, "state")
	local backup_dir = vim.fs.joinpath(swapped_root, "state.backup")
	local outside_dir = vim.fs.joinpath(swapped_root, "outside")
	assert(vim.fn.mkdir(state_dir, "p", 448) == 1)
	assert(vim.fn.mkdir(outside_dir, "p", 448) == 1)
	local state_path = vim.fs.joinpath(state_dir, "theme.yaml")
	write(state_path, { "version: 1", "colorscheme: catppuccin" })
	write(vim.fs.joinpath(outside_dir, "theme.yaml"), { "version: 1", "colorscheme: habamax" })
	local parent_chmods = 0
	observed = callbacks()
	selection = with_uv_override("fs_fchmod", function(original, fd, mode)
		local opened = vim.uv.fs_fstat(fd)
		local current = vim.uv.fs_lstat(state_dir)
		local result, chmod_err = original(fd, mode)
		if same_object(opened, current) then
			parent_chmods = parent_chmods + 1
			if parent_chmods == 2 then
				assert(vim.uv.fs_rename(state_dir, backup_dir))
				assert(vim.uv.fs_symlink(outside_dir, state_dir))
			end
		end
		return result, chmod_err
	end, function()
		return setup(state_path, observed)
	end)
	equal(false, selection.validity.valid, "ancestor swap was accepted")
	assert(has_message(observed, "directory changed"), "ancestor swap was not reported")
	equal(
		"colorscheme: habamax",
		vim.fn.readfile(vim.fs.joinpath(outside_dir, "theme.yaml"))[2],
		"outside YAML changed"
	)
	assert(vim.uv.fs_unlink(state_dir))
	assert(vim.uv.fs_rename(backup_dir, state_dir))
	vim.fn.delete(swapped_root, "rf")
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
	local reloaded, unchanged_active = theme_router.reload()
	assert(reloaded and unchanged_active == "habamax", "unchanged fallback request did not reload")
	equal({ "missing", "habamax" }, painted, "mutated painter context defeated reload deduplication")

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

test("select and reload distinguish durable selection from active last-known-good", function()
	theme_router.teardown()
	local initial = theme_router.status()
	assert(initial.configured == false and initial.selected == nil and initial.active == nil)
	assert(vim.deep_equal(theme_router.effective_config(), {}))
	local root = temp_dir()
	local path = vim.fs.joinpath(root, "state", "theme.yaml")
	local painted = {}
	local context = { background = "dark" }
	local observed = callbacks({
		paint = function(name)
			painted[#painted + 1] = name
			return true
		end,
		context = function()
			return context
		end,
	})
	setup(path, observed, {
		on_state_change = function(event)
			event.kind = "mutated"
			error("observer failure")
		end,
	})
	assert(theme_router.status().last_known_good == nil, "unpainted selection became last-known-good")
	local selected, select_err = theme_router.select("catppuccin")
	assert(selected, select_err)
	local status = theme_router.status()
	equal("catppuccin", status.selected.colorscheme, "select did not persist the chosen theme")
	equal("catppuccin", status.active.colorscheme, "select did not paint the chosen theme")
	equal("catppuccin", status.last_known_good.colorscheme, "select did not advance last-known-good")
	status.active.colorscheme = "mutated"
	equal("catppuccin", theme_router.status().active.colorscheme, "status shares active state")
	local effective = theme_router.effective_config()
	effective.default = "mutated"
	equal("vscode", theme_router.effective_config().default, "effective config shares state")

	write(path, { "version: 1", "colorscheme: [broken" })
	local reloaded = theme_router.reload()
	assert(not reloaded, "invalid YAML was reloaded")
	status = theme_router.status()
	equal(false, status.validity.valid, "invalid YAML did not update validity")
	equal("catppuccin", status.selected.colorscheme, "invalid YAML replaced the selected theme")
	equal("catppuccin", status.active.colorscheme, "invalid YAML repainted the active theme")
	equal("catppuccin", status.last_known_good.colorscheme, "invalid YAML displaced last-known-good")

	write(path, { "version: 1", "colorscheme: tokyonight" })
	local valid, active = theme_router.reload()
	assert(valid and active == "tokyonight", "valid reload did not repaint the durable selection")
	equal("tokyonight", theme_router.status().active.colorscheme, "valid reload left stale active state")
	equal({ "catppuccin", "tokyonight" }, painted, "reload painted an unexpected sequence")
	valid, active = theme_router.reload()
	assert(valid and active == "tokyonight", "unchanged valid reload failed")
	equal({ "catppuccin", "tokyonight" }, painted, "unchanged valid reload called a painter")
	context.background = "light"
	valid, active = theme_router.reload()
	assert(valid and active == "tokyonight", "context-changing reload failed")
	equal({ "catppuccin", "tokyonight", "tokyonight" }, painted, "changed repaint context did not call the painter")
	assert(theme_router.repaint(), "explicit repaint failed")
	equal({ "catppuccin", "tokyonight", "tokyonight", "tokyonight" }, painted, "explicit repaint was deduplicated")
	local before = theme_router.status()
	local accepted, setup_err = theme_router.setup({ injected = true })
	assert(not accepted and setup_err:find("unknown option: injected", 1, true), "unknown setup option was accepted")
	equal(before, theme_router.status(), "rejected setup mutated router state")
	assert(theme_router.teardown() and theme_router.teardown(), "teardown was not repeatable")
	vim.fn.delete(root, "rf")
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("theme_router plugin spec: %d tests passed"):format(count))
