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
local cli = fixture .. "/devcontainer"
local docker = fixture .. "/podman"
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, cli) == 0)
assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, docker) == 0)
assert(vim.uv.fs_chmod(cli, tonumber("700", 8)))
assert(vim.uv.fs_chmod(docker, tonumber("700", 8)))
cli = assert(vim.uv.fs_realpath(cli))
docker = assert(vim.uv.fs_realpath(docker))
local original = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
	TMUX_PANE = vim.env.TMUX_PANE,
}
vim.env.NVIM_DEVCONTAINER = nil
vim.env.TMUX_PANE = "%7"

local old_repo = package.loaded["config.repo"]
local old_local_config = package.loaded["config.local_config"]
local old_tool_bootstrap = package.loaded["config.tool_bootstrap"]
package.loaded["config.repo"] = {
	current_root = function()
		return root
	end,
}
package.loaded["config.local_config"] = {
	host_plugin = function(name, defaults)
		assert(name == "devcontainer_editor")
		assert(defaults.docker_path == "docker" and defaults.lockfile_policy == "preserve")
		assert(defaults.ssh_agent == "auto" and defaults.claim_timeout_ms == 2000)
		assert(defaults.ack_timeout_ms == 5000 and defaults.max_messages_per_tick == 32)
		assert(defaults.ui.progress and defaults.ui.progress_interval_ms == 500)
		assert(defaults.ui.log_width == 72 and defaults.ui.auto_open_log_on_error)
		local result = vim.deepcopy(defaults)
		result.docker_path = docker
		return result
	end,
}
package.loaded["config.tool_bootstrap"] = {
	resolve = function(name, command)
		assert(name == "devcontainers-cli" and command == "devcontainer")
		return cli
	end,
}

local devcontainer = require("config.devcontainer")
assert(package.loaded.devcontainer_editor == nil, "devcontainer core loaded while registering host commands")

