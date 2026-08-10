local function terminal_editor()
	return not vim.g.vscode
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
			local executables = require("config.dap_executables")

			require("config.dap_ui").setup(dap)

			-- Python debugging. Keep Mason's deterministic path even before the
			-- first install completes, so the adapter works later without a reload.
			local debugpy_path, has_debugpy = executables.resolve("debugpy-adapter")
			require("dap-python").setup(debugpy_path)
			require("config.python").setup_dap(dap)
			if not has_debugpy then
				vim.notify(
					"debugpy-adapter not found. Retry the exact tool manifest with :MasonToolsInstallSync",
					vim.log.levels.WARN,
					{ title = "DAP" }
				)
			end

			-- C/C++ debugging with codelldb from Mason. Register it even during a
			-- first-install race; Mason will create this path when installation ends.
			local codelldb_path, has_codelldb = executables.resolve("codelldb")
			dap.adapters.codelldb = {
				type = "server",
				port = "${port}",
				executable = {
					command = codelldb_path,
					args = { "--port", "${port}" },
				},
			}
			-- launch.json interop: the VSCode CodeLLDB extension uses type
			-- "lldb", cpptools uses "cppdbg"; route both to codelldb
			-- (cpptools-only keys like MIMode/setupCommands are ignored)
			dap.adapters.lldb = dap.adapters.codelldb
			dap.adapters.cppdbg = dap.adapters.codelldb

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
			dap.configurations.c = dap.configurations.cpp

			if not has_codelldb then
				vim.notify(
					"codelldb not found. Retry the exact tool manifest with :MasonToolsInstallSync",
					vim.log.levels.WARN,
					{ title = "DAP" }
				)
			end
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
