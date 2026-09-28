local function terminal_editor()
	return not vim.g.vscode
end

local managed_adapters = {
	codelldb = true,
	debugpy = true,
	lldb = true,
	python = true,
}

local function workspace_options(config, original, managed)
	local unresolved = false
	for _, field in ipairs({ "cwd", "workspace", "workspaceFolder", "program" }) do
		local value = type(config) == "table" and config[field] or nil
		if type(value) == "string" and value ~= "" and not value:find("${", 1, true) then
			return { root = value }
		end
		unresolved = unresolved or value ~= nil or (type(original) == "table" and original[field] ~= nil)
	end
	if unresolved then
		return nil, "debug configuration workspace could not be resolved after expansion"
	end
	if managed or (type(config) == "table" and managed_adapters[config.type]) then
		return { buf = 0 }
	end
	return nil, "unmanaged debug adapters must provide cwd, workspace, workspaceFolder, or program"
end

local function abort_config(dap, config, key)
	local rejected = vim.deepcopy(config)
	rejected.type = dap.ABORT
	rejected[key] = function()
		return dap.ABORT
	end
	return rejected
end

local function contains_abort(dap, config)
	if type(config) ~= "table" then
		return false
	end
	for _, value in pairs(config) do
		if value == dap.ABORT then
			return true
		end
	end
	return false
end

local function notify_cppdbg()
	vim.notify(
		"cppdbg requires the Microsoft C/C++ adapter; use lldb or codelldb for CodeLLDB",
		vim.log.levels.WARN,
		{ title = "DAP" }
	)
end

local function install_execution_gate(dap, workflow)
	if not dap._nvim_config_execution_gate_v1 then
		local expand = dap.listeners.on_config["dap.expand_variable"]
		if type(expand) ~= "function" then
			error("nvim-dap variable expansion boundary is unavailable", 0)
		end
		dap.listeners.on_config["dap.expand_variable"] = function(config)
			local expanded = expand(config)
			if contains_abort(dap, expanded) then
				error("DAP debug configuration aborted", 0)
			end
			local options, options_err = workspace_options(expanded, config)
			if not options then
				error("DAP debug execution denied: " .. options_err, 0)
			end
			local granted, grant_err = workflow.grant("debug", options)
			if not granted then
				error("DAP debug execution denied: " .. tostring(grant_err), 0)
			end
			return expanded
		end
		dap._nvim_config_execution_gate_v1 = true
	end

	if not dap._nvim_config_restart_gate_v1 then
		local restart = dap.restart
		if type(restart) ~= "function" then
			error("nvim-dap restart API is unavailable", 0)
		end
		dap.restart = function(config, opts)
			local candidate = config
			if candidate == nil and type(dap.session) == "function" then
				local session = dap.session()
				candidate = session and session.config or nil
			end
			if type(candidate) == "table" and candidate.type == "cppdbg" then
				notify_cppdbg()
				return
			end
			return restart(config, opts)
		end
		dap._nvim_config_restart_gate_v1 = true
	end
end