test("host adapter injects plugin callbacks and no config dependency crosses the boundary", function()
	local options = devcontainer._options()
	assert(type(options.state_root) == "function")
	assert(type(options.open) == "function")
	assert(type(options.notify) == "function")
	assert(options.docker_path == docker and options.lockfile_policy == "preserve")
	assert(options.resolve_cli() == cli)
	assert(options.ssh_agent == "auto" and options.claim_timeout_ms == 2000)
	assert(options.ack_timeout_ms == 5000 and options.max_messages_per_tick == 32)
	assert(options.ui == nil, "host visual policy crossed into the local plugin")
	assert(type(options.state_root()) == "string", "default private state root was rejected")
	local previous_state = vim.env.NVIM_DEVCONTAINER_STATE_HOME
	vim.env.NVIM_DEVCONTAINER_STATE_HOME = "/srv/shared/nvim-devcontainer"
	assert(options.state_root() == nil, "shared non-HOME state root was accepted")
	vim.env.NVIM_DEVCONTAINER_STATE_HOME = previous_state
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

test("existing lifecycle states give actionable guidance without starting another lifecycle", function()
	local core = devcontainer._core()
	local old_status = core.status
	local old_claim = core.new_claim_id
	local old_system = vim.system
	local calls = {}
	core.new_claim_id = function()
		error("lifecycle guidance allocated a new claim")
	end
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		assert(argv[1] == "tmux" and argv[2] == "display-message", "lifecycle guidance started a process")
		return {
			wait = function()
				return { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
			end,
		}
	end

	local cases = {
		{
			status = "error",
			recreate = false,
			expected = "Dev Container lifecycle is error; run :DevContainerLog for details, "
				.. "then :DevContainerHostEditor to recover it, and retry :DevContainerUp",
		},
		{
			status = "stopped",
			recreate = true,
			expected = "Dev Container lifecycle is stopped; run :DevContainerLog for details, "
				.. "then :DevContainerHostEditor to recover it, and retry :DevContainerRecreate",
		},
		{
			status = "starting",
			recreate = false,
			expected = "Dev Container lifecycle is starting; wait for the registered container editor to open",
		},
		{
			status = "running",
			recreate = false,
			expected = "Dev Container lifecycle is running; use the registered container editor instead of starting another lifecycle",
		},
	}
	for _, case in ipairs(cases) do
		core.status = function()
			return { status = case.status }
		end
		local ok, err = devcontainer._replace_editor(case.recreate, false)
		assert(ok == nil and err == case.expected, vim.inspect({ status = case.status, error = err }))
	end
	core.status = function()
		error("injected workspace status failure")
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err:find("injected workspace status failure", 1, true))
	assert(#calls == #cases + 1, "lifecycle guidance did more than inspect the tmux pane")

	vim.system = old_system
	core.status = old_status
	core.new_claim_id = old_claim
end)

test("recreate and network authorization are explicit launcher argv", function()
	local old_system = vim.system
	local core = devcontainer._core()
	local old_claim = core.new_claim_id
	local old_status = core.status
	local calls = {}
	local status_calls = 0
	core.new_claim_id = function()
		return "00000000-0000-4000-8000-000000000031"
	end
	core.status = function()
		status_calls = status_calls + 1
		if status_calls == 1 then
			return nil, "workspace record is missing or not a regular file"
		end
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
	assert(#calls == 3 and calls[2][2] == "doctor" and calls[3][2] == "run-shell" and calls[3][3] == "-b")
	assert(calls[3][4] == "-t" and calls[3][5] == "%7")
	local command = calls[3][#calls[3]]
	assert(command:find("scripts/devcontainer%-editor"))
	assert(command:find("--recreate", 1, true) and command:find("--allow-network", 1, true))
	assert(command:find("--tmux%-pane") and command:find("%%7"))
	assert(command:find("--claim%-id") and command:find("00000000%-0000%-4000%-8000%-000000000031"))
	assert(command:find("--cli%-path") and command:find(cli, 1, true))
	assert(command:find("--docker%-path") and command:find(docker, 1, true))
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
		local doctor = argv[2] == "doctor"
		return {
			wait = function()
				return display and { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
					or doctor and { code = 0, stdout = "{}", stderr = "" }
					or { code = 1, stdout = "", stderr = "detached start failed" }
			end,
		}
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err == "detached start failed")
	assert(#calls == 3 and calls[3][2] == "run-shell")
	for _, call in ipairs(calls) do
		assert(call[2] ~= "respawn-pane" and call[2] ~= "set-option")
	end
	vim.system = old_system
end)

test("failed preflight never publishes a claim or starts the coordinator", function()
	local old_system = vim.system
	local core = devcontainer._core()
	local old_status = core.status
	local old_claim = core.new_claim_id
	local claimed = false
	local calls = {}
	core.status = function()
		return nil, "workspace record is missing or not a regular file"
	end
	core.new_claim_id = function()
		claimed = true
		return "00000000-0000-4000-8000-000000000061"
	end
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		return {
			wait = function()
				if argv[2] == "display-message" then
					return { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
				end
				return { code = 2, stdout = "", stderr = "podman service is unavailable" }
			end,
		}
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err == "podman service is unavailable")
	assert(not claimed and #calls == 2 and calls[2][2] == "doctor")
	assert(not vim.tbl_contains(
		vim.tbl_map(function(call)
			return call[2]
		end, calls),
		"run-shell"
	))
	vim.system = old_system
	core.status = old_status
	core.new_claim_id = old_claim
end)

test("headless prepare returns the exact pair used by doctor", function()
	local old_system = vim.system
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		return {
			wait = function()
				return { code = 0, stdout = "ready\n", stderr = "" }
			end,
		}
	end
	local runtime, err = devcontainer.prepare_up(root)
	assert(err == nil and runtime.cli_path == cli and runtime.docker_path == docker)
	assert(#calls == 1 and calls[1][2] == "doctor")
	assert(vim.list_contains(calls[1], cli) and vim.list_contains(calls[1], docker))
	runtime.cli_path = "/mutated"
	assert(devcontainer._core().resolve_runtime().cli_path == cli, "prepare_up leaked mutable plugin state")
	vim.system = old_system
end)

test("headless record preflight accepts dead v4/v5/v6 state", function()
	local core = devcontainer._core()
	local old_status = core.status
	local old_system = vim.system
	local doctor_calls = 0
	vim.system = function(argv)
		assert(argv[2] == "doctor")
		doctor_calls = doctor_calls + 1
		return {
			wait = function()
				return { code = 0, stdout = "ready\n", stderr = "" }
			end,
		}
	end
	core.status = function()
		return {
			version = 4,
			status = "dead",
			cli_path = cli,
			docker_path = docker,
			config_path = root .. "/.devcontainer/devcontainer.json",
		}
	end
	assert(devcontainer.preflight_record(root))
	assert(doctor_calls == 1)
	core.status = function()
		return {
			version = 5,
			status = "dead",
			phase = "monitoring-editor",
			cli_path = cli,
			docker_path = docker,
			config_path = root .. "/.devcontainer/devcontainer.json",
		}
	end
	assert(devcontainer.preflight_record(root))
	assert(doctor_calls == 2)
	core.status = function()
		return {
			version = 6,
			status = "dead",
			phase = "monitoring-editor",
			cli_path = cli,
			docker_path = docker,
			podman_connection = vim.NIL,
			config_path = root .. "/.devcontainer/devcontainer.json",
		}
	end
	assert(devcontainer.preflight_record(root))
	assert(doctor_calls == 3)

	for _, state in ipairs({
		{ version = 3, status = "dead", cli_path = cli },
		{ version = 4, status = "running", cli_path = cli, docker_path = docker },
	}) do
		core.status = function()
			return state
		end
		local ok = devcontainer.preflight_record(root)
		assert(ok == nil, "non-restartable record passed headless preflight")
	end
	assert(doctor_calls == 3, "invalid record started doctor")
	vim.system = old_system
	core.status = old_status
end)

test("legacy dead records fail before preflight or restart claim", function()
	local old_system = vim.system
	local core = devcontainer._core()
	local old_status = core.status
	local old_claim = core.new_claim_id
	local claimed = false
	core.new_claim_id = function()
		claimed = true
		return "00000000-0000-4000-8000-000000000062"
	end
	vim.system = function(argv)
		return {
			wait = function()
				assert(argv[2] == "display-message")
				return { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
			end,
		}
	end
	for _, version in ipairs({ 2, 3 }) do
		core.status = function()
			return {
				version = version,
				status = "dead",
				cli_path = version == 3 and cli or nil,
				config_path = root .. "/.devcontainer/devcontainer.json",
			}
		end
		local ok, err = devcontainer._replace_editor(false, false)
		assert(ok == nil and err == "Dev Container restart requires a version 4, 5, or 6 workspace record")
	end
	assert(not claimed)
	vim.system = old_system
	core.status = old_status
	core.new_claim_id = old_claim
end)

test("detached launch is not successful before its exact starting claim", function()
	local core = devcontainer._core()
	local old_status = core.status
	local attempts = 0
	core.status = function()
		attempts = attempts + 1
		if attempts == 1 then
			error("transient workspace record decode failure")
		end
		return { claim_id = "00000000-0000-4000-8000-000000000041", status = "starting" }
	end
	assert(devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041"))
	assert(attempts == 2)
	core.status = function()
		return {
			claim_id = "00000000-0000-4000-8000-000000000041",
			status = "error",
			error = "exact detached lifecycle error",
		}
	end
	local ok, err, failed = devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041")
	assert(ok == nil and err == "exact detached lifecycle error")
	assert(failed.claim_id == "00000000-0000-4000-8000-000000000041" and failed.status == "error")
	local existing = { claim_id = "00000000-0000-4000-8000-000000000042", status = "error" }
	core.status = function()
		return existing
	end
	ok, err = devcontainer._wait_for_claim(root, "00000000-0000-4000-8000-000000000041", 1)
	assert(ok == nil and err:find("did not publish", 1, true))
	assert(existing.claim_id == "00000000-0000-4000-8000-000000000042" and existing.status == "error")
	core.status = old_status
end)

test("a dead record uses explicit restart without re-resolving the CLI", function()
	local old_system = vim.system
	local core = devcontainer._core()
	local old_claim = core.new_claim_id
	local old_status = core.status
	local claim = "00000000-0000-4000-8000-000000000051"
	local status_calls = 0
	local calls = {}
	core.new_claim_id = function()
		return claim
	end
	core.status = function()
		status_calls = status_calls + 1
		if status_calls == 1 then
			return {
				version = 6,
				claim_id = "00000000-0000-4000-8000-000000000050",
				status = "dead",
				phase = "monitoring-editor",
				cli_path = cli,
				docker_path = docker,
				podman_connection = vim.NIL,
				config_path = root .. "/.devcontainer/devcontainer.json",
			}
		end
		return { claim_id = claim, status = "starting" }
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
	assert(#calls == 3 and calls[2][2] == "doctor")
	assert(vim.list_contains(calls[2], cli) and vim.list_contains(calls[2], docker))
	local command = calls[3][#calls[3]]
	assert(command:find("restart%-dead"))
	assert(command:find("--recreate", 1, true))
	assert(not command:find("--cli", 1, true))
	assert(not command:find("--allow%-network"))

	vim.system = old_system
	core.new_claim_id = old_claim
	core.status = old_status
end)

test("host editor command is idempotent and reports asynchronous recovery outcomes", function()
	local core = devcontainer._core()
	local old_status = core.status
	core.status = function()
		return nil, "workspace record is missing or not a regular file"
	end
	local ok, message = devcontainer._return_to_host()
	assert(ok and message:find("already running", 1, true))

	local old_system = vim.system
	local old_notify = vim.notify
	local calls = {}
	local callbacks = {}
	local notices = {}
	core.status = function()
		return { status = "error", error = "previous startup failed" }
	end
	vim.system = function(argv, _, callback)
		calls[#calls + 1] = vim.deepcopy(argv)
		if callback then
			callbacks[#callbacks + 1] = callback
		end
		return {
			wait = function()
				return { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
			end,
		}
	end
	vim.notify = function(value, level)
		notices[#notices + 1] = { message = value, level = level }
	end
	assert(devcontainer._return_to_host())
	assert(#calls == 2 and calls[1][2] == "display-message")
	assert(vim.deep_equal(calls[2], { devcontainer._launcher, "host", "--repo", root, "--tmux-pane", "%7" }))
	assert(#notices == 0 and #callbacks == 1, "host recovery completion was not asynchronous")
	callbacks[1]({ code = 0, stdout = "", stderr = "" })
	assert(
		vim.wait(100, function()
			return #notices == 1
		end),
		"successful host recovery notification was not scheduled"
	)
	assert(notices[1].message == "Dev Container lifecycle recovered; retry :DevContainerUp")
	assert(notices[1].level == vim.log.levels.INFO)

	assert(devcontainer._return_to_host())
	assert(#callbacks == 2, "failed host recovery callback was not captured")
	callbacks[2]({ code = 2, stdout = "", stderr = "exact host recovery failure" })
	assert(
		vim.wait(100, function()
			return #notices == 2
		end),
		"failed host recovery notification was not scheduled"
	)
	assert(notices[2].message == "exact host recovery failure")
	assert(notices[2].level == vim.log.levels.ERROR)
	vim.system = old_system
	vim.notify = old_notify
	core.status = old_status
end)

test("host recovery refuses an active lifecycle", function()
	local core = devcontainer._core()
	local old_status = core.status
	for _, state in ipairs({ "starting", "running" }) do
		core.status = function()
			return { status = state }
		end
		local ok, err = devcontainer._return_to_host()
		assert(ok == nil and err:find("request host recovery", 1, true))
	end
	core.status = old_status
end)

test("lifecycle progress uses one direct frame id and one broker-backed success", function()
	local core = devcontainer._core()
	local old_status = core.status
	local old_claim = core.new_claim_id
	local old_system = vim.system
	local old_notify = vim.notify
	local claim = "00000000-0000-4000-8000-000000000071"
	local calls = 0
	local clock = 0
	local frames = {}
	local notices = {}
	local order = {}
	local timer = { closed = false }
	function timer:start(timeout, repeating, callback)
		self.timeout = timeout
		self.repeating = repeating
		self.callback = callback
		return 0
	end
	function timer:stop()
		self.stopped = true
		return 0
	end
	function timer:is_closing()
		return self.closed
	end
	function timer:close()
		self.closed = true
	end
	core.new_claim_id = function()
		return claim
	end
	core.status = function()
		calls = calls + 1
		if calls == 1 then
			return nil, "workspace record is missing or not a regular file"
		end
		if calls == 2 then
			return { claim_id = claim, status = "starting", phase = "claimed", pid = 712 }
		end
		if calls == 3 then
			return { claim_id = claim, status = "starting", phase = "preparing-config", pid = 712 }
		end
		return { claim_id = claim, status = "running", phase = "monitoring-editor", pid = 712 }
	end
	vim.system = function(argv)
		order[#order + 1] = "system:" .. tostring(argv[2])
		local stdout = argv[2] == "display-message" and "editor\t1\t0\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, options = options }
	end
	devcontainer._set_progress_dependencies({
		visual_notify = function(message, level, options)
			order[#order + 1] = "frame"
			frames[#frames + 1] = { message = message, level = level, options = options }
			return true
		end,
		visual_hide = function() end,
		redraw = function()
			order[#order + 1] = "redraw"
		end,
		now_ms = function()
			return clock
		end,
		new_timer = function()
			return timer
		end,
		schedule = function(callback)
			callback()
		end,
		kill = function(pid, signal)
			assert(pid == 712 and signal == 0)
			return 0
		end,
	})

	local descriptor, execute_err = devcontainer._execute_replace(false, false)
	assert(descriptor, execute_err)
	assert(descriptor.root == root and descriptor.claim_id == claim and descriptor.status == "starting")
	assert(not pcall(function()
		descriptor.root = "/mutated"
	end), "lifecycle descriptor remained mutable")
	assert(order[1] == "frame" and order[2] == "redraw" and order[3] == "system:display-message")
	assert(#frames == 2 and #notices == 0, "claim progress entered native notification history")
	assert(frames[1].message:find("Preparing Dev Container", 1, true))
	assert(frames[2].message:find("Lifecycle claimed", 1, true))
	assert(frames[1].options.id == frames[2].options.id)
	assert(frames[1].options.id == "devcontainer:" .. vim.fn.sha256(root), "progress id exposed the raw root")
	assert(frames[1].options.timeout == false and frames[1].options.history == false)
	assert(timer.timeout == 500 and timer.repeating == 500, "progress interval changed")

	clock = 750
	timer.callback()
	assert(frames[#frames].message:find("Preparing configuration", 1, true))
	assert(frames[#frames].message:find("0.8s", 1, true), "progress omitted monotonic elapsed time")
	clock = 1000
	timer.callback()
	assert(timer.closed and timer.stopped, "terminal state did not close the progress timer")
	assert(#notices == 1 and notices[1].level == vim.log.levels.INFO)
	assert(notices[1].message:find("editor is running", 1, true))
	assert(notices[1].options.id == frames[1].options.id and notices[1].options.timeout == 3000)

	devcontainer._set_progress_dependencies()
	vim.system = old_system
	vim.notify = old_notify
	core.status = old_status
	core.new_claim_id = old_claim
end)

test("only exact terminal lifecycle errors auto-open the validated log", function()
	local core = devcontainer._core()
	local deferred_module = require("config.deferred")
	local old_status = core.status
	local old_claim = core.new_claim_id
	local old_log_path = core.log_path
	local old_try = deferred_module.try
	local old_system = vim.system
	local old_notify = vim.notify
	local claim = "00000000-0000-4000-8000-000000000072"
	local status_calls = 0
	local notices = {}
	local opened = 0
	local timer = { closed = false }
	function timer:start(_, _, callback)
		self.callback = callback
		return 0
	end
	function timer:stop()
		return 0
	end
	function timer:is_closing()
		return self.closed
	end
	function timer:close()
		self.closed = true
	end
	core.new_claim_id = function()
		return claim
	end
	core.status = function()
		status_calls = status_calls + 1
		if status_calls == 1 then
			return nil, "workspace record is missing or not a regular file"
		end
		if status_calls == 2 then
			return { claim_id = claim, status = "starting", phase = "starting-container", pid = 722 }
		end
		if status_calls == 3 then
			error("transient record decode exception")
		end
		return { claim_id = claim, status = "error", phase = "starting-container", pid = 722, error = "build failed" }
	end
	core.log_path = function(project_root)
		assert(project_root == root)
		return root .. "/validated.log"
	end
	deferred_module.try = function(name)
		if name == "config.log_watch" then
			return true,
				{
					follow_path = function(path, options)
						assert(path == root .. "/validated.log" and options.presenter == "devcontainer-log")
						opened = opened + 1
						return { path = path }
					end,
				}
		end
		return old_try(name)
	end
	vim.system = function(argv)
		local stdout = argv[2] == "display-message" and "editor\t1\t0\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, options = options }
	end
	devcontainer._set_progress_dependencies({
		visual_notify = function()
			return true
		end,
		visual_hide = function() end,
		redraw = function() end,
		now_ms = function()
			return 0
		end,
		new_timer = function()
			return timer
		end,
		schedule = function(callback)
			callback()
		end,
		kill = function()
			return 0
		end,
	})
	assert(devcontainer._execute_replace(false, false))
	timer.callback()
	assert(devcontainer._active_progress(), "thrown status read escaped its grace period")
	assert(opened == 0 and #notices == 0, "transient status read became a terminal error")
	timer.callback()
	assert(opened == 1, "post-claim lifecycle error did not open its live log")
	assert(#notices == 1 and notices[1].message:find("build failed", 1, true))
	assert(notices[1].message:find(":DevContainerLog", 1, true))
	assert(notices[1].message:find(":DevContainerHostEditor", 1, true))
	assert(notices[1].options.timeout == false)

	status_calls = 0
	core.status = function()
		status_calls = status_calls + 1
		return nil, "workspace record is missing or not a regular file"
	end
	vim.system = function(argv)
		if argv[2] == "display-message" then
			return {
				wait = function()
					return { code = 0, stdout = "editor\t1\t0\n", stderr = "" }
				end,
			}
		end
		return {
			wait = function()
				return { code = 2, stdout = "", stderr = "preflight unavailable" }
			end,
		}
	end
	local ok, preflight_err = devcontainer._execute_replace(false, false)
	assert(ok == nil and preflight_err == "preflight unavailable")
	assert(opened == 1, "pre-claim failure opened a lifecycle log")
	assert(#notices == 2 and notices[2].message == "preflight unavailable")

	status_calls = 0
	core.status = function()
		status_calls = status_calls + 1
		if status_calls == 1 then
			return nil, "workspace record is missing or not a regular file"
		end
		return {
			claim_id = claim,
			status = "error",
			phase = "starting-container",
			pid = 722,
			error = "quick build failure",
		}
	end
	vim.system = function(argv)
		local stdout = argv[2] == "display-message" and "editor\t1\t0\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	ok, preflight_err = devcontainer._execute_replace(false, false)
	assert(ok == nil and preflight_err == "quick build failure")
	assert(opened == 2, "an exact quick post-claim failure did not open its lifecycle log")
	assert(#notices == 3 and notices[3].message:find("quick build failure", 1, true))
	assert(notices[3].message:find(":DevContainerLog", 1, true))

	status_calls = 0
	core.status = function()
		status_calls = status_calls + 1
		if status_calls == 1 then
			return nil, "workspace record is missing or not a regular file"
		end
		return { claim_id = claim, status = "starting", phase = "claimed", pid = 722 }
	end
	devcontainer._set_progress_dependencies({
		visual_notify = function()
			return true
		end,
		visual_hide = function() end,
		redraw = function() end,
		now_ms = function()
			return 0
		end,
		new_timer = function()
			return nil, "injected timer failure"
		end,
	})
	ok, preflight_err = devcontainer._execute_replace(false, false)
	assert(ok == nil and preflight_err == "injected timer failure")
	assert(opened == 2, "a progress-only failure opened the lifecycle log")
	assert(#notices == 4 and notices[4].message:find("progress timer", 1, true))

	devcontainer._set_progress_dependencies()
	vim.system = old_system
	vim.notify = old_notify
	deferred_module.try = old_try
	core.status = old_status
	core.new_claim_id = old_claim
	core.log_path = old_log_path
end)

test("coordinator liveness treats only ESRCH as a confirmed exit", function()
	devcontainer._set_progress_dependencies({
		kill = function()
			return 0
		end,
	})
	assert(devcontainer._coordinator_alive(42) == true)
	devcontainer._set_progress_dependencies({
		kill = function()
			return nil, "ESRCH: no such process"
		end,
	})
	assert(devcontainer._coordinator_alive(42) == false)
	devcontainer._set_progress_dependencies({
		kill = function()
			return nil, "EPERM: operation not permitted"
		end,
	})
	assert(devcontainer._coordinator_alive(42) == nil)
	devcontainer._set_progress_dependencies()
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

test("the replacement container editor publishes one broker success", function()
	local previous_container = vim.env.NVIM_DEVCONTAINER
	local previous_host_root = vim.env.NVIM_DEVCONTAINER_HOST_ROOT
	local previous_claim = vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID
	local previous_very_lazy = vim.g.did_very_lazy
	local old_notify = vim.notify
	local core = devcontainer._core()
	local old_request_host = core.request_host
	local notices = {}
	local requests = 0
	local acknowledge
	local request_error
	local async_error
	vim.env.NVIM_DEVCONTAINER = "1"
	vim.env.NVIM_DEVCONTAINER_HOST_ROOT = root
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = "00000000-0000-4000-8000-000000000073"
	vim.g.did_very_lazy = false
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, options = options }
	end
	devcontainer._set_progress_dependencies({
		schedule = function(callback)
			callback()
		end,
	})
	core.request_host = function(action, request_dependencies, on_success)
		requests = requests + 1
		assert(action == "editor_ready", "startup used the wrong authenticated action")
		assert(type(request_dependencies.notify) == "function", "startup did not provide its failure broker")
		assert(type(on_success) == "function", "startup did not wait for the authenticated ACK")
		if request_error then
			return nil, request_error
		end
		if async_error then
			request_dependencies.notify(async_error, vim.log.levels.ERROR)
			return true, "00000000-0000-4000-8000-000000000076"
		end
		request_dependencies.notify("readiness request committed with a durability warning", vim.log.levels.WARN)
		acknowledge = on_success
		return true, "00000000-0000-4000-8000-000000000074"
	end

	assert(devcontainer.setup())
	assert(vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID == nil, "startup claim was not consumed")
	assert(requests == 0, "readiness was requested before the UI provider boundary")
	assert(#notices == 0, "container success was published before the UI provider boundary")
	vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
	assert(requests == 1, "container startup did not request exactly one authenticated readiness ACK")
	assert(#notices == 0, "container success was published before the authenticated readiness ACK")
	acknowledge({ action = "editor_ready", ok = true })
	assert(#notices == 1 and notices[1].level == vim.log.levels.INFO)
	assert(notices[1].message:find("editor is running", 1, true))
	assert(notices[1].message:find(":DevContainerLog", 1, true))
	assert(notices[1].message:find("durability warning", 1, true))
	assert(notices[1].options.id == "devcontainer:" .. vim.fn.sha256(root))
	assert(notices[1].options.timeout == 3000)
	vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
	assert(requests == 1 and #notices == 1, "container startup success was published more than once")
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = "00000000-0000-4000-8000-00000000007-"
	assert(devcontainer.setup())
	vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
	assert(requests == 1 and #notices == 1, "a non-canonical startup claim requested or published success")
	vim.g.did_very_lazy = true
	async_error = "injected asynchronous readiness failure"
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = "00000000-0000-4000-8000-000000000075"
	assert(devcontainer.setup())
	assert(requests == 2 and #notices == 2, "asynchronous readiness failure was not published once")
	assert(notices[2].level == vim.log.levels.ERROR)
	assert(notices[2].message:find("injected asynchronous readiness failure", 1, true))
	assert(notices[2].options.id == "devcontainer:" .. vim.fn.sha256(root))
	assert(notices[2].options.timeout == false)
	async_error = nil
	request_error = "injected readiness failure"
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = "00000000-0000-4000-8000-000000000077"
	assert(devcontainer.setup())
	assert(requests == 3 and #notices == 3, "synchronous readiness failure was not published once")
	assert(notices[3].level == vim.log.levels.ERROR)
	assert(notices[3].message:find("injected readiness failure", 1, true))
	assert(notices[3].options.id == "devcontainer:" .. vim.fn.sha256(root))
	assert(notices[3].options.timeout == false)

	devcontainer._set_progress_dependencies()
	core.request_host = old_request_host
	vim.notify = old_notify
	vim.g.did_very_lazy = previous_very_lazy
	vim.env.NVIM_DEVCONTAINER = previous_container
	vim.env.NVIM_DEVCONTAINER_HOST_ROOT = previous_host_root
	vim.env.NVIM_DEVCONTAINER_START_CLAIM_ID = previous_claim
end)

package.loaded["config.repo"] = old_repo
package.loaded["config.local_config"] = old_local_config
package.loaded["config.tool_bootstrap"] = old_tool_bootstrap
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
