local MiniTest = require("mini.test")
local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })
vim.o.shadafile = "NONE"
vim.o.swapfile = false
local config = vim.fn.getcwd()
vim.opt.runtimepath:prepend(config .. "/local-plugins/devcontainer-editor.nvim")
package.path = config .. "/local-plugins/_shared/lua/?.lua;" .. package.path
local core = require("devcontainer_editor")
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/repo/sub", "p")
vim.fn.writefile({ "hello" }, fixture .. "/repo/sub/file.txt")
local root = assert(vim.uv.fs_realpath(fixture .. "/repo"))
local launcher = config .. "/scripts/devcontainer-editor"
local saved_jobstart = vim.fn.jobstart
local saved_environment = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
}

local function configure(overrides)
	return core.setup(vim.tbl_extend("force", {
		launcher = launcher,
		state_root = fixture .. "/state",
		watch = false,
		resolve_cli = function()
			return vim.fn.exepath("nvim")
		end,
		docker_path = vim.fn.exepath("nvim"),
	}, overrides or {}))
end

local function helper(lines)
	local path = fixture .. "/bridge.py"
	vim.fn.writefile(lines, path)
	return path
end

hooks.pre_case = function()
	vim.env.NVIM_DEVCONTAINER = nil
end
hooks.post_case = function()
	vim.fn.jobstart = saved_jobstart
	core.teardown()
	for name, value in pairs(saved_environment) do
		vim.env[name] = value
	end
end
hooks.post_once = function()
	vim.fn.delete(fixture, "rf")
end

T["setup and health remain process-free and return caller-owned snapshots"] = function()
	vim.fn.jobstart = function()
		error("health started a helper")
	end
	local defaults = core.effective_config()
	assert(defaults.ack_timeout_ms == 5000 and defaults.max_messages_per_tick == 32)
	configure()
	local status = core.status()
	assert(status.configured and not status.bridge.active and not status.watcher.active)
	status.transport.state = "changed"
	defaults.docker_path = "changed"
	assert(core.status().transport.state == "idle")
	assert(core.effective_config().docker_path ~= "changed")
end

T["one real helper serves routing, UUID, and runtime requests"] = function()
	local starts = 0
	vim.fn.jobstart = function(...)
		starts = starts + 1
		return saved_jobstart(...)
	end
	configure()
	assert(core.route("sub/file.txt", root, "/workspaces/repo", "file") == "/workspaces/repo/sub/file.txt")
	assert(core.new_claim_id():match("^[a-f0-9-]+$"))
	local runtime = assert(core.resolve_runtime())
	assert(runtime.cli_path == vim.uv.fs_realpath(vim.fn.exepath("nvim")))
	assert(starts == 1 and core.status().bridge.active)
	core.stop()
	assert(not core.status().bridge.active)
end

T["routing rejects a symlink escape and invalid destination"] = function()
	configure()
	local outside = fixture .. "/outside.txt"
	vim.fn.writefile({ "outside" }, outside)
	assert(vim.uv.fs_symlink(outside, root .. "/escape"))
	local value, err = core.route("escape", root, "/workspace", "file")
	assert(value == nil and err:find("outside", 1, true))
	assert(core.route("sub/file.txt", root, "/workspace/../escape", "file") == nil)
	assert(core.route("sub/file.txt", root, "/workspace", "directory") == nil)
end

T["workspace identities remain lexical and caller-owned"] = function()
	local key = { runtime = "container", root = "/workspace", repo_identity = "/host/repo" }
	local normalized = assert(core.workspace_key(key))
	normalized.root = "/changed"
	assert(key.root == "/workspace")
	assert(core.workspace_key({ runtime = "container", root = "/workspace/../other", repo_identity = "/host" }) == nil)
end

T["lifecycle argv carries explicit pane, claim, policy and runtime"] = function()
	configure()
	local id = assert(core.new_claim_id())
	local argv = assert(core.lifecycle_argv("up", {
		root = root,
		tmux_pane = "%7",
		claim_id = id,
		allow_network = true,
		recreate = true,
	}))
	assert(argv[1] == launcher and argv[2] == "up")
	assert(vim.tbl_contains(argv, "--docker-path") and vim.tbl_contains(argv, "--allow-network"))
	assert(vim.tbl_contains(argv, "--recreate") and vim.tbl_contains(argv, id))
	assert(core.lifecycle_argv("up", { root = root }) == nil)
	assert(core.lifecycle_argv("exec", {}) == nil)
	local restart = assert(core.lifecycle_argv("restart-dead", { root = root, tmux_pane = "%7", claim_id = id }))
	assert(not vim.tbl_contains(restart, "--cli-path"))
end

T["setup rejects invalid policy without changing an active configuration"] = function()
	configure()
	local before = core.effective_config()
	for _, invalid in ipairs({ { extra = true }, { ack_timeout_ms = 0 }, { watch = "yes" }, { ssh_agent = "on" } }) do
		assert(not pcall(core.setup, invalid))
		assert(vim.deep_equal(core.effective_config(), before))
	end
