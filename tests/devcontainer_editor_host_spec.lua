vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/devcontainer-editor.nvim")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
package.path = table.concat({ repo .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

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
assert(vim.fn.mkdir(fixture .. "/.git", "p") == 1)
local root = assert(vim.uv.fs_realpath(fixture))
local original = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
	TMUX_PANE = vim.env.TMUX_PANE,
}
vim.env.NVIM_DEVCONTAINER = nil
vim.env.TMUX_PANE = "%7"

local old_repo = package.loaded["config.repo"]
local old_local_config = package.loaded["config.local_config"]
package.loaded["config.repo"] = {
	current_root = function()
		return root
	end,
}
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "devcontainer_editor")
		assert(defaults.cli == "devcontainer" and defaults.lockfile_policy == "preserve")
		assert(defaults.ssh_agent == "auto" and defaults.claim_timeout_ms == 2000)
		assert(defaults.ack_timeout_ms == 5000 and defaults.max_messages_per_tick == 32)
		return vim.deepcopy(defaults)
	end,
}

local devcontainer = require("config.devcontainer")
assert(package.loaded.devcontainer_editor == nil, "devcontainer core loaded while registering host commands")

test("host adapter injects plugin callbacks and no config dependency crosses the boundary", function()
	local options = devcontainer._options()
	assert(type(options.state_root) == "function")
	assert(type(options.open) == "function")
	assert(type(options.notify) == "function")
	assert(options.cli == "devcontainer" and options.lockfile_policy == "preserve")
	assert(options.ssh_agent == "auto" and options.claim_timeout_ms == 2000)
	assert(options.ack_timeout_ms == 5000 and options.max_messages_per_tick == 32)
	local plugin_source = table.concat(
		vim.fn.readfile(repo .. "/local-plugins/devcontainer-editor.nvim/lua/devcontainer_editor/init.lua"),
		"\n"
	)
	assert(not plugin_source:find('require%("config%.'))
	assert(not plugin_source:find("nvim_create_user_command", 1, true))
end)

test("editor replacement validates the exact pane before lifecycle start", function()
	local old_system = vim.system
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		return {
			wait = function()
				return { code = 0, stdout = "agent\t1\n", stderr = "" }
			end,
		}
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err:find("single%-pane editor window"))
	assert(#calls == 1 and calls[1][2] == "display-message")
	vim.system = old_system
end)

