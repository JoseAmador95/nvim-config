vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/nvim-dap")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
local dap_utils = require("dap.utils")

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

local originals = {}
for _, name in ipairs({
	"config.execution",
	"config.deferred",
	"config.workflow_execution",
	"config.dap_ui",
	"config.python",
	"dap",
	"dap-python",
	"neotest",
	"neotest.config",
	"neotest-python",
	"neotest-gtest",
	"plugins.dap",
	"plugins.neotest",
}) do
	originals[name] = package.loaded[name]
end

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local executable = fixture .. "/adapter"
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, executable)
assert(vim.uv.fs_chmod(executable, tonumber("700", 8)))
executable = assert(vim.uv.fs_realpath(executable))
local alias = fixture .. "/adapter-link"
assert(vim.uv.fs_symlink(executable, alias))

local authority_mode = "allow"
local authority_calls = {}
local resolver_calls = 0
local bootstrap_calls = 0
local bootstrap_path = executable
package.loaded["config.execution"] = {
	resolve = function(capability, resolver, opts)
		authority_calls[#authority_calls + 1] = { capability = capability, opts = vim.deepcopy(opts) }
		if authority_mode == "deny" then
			return nil, "grant denied"
		end
		if authority_mode == "throw" then
			error("authority exploded")
		end
		resolver_calls = resolver_calls + 1
		local resolved, resolve_err = resolver()
		if authority_mode == "revoke" then
			return nil, "grant revoked"
		end
		if not resolved then
			return nil, resolve_err
		end
		return resolved, { runtime = "host", root = repo, repo_identity = repo }
	end,
}
package.loaded["config.deferred"] = {
	load = function(name)
		assert(name == "config.tool_bootstrap")
		bootstrap_calls = bootstrap_calls + 1
		return {
			resolve = function(tool, command)
				assert(tool == "debugpy" and command == "debugpy-adapter")
				return bootstrap_path
			end,
		}
	end,
}
package.loaded["config.workflow_execution"] = nil

local workflow = require("config.workflow_execution")

test("workflow helper remains observational until an authorized resolver", function()
	assert(package.loaded["config.tool_bootstrap"] == nil)
	assert(package.loaded.verified_tools == nil)
	authority_mode = "allow"
	local granted = assert(workflow.grant("test", { root = repo }))
	assert(granted == true and resolver_calls == 1 and bootstrap_calls == 0)
	assert(package.loaded["config.tool_bootstrap"] == nil and package.loaded.verified_tools == nil)

	authority_mode = "deny"
	local denied, err = workflow.tool("debug", "debugpy", "debugpy-adapter", { root = repo })
	assert(denied == nil and err:find("grant denied", 1, true))
	assert(bootstrap_calls == 0, "denied authority invoked tool bootstrap")
end)

test("managed and host paths are exact and resolver failures stay closed", function()
	authority_mode = "allow"
	bootstrap_path = executable
	assert(workflow.tool("debug", "debugpy", "debugpy-adapter", { root = repo }) == executable)
	assert(bootstrap_calls == 1)

	bootstrap_path = "relative/adapter"
	local relative, relative_err = workflow.tool("debug", "debugpy", "debugpy-adapter", { root = repo })
	assert(relative == nil and relative_err:find("absolute path", 1, true))

	authority_mode = "revoke"
	bootstrap_path = executable
	local revoked, revoked_err = workflow.tool("debug", "debugpy", "debugpy-adapter", { root = repo })
	assert(revoked == nil and revoked_err:find("revoked", 1, true))

	authority_mode = "throw"
	local failed, failed_err = workflow.grant("build", { root = repo })
	assert(failed == nil and failed_err:find("authority resolution failed", 1, true))

	authority_mode = "allow"
	assert(workflow.host_executable("build", function()
		return alias
	end, executable, { root = repo }, "host tool") == executable)
	local drifted, drift_err = workflow.host_executable("build", function()
		return alias
	end, fixture .. "/other", { root = repo }, "host tool")
	assert(drifted == nil and drift_err:find("changed after discovery", 1, true))
end)

local workflow_mode = "allow"
local workflow_grants = {}
local workflow_tools = {}
local notifications = {}
local fake_workflow = {
	grant = function(capability, opts)
		workflow_grants[#workflow_grants + 1] = { capability = capability, opts = vim.deepcopy(opts) }
		if workflow_mode == "deny" or (workflow_mode == "revoke-debug" and capability == "debug") then
			return nil, capability .. " grant denied"
		end
		return true, { runtime = "host" }
	end,
	tool = function(capability, tool, command, opts)
		workflow_tools[#workflow_tools + 1] = {
			capability = capability,
			tool = tool,
			command = command,
			opts = vim.deepcopy(opts),
		}
		if workflow_mode == "tool-error" then
			return nil, "verified path drifted"
		end
		return "/verified/" .. command, { runtime = "host" }
	end,
	notify = function(title, message, level)
		notifications[#notifications + 1] = { title = title, message = tostring(message), level = level }
	end,
}

test("DAP gates direct runs and resolves adapters only inside callbacks", function()
	package.loaded["config.workflow_execution"] = fake_workflow
	package.loaded["config.dap_ui"] = { setup = function() end }
	package.loaded["config.python"] = {
		setup_dap = function(dap)
			dap.listeners.on_config.nvim_config_python = function(config)
				return config
			end
		end,
	}
	package.loaded["dap-python"] = {}
	local before = setmetatable({}, {
		__index = function(table_value, key)
			rawset(table_value, key, {})
			return rawget(table_value, key)
		end,
	})
	local abort = {}
	local restart_calls = 0
	local dap = {
		ABORT = abort,
		adapters = {},
		configurations = {},
		listeners = {
			before = before,
			on_config = {
				["dap.expand_variable"] = function(config)
					local expanded = vim.deepcopy(config)
					if type(expanded.cwd) == "function" then
						expanded.cwd = expanded.cwd()
					end
					return expanded
				end,
			},
		},
		restart = function()
			restart_calls = restart_calls + 1
		end,
		session = function()
			return nil
		end,
	}
	package.loaded.dap = dap
	package.loaded["plugins.dap"] = nil
	local configure = require("plugins.dap")[1].config
	configure()
	local execution_gate = dap.listeners.on_config["dap.expand_variable"]
	configure()
	assert(#dap.configurations.python == 4, "repeated DAP setup duplicated Python configurations")
	assert(dap.listeners.on_config["dap.expand_variable"] == execution_gate, "repeated DAP setup nested its gate")
	local arguments = assert(vim.iter(dap.configurations.python):find(function(config)
		return config.name == "file:args"
	end)).args
	local input = vim.fn.input
	vim.fn.input = function()
		return [[one "two words" escaped\ space]]
	end
	local parsed = arguments()
	vim.fn.input = input
	assert(vim.deep_equal(parsed, { "one", "two words", "escaped space" }), "Python DAP argv parsing drifted")

	workflow_mode = "deny"
	workflow_grants = {}
	local source = { type = "custom", request = "launch", cwd = repo }
	assert(not pcall(execution_gate, source))
	assert(source.type == "custom")
	assert(#workflow_grants == 1 and workflow_grants[1].capability == "debug")
	workflow_mode = "allow"
	local grant_count = #workflow_grants
	assert(not pcall(execution_gate, { type = "custom", request = "launch" }))
	assert(#workflow_grants == grant_count, "unmanaged DAP adapter inferred workspace authority from the buffer")
	restart_calls = 0

	workflow_grants = {}
	local other_root = repo .. "/tests"
	local functional = {
		type = "custom",
		request = "launch",
		cwd = function()
			return other_root
		end,
	}
	local accepted = execution_gate(functional)
	assert(accepted ~= functional and accepted.cwd == other_root and functional.cwd ~= other_root)
	assert(workflow_grants[1].opts.root == other_root, "DAP gate authorized before configuration expansion")
	dap.restart(functional, {})
	assert(restart_calls == 1, "authorized DAP restart did not reach upstream")
	assert(#workflow_grants == 1, "DAP restart performed a premature grant before configuration expansion")
	dap.restart({ type = "cppdbg", cwd = repo }, {})
	assert(restart_calls == 1, "cppdbg direct restart reached upstream")
	local launch = { request = "launch", cwd = repo }
	local launch_copy = vim.deepcopy(launch)
	local callbacks = 0
	local python_adapter
	dap.adapters.python(function(adapter)
		callbacks = callbacks + 1
		python_adapter = adapter
	end, launch)
	assert(callbacks == 1 and python_adapter.command == "/verified/debugpy-adapter")
	assert(vim.deep_equal(python_adapter.args, {}) and vim.deep_equal(launch, launch_copy))
	assert(workflow_tools[#workflow_tools].tool == "debugpy")

	local attach = { request = "attach", connect = { host = "127.0.0.2", port = 8765 }, cwd = repo }
	local tool_count = #workflow_tools
	local attach_adapter
	dap.adapters.python(function(adapter)
		attach_adapter = adapter
	end, attach)
	assert(attach_adapter.type == "server" and attach_adapter.host == "127.0.0.2" and attach_adapter.port == 8765)
	assert(#workflow_tools == tool_count, "Python attach resolved a managed tool")
	workflow_mode = "deny"
	callbacks = 0
	dap.adapters.python(function()
		callbacks = callbacks + 1
	end, attach)
	assert(callbacks == 0 and #workflow_tools == tool_count, "denied Python attach reached an adapter callback")

	workflow_mode = "tool-error"
	callbacks = 0
	dap.adapters.codelldb(function()
		callbacks = callbacks + 1
	end, { request = "launch", cwd = repo })
	assert(callbacks == 0 and notifications[#notifications].message:find("drifted", 1, true))

	workflow_mode = "allow"
	local codelldb
	dap.adapters.codelldb(function(adapter)
		codelldb = adapter
	end, { request = "launch", cwd = repo })
	assert(codelldb.executable.command == "/verified/codelldb")
	assert(vim.deep_equal(codelldb.executable.args, { "--port", "${port}" }))
	assert(dap.adapters.lldb == dap.adapters.codelldb and dap.adapters.cppdbg == nil)
	assert(package.loaded["config.tool_bootstrap"] == nil and package.loaded.verified_tools == nil)
end)

test("DAP existing-session restart authorizes only the expanded workspace", function()
	local gate_calls = {}
	local gate_notifications = 0
	local gate_mode = "deny"
	package.loaded["config.workflow_execution"] = {
		grant = function(capability, opts)
			gate_calls[#gate_calls + 1] = { capability = capability, opts = vim.deepcopy(opts) }
			if gate_mode == "deny" or (gate_mode == "only-fixture" and opts.root ~= fixture) then
				return nil, "debug grant denied"
			end
			return true, { runtime = "host" }
		end,
		tool = fake_workflow.tool,
		notify = function()
			gate_notifications = gate_notifications + 1
		end,
	}
	package.loaded.dap = nil
	package.loaded["plugins.dap"] = nil
	local dap = require("dap")
	require("plugins.dap")[1].config()
	local requests = 0
	local config = {
		name = "restart fixture",
		type = "python",
		request = "launch",
		cwd = function()
			return fixture
		end,
	}
	local session = {
		id = 9127,
		config = config,
		capabilities = { supportsRestartRequest = true },
		request = function(_, command)
			assert(command == "restart")
			requests = requests + 1
		end,
	}
	dap.set_session(session)
	local dap_notify = dap_utils.notify
	local dap_notifications = {}
	dap_utils.notify = function(message)
		dap_notifications[#dap_notifications + 1] = tostring(message)
	end
	dap.restart(config)
	local direct_restart_denied = requests == 0 and #gate_calls == 1

	gate_calls = {}
	dap.run(config)
	dap_utils.notify = dap_notify
	assert(direct_restart_denied, "denied direct dap.restart reached the adapter")
	assert(requests == 0 and #gate_calls == 1, "denied dap.run restarted an existing session")
	assert(gate_notifications == 0 and #dap_notifications == 2, "DAP denial emitted duplicate notifications")
	assert(dap_notifications[1]:find("debug grant denied", 1, true), "DAP denial omitted the authority failure")

	gate_mode = "only-fixture"
	gate_calls = {}
	dap_utils.notify = function(message)
		dap_notifications[#dap_notifications + 1] = tostring(message)
	end
	dap.restart({
		name = "aborted restart",
		type = "python",
		request = "launch",
		program = function()
			return dap.ABORT
		end,
	})
	dap_utils.notify = dap_notify
	assert(requests == 0 and #gate_calls == 0, "an aborted restart bypassed the execution gate")
	assert(dap_notifications[#dap_notifications]:find("configuration aborted", 1, true))

	gate_calls = {}
	dap.run(config)
	assert(requests == 1, "an authorized expanded workspace did not reach the DAP restart request")
	assert(#gate_calls == 1 and gate_calls[1].opts.root == fixture, "restart did not authorize the expanded cwd")
	dap.sessions()[session.id] = nil
	dap.set_session(nil)
end)

test("Neotest chains one immutable pre-spawn gate for run and run_last", function()
	package.loaded["config.workflow_execution"] = fake_workflow
	package.loaded["config.python"] = { neotest_python = function() end, neotest_runner = function() end }
	package.loaded["neotest-python"] = function()
		return { name = "python" }
	end
	package.loaded["neotest-gtest"] = {
		setup = function()
			return { name = "gtest" }
		end,
	}
	local previous_calls = 0
	local neotest_config = {
		default_strategy = "integrated",
		projects = {},
		run = {
			augment = function(_, args)
				previous_calls = previous_calls + 1
				args.previous = true
				return args
			end,
		},
	}
	local configured
	package.loaded["neotest.config"] = neotest_config
	package.loaded.neotest = {
		setup = function(options)
			configured = options
			neotest_config.run = options.run
		end,
	}
	package.loaded["plugins.neotest"] = nil
	local configure = require("plugins.neotest").config
	configure()
	local first_augment = configured.run.augment
	configure()
	assert(configured.run.augment == first_augment, "repeated Neotest setup nested the execution gate")

	local tree = {
		data = function()
			return { path = repo .. "/tests/workflow_execution_spec.lua" }
		end,
		root = function()
			return {
				data = function()
					return { path = repo }
				end,
			}
		end,
	}
	local source = { strategy = "integrated", nested = { value = 1 } }
	workflow_mode = "allow"
	workflow_grants = {}
	local result = configured.run.augment(tree, source)
	assert(
		result ~= source
			and result.previous
			and vim.deep_equal(source, { strategy = "integrated", nested = { value = 1 } })
	)
	assert(#workflow_grants == 1 and workflow_grants[1].capability == "test")

	local spawned = 0
	local function common_run(args)
		configured.run.augment(tree, args)
		spawned = spawned + 1
	end
	workflow_mode = "deny"
	assert(not pcall(common_run, {}))
	assert(not pcall(common_run, { strategy = "dap" }))
	assert(spawned == 0, "denied Neotest run reached the client spawn seam")

	workflow_mode = "revoke-debug"
	workflow_grants = {}
	assert(not pcall(common_run, { strategy = "dap" }))
	assert(spawned == 0)
	assert(
		#workflow_grants == 2 and workflow_grants[1].capability == "test" and workflow_grants[2].capability == "debug"
	)
	neotest_config.projects[repo] = { default_strategy = "dap" }
	workflow_grants = {}
	assert(not pcall(common_run, {}))
	assert(#workflow_grants == 2 and workflow_grants[2].capability == "debug")
	neotest_config.projects[repo] = nil
	assert(package.loaded["config.tool_bootstrap"] == nil and package.loaded.verified_tools == nil)
end)

for name, value in pairs(originals) do
	package.loaded[name] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("workflow_execution_spec: %d tests passed", count))
vim.cmd("quitall!")
