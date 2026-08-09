vim.o.shadafile = "NONE"
vim.o.swapfile = false

local config_repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(config_repo)
package.path = table.concat({ config_repo .. "/lua/?.lua", config_repo .. "/lua/?/init.lua", package.path }, ";")

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

local function git(arguments)
	local command = { "git" }
	vim.list_extend(command, arguments)
	local result = vim.system(command, { text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout or "")
end

local fixture = vim.fn.tempname()
local state = vim.fn.tempname()
local outside = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
assert(vim.fn.writefile({ "target" }, fixture .. "/target.lua") == 0)
assert(vim.fn.writefile({ "outside" }, outside) == 0)
git({ "-C", fixture, "init", "-q" })
assert(vim.uv.fs_symlink(outside, fixture .. "/escape.lua"))
local root = assert(vim.uv.fs_realpath(fixture))

local rpc = require("config.editor_rpc")
assert(rpc._prepare_state(state))
local instance = {
	root = state,
	instance_id = "12345678-1234-4234-8234-123456789abc",
	socket = state .. "/sockets/editor.sock",
	roots = { [root] = true },
}

local function request(overrides)
	local value = {
		version = 1,
		request_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		instance_id = instance.instance_id,
		repo_root = root,
		path = "target.lua",
		line = 7,
		column = 9,
		created_at = "2026-08-09T12:00:00Z",
	}
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return value
end

local function write_request(value)
	local path = state .. "/requests/" .. value.request_id .. ".json"
	assert(require("config.fs").write_binary_atomic(path, vim.json.encode(value) .. "\n"))
	return path
end

test("state root follows override, XDG, then home modes", function()
	local old_override = vim.env.NVIM_REVIEW_STATE_HOME
	local old_xdg = vim.env.XDG_STATE_HOME
	local old_home = vim.env.HOME
	vim.env.NVIM_REVIEW_STATE_HOME = "/tmp/review-explicit"
	vim.env.XDG_STATE_HOME = "/tmp/review-xdg"
	vim.env.HOME = "/tmp/review-home"
	assert(rpc.state_root() == "/tmp/review-explicit")
	vim.env.NVIM_REVIEW_STATE_HOME = nil
	assert(rpc.state_root() == "/tmp/review-xdg/nvim-review")
	vim.env.XDG_STATE_HOME = nil
	assert(rpc.state_root() == "/tmp/review-home/.local/state/nvim-review")
	vim.env.NVIM_REVIEW_STATE_HOME = old_override
	vim.env.XDG_STATE_HOME = old_xdg
	vim.env.HOME = old_home
end)

test("state directories and atomic registry are owner-only", function()
	local record = assert(rpc.write_registry(instance))
	assert(record.version == 1 and record.instance_id == instance.instance_id)
	assert(vim.deep_equal(record.repo_roots, { root }))
	for _, directory in ipairs({ state, state .. "/editors", state .. "/requests", state .. "/sockets" }) do
		assert(assert(vim.uv.fs_lstat(directory)).mode % 512 == 448, directory .. " is not 0700")
	end
	local path = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == 384, "registry is not 0600")
	local decoded = vim.json.decode(assert(require("config.fs").read_binary(path)))
	for key in pairs(rpc._record_keys) do
		assert(decoded[key] ~= nil or key == "TMUX_PANE", "registry omitted " .. key)
	end
end)

test("opaque UUID request is consumed once and delegates exact tab position", function()
	local value = request()
	local path = write_request(value)
	local opened
	local handled, err = rpc.consume_request(value.request_id, instance, {
		open_file = function(target, options)
			opened = { target, options }
		end,
	})
	assert(handled == 1, err)
	assert(opened[1] == root .. "/target.lua")
	assert(opened[2].lnum == 7 and opened[2].col == 9)
	assert(vim.uv.fs_lstat(path) == nil, "request was not unlinked after consumption")
	assert(rpc.consume_request(value.request_id, instance, { open_file = function() end }) == nil)
end)

test("request schema, identity, and opaque id reject injected fields", function()
	assert(rpc.consume_request('../target")', instance, { open_file = function() end }) == nil)
	local value = request({ action = "execute" })
	local path = write_request(value)
	local handled, err = rpc.consume_request(value.request_id, instance, { open_file = function() end })
	assert(not handled and err:find("unknown key", 1, true))
	assert(vim.uv.fs_lstat(path) == nil)
	value = request({ instance_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" })
	write_request(value)
	handled, err = rpc.consume_request(value.request_id, instance, { open_file = function() end })
	assert(not handled and err:find("identity", 1, true))
end)

test("request containment rejects traversal and symlink escape", function()
	for _, unsafe in ipairs({ "../outside.lua", "/etc/passwd", "escape.lua", "missing.lua" }) do
		local value = request({ path = unsafe })
		write_request(value)
		local handled = rpc.consume_request(value.request_id, instance, { open_file = function() end })
		assert(not handled, "unsafe request path was accepted: " .. unsafe)
	end
end)

test("symlinked state directories are rejected before chmod", function()
	local symlink_root = vim.fn.tempname()
	local target = vim.fn.tempname()
	assert(vim.fn.mkdir(target, "p") == 1)
	assert(vim.uv.fs_symlink(target, symlink_root))
	local ok, err = rpc._prepare_state(symlink_root)
	assert(not ok and err:find("not a real directory", 1, true))
	vim.fn.delete(symlink_root)
	vim.fn.delete(target, "rf")
end)

test("interactive registration is deferred once beyond the startup path", function()
	local callbacks = {}
	local setups = 0
	local deps = {
		ui_count = function()
			return 1
		end,
		schedule = function(callback)
			callbacks[#callbacks + 1] = callback
		end,
		setup = function()
			setups = setups + 1
		end,
	}
	rpc.setup_deferred(deps)
	rpc.setup_deferred(deps)
	assert(#callbacks == 1 and setups == 0, "deferred setup was not coalesced")
	callbacks[1]()
	assert(setups == 1, "deferred setup did not run exactly once")
end)

vim.fn.delete(fixture, "rf")
vim.fn.delete(state, "rf")
vim.fn.delete(outside)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("editor_rpc_spec: %d tests passed", count))
vim.cmd("quitall!")