test("first command reports a core load failure and the next activation retries", function()
	local original_preload = package.preload.devcontainer_editor
	local original_notify = vim.notify
	local notices = {}
	package.preload.devcontainer_editor = function()
		error("injected devcontainer core load failure")
	end
	package.loaded.devcontainer_editor = nil
	vim.notify = function(message, level)
		notices[#notices + 1] = { message = message, level = level }
	end

	local called, command_err = pcall(devcontainer._show_doctor)
	package.preload.devcontainer_editor = original_preload
	package.loaded.devcontainer_editor = nil
	vim.notify = original_notify

	assert(called, "doctor command raised on a deferred core load failure: " .. tostring(command_err))
	assert(
		#notices == 1 and notices[1].message:find("injected devcontainer core load failure", 1, true),
		"doctor command did not report the deferred load failure"
	)
	assert(devcontainer._core(), "devcontainer core did not retry after the load failure")
end)

test("recreate and network authorization are explicit launcher argv", function()
	local old_system = vim.system
	local core = devcontainer._core()
	local old_claim = core.new_claim_id
	local old_status = core.status
	local calls = {}
	core.new_claim_id = function()
		return "00000000-0000-4000-8000-000000000031"
	end
	core.status = function()
		return { claim_id = "00000000-0000-4000-8000-000000000031", status = "starting" }
	end
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		local stdout = argv[2] == "display-message" and "editor\t1\t0\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	assert(devcontainer._replace_editor(true, true))
	assert(#calls == 2 and calls[2][2] == "run-shell" and calls[2][3] == "-b")
	assert(calls[2][4] == "-t" and calls[2][5] == "%7")
	local command = calls[2][#calls[2]]
	assert(command:find("scripts/devcontainer%-editor"))
	assert(command:find("--recreate", 1, true) and command:find("--allow-network", 1, true))
	assert(command:find("--tmux%-pane") and command:find("%%7"))
	assert(command:find("--claim%-id") and command:find("00000000%-0000%-4000%-8000%-000000000031"))
	assert(command:find("--cli", 1, true) and command:find("devcontainer", 1, true))
	assert(command:find("--lockfile%-policy") and command:find("preserve", 1, true))
	assert(command:find("--ssh%-agent") and command:find("auto", 1, true))
	assert(not command:find("NVIM_DEVCONTAINER_TOKEN", 1, true))
	vim.system = old_system
	core.new_claim_id = old_claim
	core.status = old_status
end)

test("detached coordinator launch failure is reported without pane replacement", function()
	local old_system = vim.system
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		local display = argv[2] == "display-message"
		return {
			wait = function()
				return display and { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
					or { code = 1, stdout = "", stderr = "detached start failed" }
			end,
		}
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err == "detached start failed")
	assert(#calls == 2 and calls[2][2] == "run-shell")
	for _, call in ipairs(calls) do
		assert(call[2] ~= "respawn-pane" and call[2] ~= "set-option")
	end
	vim.system = old_system
end)

test("detached launch is not successful before its exact starting claim", function()
	local core = devcontainer._core()
	local old_status = core.status
	local attempts = 0
	core.status = function()
		attempts = attempts + 1
		if attempts == 1 then
			return nil, "workspace record is unavailable"
		end
		return { claim_id = "00000000-0000-4000-8000-000000000041", status = "starting" }
	end
	assert(devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041"))
	assert(attempts == 2)
	core.status = function()
		return { claim_id = "00000000-0000-4000-8000-000000000041", status = "error" }
	end
	local ok, err = devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041")
	assert(ok == nil and err:find("entered error", 1, true))
	local existing = { claim_id = "00000000-0000-4000-8000-000000000042", status = "error" }
	core.status = function()
		return existing
	end
	ok, err = devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041", 1)
	assert(ok == nil and err:find("did not publish", 1, true))
	assert(existing.claim_id == "00000000-0000-4000-8000-000000000042" and existing.status == "error")
	core.status = old_status
end)

test("only final DevContainer commands are registered", function()
	devcontainer.setup()
	for _, name in ipairs({
		"DevContainerUp",
		"DevContainerRecreate",
		"DevContainerStatus",
		"DevContainerLog",
		"DevContainerHostEditor",
		"DevContainerDoctor",
	}) do
		assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
	end
	assert(vim.fn.exists(":HostEditor") == 0, "legacy host command remains")
end)

test("network denial is exactly the verified-tools offline signal", function()
	local previous = vim.env.NVIM_CONFIG_OFFLINE
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	assert(not devcontainer.network_authorized())
	vim.env.NVIM_CONFIG_OFFLINE = "0"
	assert(devcontainer.network_authorized())
	vim.env.NVIM_CONFIG_OFFLINE = previous
end)

test("container startup configures the core once and retries a failed first setup", function()
	local saved_adapter = package.loaded["config.devcontainer"]
	local saved_core = package.loaded.devcontainer_editor
	local previous_container = vim.env.NVIM_DEVCONTAINER
	local calls = 0
	local fake = {}
	function fake.setup()
		calls = calls + 1
		if calls == 1 then
			error("fixture setup failure")
		end
		return fake
	end
	package.loaded.devcontainer_editor = fake
	package.loaded["config.devcontainer"] = nil
	vim.env.NVIM_DEVCONTAINER = "1"
	local isolated = require("config.devcontainer")
	local ok = pcall(isolated.setup)
	assert(not ok and calls == 1, "failed container setup was not surfaced")
	assert(isolated.setup() and calls == 2, "container setup did not retry exactly once")
	assert(isolated.setup() and calls == 2, "configured container core was initialized twice")
	package.loaded["config.devcontainer"] = saved_adapter
	package.loaded.devcontainer_editor = saved_core
	vim.env.NVIM_DEVCONTAINER = previous_container
end)

package.loaded["config.repo"] = old_repo
package.loaded["config.local_config"] = old_local_config
for name, value in pairs(original) do
	vim.env[name] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("devcontainer_editor_host_spec: %d tests passed", count))
vim.cmd("quitall!")
