return {
	"mfussenegger/nvim-dap",
	cmd = { "DapContinue", "DapToggleBreakpoint", "DapStepOver", "DapStepInto", "DapStepOut", "DapTerminate" },
	cond = function()
		return not vim.g.vscode
	end,
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
				require("dapui").toggle()
			end,
			desc = "Debug: Toggle UI",
		},
	},
	dependencies = {
		"nvim-neotest/nvim-nio",
		"rcarriga/nvim-dap-ui",
		"mfussenegger/nvim-dap-python",
		"leoluz/nvim-dap-go",
	},
	config = function()
		local dap = require("dap")
		local dapui = require("dapui")

		dapui.setup()

		-- Open/close the UI with the session (the VSCode-familiar behavior)
		dap.listeners.after.event_initialized["dapui_config"] = function()
			dapui.open()
		end
		dap.listeners.before.event_terminated["dapui_config"] = function()
			dapui.close()
		end
		dap.listeners.before.event_exited["dapui_config"] = function()
			dapui.close()
		end

		-- Python debugging
		require("dap-python").setup("python")

		-- Go debugging (delve from Mason; also handles launch.json type "go")
		require("dap-go").setup()

		-- C/C++ debugging with codelldb from Mason
		local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
		local codelldb_path = mason_bin .. "codelldb"

		if vim.fn.executable(codelldb_path) == 1 then
			-- codelldb speaks DAP over a TCP port, not stdio
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
			dap.configurations.rust = dap.configurations.cpp
		else
			vim.notify("codelldb not found. Install with :MasonInstall codelldb", vim.log.levels.WARN)
		end
	end,
}
