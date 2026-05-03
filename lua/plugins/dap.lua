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
	},
	config = function()
		local dap = require("dap")
		local dapui = require("dapui")

		dapui.setup()

		-- Python debugging
		require("dap-python").setup("python")

		-- C/C++ debugging with codelldb from Mason
		local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
		local codelldb_path = mason_bin .. "codelldb"

		if vim.fn.executable(codelldb_path) == 1 then
			dap.adapters.cppdbg = {
				type = "executable",
				command = codelldb_path,
				name = "cppdbg",
			}

			dap.configurations.cpp = {
				{
					name = "Launch file",
					type = "cppdbg",
					request = "launch",
					program = function()
						return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/", "file")
					end,
					cwd = "${workspaceFolder}",
					stopOnEntry = false,
				},
			}
			dap.configurations.c = dap.configurations.cpp
		else
			vim.notify("codelldb not found. Install with :MasonInstall codelldb", vim.log.levels.WARN)
		end

		vim.notify("DAP ready", vim.log.levels.INFO, { title = "Debug" })
	end,
}