local function add_configuration(configurations, candidate)
	for _, existing in ipairs(configurations) do
		if
			existing.type == candidate.type
			and existing.request == candidate.request
			and existing.name == candidate.name
		then
			return
		end
	end
	configurations[#configurations + 1] = candidate
end

local function python_enricher(dap_python)
	return function(config, on_config)
		local resolved = vim.deepcopy(config)
		if not resolved.pythonPath and not resolved.python and type(dap_python.resolve_python) == "function" then
			local ok, interpreter = pcall(dap_python.resolve_python)
			resolved.pythonPath = ok and interpreter or nil
		end
		local envfile = vim.fn.fnamemodify(resolved.envFile or "./.env", ":p")
		resolved.envFile = nil
		local file = io.open(envfile, "r")
		if file then
			local environment = vim.empty_dict()
			for line in file:lines() do
				local name, value = line:match("^([^=]+)=(.+)")
				if name and value and name:sub(1, 1) ~= "#" then
					environment[name] = value:gsub("^'(.*)'$", "%1"):gsub('^"(.*)"$', "%1")
				end
			end
			file:close()
			resolved.env = vim.tbl_deep_extend("force", resolved.env or vim.empty_dict(), environment)
		end
		on_config(resolved)
	end
end

local function install_python(dap, workflow, dap_python, splitstr)
	local enrich_config = python_enricher(dap_python)
	dap.adapters.python = function(callback, config)
		if type(callback) ~= "function" or type(config) ~= "table" then
			return
		end
		local options, options_err = workspace_options(config, nil, true)
		if not options then
			workflow.notify("DAP", "Python debug session denied: " .. options_err, vim.log.levels.ERROR)
			return
		end
		if config.request == "attach" then
			local granted, grant_err = workflow.grant("debug", options)
			if not granted then
				workflow.notify("DAP", "Python attach denied: " .. tostring(grant_err), vim.log.levels.ERROR)
				return
			end
			local connect = type(config.connect) == "table" and config.connect or config
			if type(connect.port) ~= "number" then
				workflow.notify("DAP", "Python attach denied: connect.port is required", vim.log.levels.ERROR)
				return
			end
			callback({
				type = "server",
				host = connect.host or "127.0.0.1",
				port = connect.port,
				enrich_config = enrich_config,
				options = { source_filetype = "python" },
			})
			return
		end

		local command, resolve_err = workflow.tool("debug", "debugpy", "debugpy-adapter", options)
		if not command then
			workflow.notify("DAP", "Python debug launch denied: " .. tostring(resolve_err), vim.log.levels.ERROR)
			return
		end
		callback({
			type = "executable",
			command = command,
			args = {},
			enrich_config = enrich_config,
			options = { source_filetype = "python" },
		})
	end
	dap.adapters.debugpy = dap.adapters.python

	dap.listeners.before["event_debugpySockets"]["dap-python"] = function() end
	local configurations = dap.configurations.python or {}
	dap.configurations.python = configurations
	add_configuration(configurations, {
		type = "python",
		request = "launch",
		name = "file",
		program = "${file}",
		console = "integratedTerminal",
	})
	add_configuration(configurations, {
		type = "python",
		request = "launch",
		name = "file:args",
		program = "${file}",
		args = function()
			local input = vim.fn.input("Arguments: ")
			return type(splitstr) == "function" and splitstr(input) or vim.split(input, " +")
		end,
		console = "integratedTerminal",
	})
	add_configuration(configurations, {
		type = "python",
		request = "attach",
		name = "attach",
		connect = function()
			local host = vim.fn.input("Host [127.0.0.1]: ")
			host = host ~= "" and host or "127.0.0.1"
			return { host = host, port = tonumber(vim.fn.input("Port [5678]: ")) or 5678 }
		end,
	})
	add_configuration(configurations, {
		type = "python",
		request = "launch",
		name = "file:doctest",
		module = "doctest",
		args = { "${file}" },
		noDebug = true,
		console = "integratedTerminal",
	})
end

local function install_codelldb(dap, workflow)
	local adapter = function(callback, config)
		if type(callback) ~= "function" or type(config) ~= "table" then
			return
		end
		local options, options_err = workspace_options(config, nil, true)
		if not options then
			workflow.notify("DAP", "C/C++ debug launch denied: " .. options_err, vim.log.levels.ERROR)
			return
		end
		local command, resolve_err = workflow.tool("debug", "codelldb", "codelldb", options)
		if not command then
			workflow.notify("DAP", "C/C++ debug launch denied: " .. tostring(resolve_err), vim.log.levels.ERROR)
			return
		end
		callback({
			type = "server",
			port = "${port}",
			executable = {
				command = command,
				args = { "--port", "${port}" },
			},
		})
	end
	dap.adapters.codelldb = adapter
	dap.adapters.lldb = adapter

	if dap.configurations.cpp == nil then
		dap.configurations.cpp = {
			{
				name = "Launch file",
				type = "codelldb",
				request = "launch",
				program = function()
					return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/", "file")
				end,
				cwd = "${workspaceFolder}",
				stopOnEntry = false,
			},
		}
	end
	dap.configurations.c = dap.configurations.cpp
end

return {
	{
		"mfussenegger/nvim-dap",
		cmd = { "DapContinue", "DapToggleBreakpoint", "DapStepOver", "DapStepInto", "DapStepOut", "DapTerminate" },
		cond = terminal_editor,
		keys = {
			{
				"<F5>",
				function()
					require("dap").continue()
				end,
				desc = "Debug: Continue",
			},
			{
				"<F10>",
				function()
					require("dap").step_over()
				end,
				desc = "Debug: Step over",
			},
			{
				"<F11>",
				function()
					require("dap").step_into()
				end,
				desc = "Debug: Step into",
			},
			{
				"<F12>",
				function()
					require("dap").step_out()
				end,
				desc = "Debug: Step out",
			},
			{
				"<leader>db",
				function()
					require("dap").toggle_breakpoint()
				end,
				desc = "Debug: Toggle breakpoint",
			},
			{
				"<leader>du",
				function()
					require("config.dap_ui").toggle()
				end,
				desc = "Debug: Toggle UI",
			},
		},
		dependencies = {
			"nvim-neotest/nvim-nio",
			"mfussenegger/nvim-dap-python",
		},
		config = function()
			local dap = require("dap")
			local dap_utils = package.loaded["dap.utils"]
			local workflow = require("config.workflow_execution")

			require("config.dap_ui").setup(dap)
			install_execution_gate(dap, workflow)
			dap.listeners.on_config.nvim_config_cppdbg = function(config)
				if type(config) ~= "table" or config.type ~= "cppdbg" then
					return config
				end
				-- The direct sentinel covers listeners that run before this one. The
				-- function-valued sentinel survives nvim-dap's variable-expansion
				-- listener when it runs afterwards.
				notify_cppdbg()
				return abort_config(dap, config, "nvim_config_abort")
			end

			local dap_python = require("dap-python")
			require("config.python").setup_dap(dap, dap_python)
			install_python(dap, workflow, dap_python, dap_utils and dap_utils.splitstr)
			-- launch.json interop: the VSCode CodeLLDB extension uses type
			-- "lldb". cppdbg belongs to cpptools and is rejected above instead
			-- of silently ignoring adapter-specific settings.
			install_codelldb(dap, workflow)
		end,
	},
	{
		"rcarriga/nvim-dap-ui",
		lazy = true,
		cond = terminal_editor,
	},
	{
		"igorlfs/nvim-dap-view",
		commit = "ba5c838e731003abefb8bc1c403c59aa5b3aa194",
		lazy = true,
		cond = terminal_editor,
	},
}
