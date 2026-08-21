vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture .. "/sub", "p") == 1)
assert(vim.fn.writefile({ "hello" }, fixture .. "/file.txt") == 0)
assert(vim.fn.writefile({ "nested" }, fixture .. "/sub/nested.txt") == 0)
local root = assert(vim.uv.fs_realpath(fixture))
local old_env = {
	NVIM_DEVPOD = vim.env.NVIM_DEVPOD,
	NVIM_DEVPOD_TOKEN = vim.env.NVIM_DEVPOD_TOKEN,
	NVIM_DEVPOD_CONTAINER_ROOT = vim.env.NVIM_DEVPOD_CONTAINER_ROOT,
	NVIM_DEVPOD_CONTROLLER_SOCKET = vim.env.NVIM_DEVPOD_CONTROLLER_SOCKET,
	TMUX_PANE = vim.env.TMUX_PANE,
}
vim.env.NVIM_DEVPOD = "1"
vim.env.NVIM_DEVPOD_TOKEN = "secret"
vim.env.NVIM_DEVPOD_CONTAINER_ROOT = root
vim.env.NVIM_DEVPOD_CONTROLLER_SOCKET = "/tmp/controller.sock"

local devpod = require("config.devpod")
local function rpc(value)
	local encoded = (
		vim.json.encode(value):gsub(".", function(byte)
			return string.format("%02x", string.byte(byte))
		end)
	)
	return vim.json.decode(devpod.rpc_hex(encoded))
end

test("RPC rejects malformed hex, unknown fields, and wrong tokens", function()
	assert(vim.json.decode(devpod.rpc_hex("xyz")).ok == false)
	assert(rpc({ version = 1, token = "wrong", action = "open_location" }).ok == false)
	local result = rpc({
		version = 1,
		token = "secret",
		action = "open_location",
		path = "file.txt",
		line = 1,
		column = 1,
		execute = true,
	})
	assert(result.ok == false and result.error:find("unknown", 1, true))
end)

test("open-location is contained and uses the shared tab primitive", function()
	local original = package.loaded["config.editor"]
	local opened
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path, position)
			opened = { path = path, position = position }
		end,
	}
	local result = rpc({
		version = 1,
		token = "secret",
		action = "open_location",
		path = "sub/nested.txt",
		line = 4,
		column = 3,
	})
	assert(result.ok and opened.path == root .. "/sub/nested.txt")
	assert(opened.position.lnum == 4 and opened.position.col == 3)
	assert(rpc({
		version = 1,
		token = "secret",
		action = "open_location",
		path = "../escape",
		line = 1,
		column = 1,
	}).ok == false)
	package.loaded["config.editor"] = original
end)

test("exec passes an argv array and contained cwd without a shell", function()
	local original_system = vim.system
	local captured
	vim.system = function(argv, options)
		captured = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
		return {
			wait = function()
				return { code = 7, signal = 0, stdout = "out\0", stderr = "err" }
			end,
		}
	end
	local result = rpc({
		version = 1,
		token = "secret",
		action = "exec",
		argv = { "printf", "%s", "a b;$(false)" },
		cwd = "sub",
	})
	vim.system = original_system
	assert(result.ok and result.code == 7)
	assert(vim.deep_equal(captured.argv, { "printf", "%s", "a b;$(false)" }))
	assert(captured.options.cwd == root .. "/sub" and captured.options.text == false)
	assert(result.stdout_hex == "6f757400" and result.stderr_hex == "657272")
end)

test("host requests use one authenticated JSON line", function()
	local written
	local pipe = {}
	function pipe:connect(path, callback)
		assert(path == "/tmp/controller.sock")
		callback(nil)
	end
	function pipe:write(payload)
		written = payload
	end
	function pipe:read_start(callback)
		callback(nil, '{"ok":true}\n')
	end
	function pipe:read_stop() end
	function pipe:close() end
	assert(devpod.request_host("tuicr", {
		new_pipe = function()
			return pipe
		end,
	}))
	assert(written:sub(-1) == "\n")
	local value = vim.json.decode(written)
	assert(vim.deep_equal(value, { version = 1, token = "secret", action = "tuicr" }))
	assert(devpod.request_host("devpod_log", {
		new_pipe = function()
			return pipe
		end,
	}))
	value = vim.json.decode(written)
	assert(vim.deep_equal(value, { version = 1, token = "secret", action = "devpod_log" }))
	assert(devpod.request_host("execute") == nil)
end)

test("refresh host requests use the exact allowlist and call back only after ACK", function()
	local written = {}
	local callbacks = 0
	local notifications = {}
	local response = '{"ok":true,"action":"ack"}\n'
	local function new_pipe()
		local pipe = {}
		function pipe:connect(path, callback)
			assert(path == "/tmp/controller.sock")
			callback(nil)
		end
		function pipe:write(payload)
			written[#written + 1] = vim.json.decode(payload)
		end
		function pipe:read_start(callback)
			callback(nil, response)
		end
		function pipe:read_stop() end
		function pipe:close() end
		return pipe
	end
	local dependencies = {
		new_pipe = new_pipe,
		schedule = function(callback)
			callback()
		end,
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
	}

	assert(devpod.request_host("tmux_dev_refresh_check", dependencies, function(value)
		assert(value.ok and value.action == "ack")
		callbacks = callbacks + 1
	end))
	assert(devpod.request_host("tmux_dev_refresh", dependencies, function()
		callbacks = callbacks + 1
	end))
	assert(callbacks == 2)
	assert(written[1].action == "tmux_dev_refresh_check" and written[2].action == "tmux_dev_refresh")

	response = '{"ok":false,"error":"preflight failed"}\n'
	assert(devpod.request_host("tmux_dev_refresh_check", dependencies, function()
		callbacks = callbacks + 1
	end))
	assert(callbacks == 2, "rejected request invoked success callback")
	assert(notifications[#notifications]:find("preflight failed", 1, true), "controller error was hidden")
	assert(devpod.request_host("tmux_dev_refresh_extra") == nil, "unexpected refresh action entered allowlist")
end)

test("workspace status is event data and never inferred on the host", function()
	assert(devpod.in_workspace())
	vim.env.NVIM_DEVPOD = nil
	assert(not devpod.in_workspace())
	vim.env.NVIM_DEVPOD = "1"
end)

test("editor replacement validates the exact pane before respawn", function()
	local original_system = vim.system
	local original_repo = package.loaded["config.repo"]
	package.loaded["config.repo"] = {
		current_root = function()
			return root
		end,
	}
	vim.env.NVIM_DEVPOD = nil
	vim.env.TMUX_PANE = "%7"
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		return {
			wait = function()
				return { code = 0, stdout = "agent\t1\n", stderr = "" }
			end,
		}
	end
	local ok, err = devpod._replace_editor(false, false)
	assert(ok == nil and err:find("single%-pane editor window"))
	assert(#calls == 1 and calls[1][2] == "display-message")

	calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		local stdout = argv[2] == "display-message" and "editor\t1\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	assert(devpod._replace_editor(true, true))
	assert(#calls == 3 and calls[2][2] == "set-option" and calls[3][2] == "respawn-pane")
	local command = calls[3][#calls[3]]
	assert(command:find(" --recreate", 1, true) and command:find(" --allow-network", 1, true))
	package.loaded["config.repo"] = original_repo
	vim.system = original_system
	vim.env.NVIM_DEVPOD = "1"
end)

for key, value in pairs(old_env) do
	vim.env[key] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("devpod_spec: %d tests passed", count))
vim.cmd("quitall!")