end

T["positive public settings above transport capacity stay usable"] = function()
	configure({ ack_timeout_ms = 600001, max_messages_per_tick = 1000000 })
	assert(core.new_claim_id())
	assert(core.effective_config().max_messages_per_tick == 1000000)
end

T["resolver and path callbacks report failures at the adapter boundary"] = function()
	configure({
		resolve_cli = function()
			error("resolver failed")
		end,
	})
	local value, err = core.resolve_runtime()
	assert(value == nil and err:find("resolver failed", 1, true))
	configure({
		state_root = function()
			error("state callback failed")
		end,
	})
	value, err = core.new_claim_id()
	assert(value == nil and err:find("state callback failed", 1, true))
end

T["fragmented subprocess stdout is framed and correlated"] = function()
	configure({
		launcher = helper({
			"import json, os, sys, time",
			"for line in sys.stdin:",
			"    request = json.loads(line)",
			"    payload = json.dumps({'id': request['id'], 'result': 'fragmented'}).encode() + b'\\n'",
			"    for part in (payload[:5], payload[5:12], payload[12:]):",
			"        os.write(1, part)",
			"        time.sleep(0.01)",
		}),
	})
	assert(core.new_claim_id() == "fragmented")
end

T["helper EOF fails pending calls and never silently restarts"] = function()
	local starts = 0
	vim.fn.jobstart = function(...)
		starts = starts + 1
		return saved_jobstart(...)
	end
	configure({ launcher = helper({ "import sys", "sys.stdin.readline()", "sys.exit(7)" }) })
	local value, err = core.new_claim_id()
	assert(value == nil and err:find("exited (7)", 1, true))
	assert(core.new_claim_id() == nil and starts == 1)
	assert(not core.status().bridge.active)
	assert(core.consume_spool_once() == nil and starts == 1, "poll restarted a dead helper")
	helper({
		"import json, sys",
		"for line in sys.stdin:",
		"    request = json.loads(line)",
		"    print(json.dumps({'id':request['id'],'result':'recovered'}),flush=True)",
	})
	core.reconnect()
	assert(core.new_claim_id() == "recovered" and starts == 2)
end

T["a stalled helper fails within the configured timeout without replay"] = function()
	configure({ ack_timeout_ms = 200, launcher = helper({ "import sys", "sys.stdin.buffer.read()" }) })
	local started = vim.uv.hrtime()
	local value, err = core.new_claim_id()
	assert(value == nil and err:find("timed out", 1, true))
	assert((vim.uv.hrtime() - started) / 1e6 < 2000)
	assert(core.new_claim_id() == nil)
end

T["invalid and oversized helper frames fail closed"] = function()
	for _, payload in ipairs({ "b'{not-json}\\n'", "b'x' * 65536", 'b\'{"id":999,"result":true}\\n\'' }) do
		configure({
			launcher = helper({
				"import os, sys",
				"sys.stdin.readline()",
				"os.write(1, " .. payload .. ")",
				"sys.stdin.buffer.read()",
			}),
		})
		local value, err = core.new_claim_id()
		assert(value == nil and type(err) == "string")
		assert(not core.status().bridge.active)
	end
end

T["a host callback failure cannot discard the next response in the same chunk"] = function()
	local notifications = {}
	configure({
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		launcher = helper({
			"import json, os, sys",
			"for line in sys.stdin:",
			"    request = json.loads(line)",
			"    event = {'id':request['id'],'event':'host_result','result':{'ok':True}}",
			"    reply = {'id':request['id'],'result':'00000000-0000-4000-8000-000000000001'}",
			"    os.write(1,(json.dumps(event)+'\\n'+json.dumps(reply)+'\\n').encode())",
		}),
	})
	local queued, id = core.request_host("editor_ready", function()
		error("callback exploded")
	end)
	assert(queued and id == "00000000-0000-4000-8000-000000000001")
	assert(#notifications == 1 and notifications[1]:find("callback exploded", 1, true))
	assert(core.status().bridge.active)
end

T["optional UUID providers remain Python-validated for claims and host requests"] = function()
	local id = "00000000-0000-4000-8000-000000000001"
	configure({
		uuid = function()
			return id
		end,
	})
	assert(core.new_claim_id() == id)
	id = "invalid"
	local value, err = core.new_claim_id()
	assert(value == nil and err:find("claim id", 1, true))
	configure({
		uuid = function()
			error("UUID provider failed")
		end,
	})
	value, err = core.new_claim_id()
	assert(value == nil and err:find("UUID provider failed", 1, true))
end

T["offline authorization is a cached environment decision"] = function()
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	assert(not core.network_authorized())
	vim.env.NVIM_CONFIG_OFFLINE = nil
	assert(core.network_authorized())
end

return T
