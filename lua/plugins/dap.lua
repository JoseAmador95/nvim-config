return {
  "mfussenegger/nvim-dap",
  cmd = { "DapContinue", "DapToggleBreakpoint", "DapStepOver", "DapStepInto", "DapStepOut", "DapTerminate" },
  cond = function() return not vim.g.vscode end,
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

    -- Keymaps
    vim.keymap.set("n", "<F5>", function() dap.continue() end, { desc = "Debug: Continue" })
    vim.keymap.set("n", "<F10>", function() dap.step_over() end, { desc = "Debug: Step over" })
    vim.keymap.set("n", "<F11>", function() dap.step_into() end, { desc = "Debug: Step into" })
    vim.keymap.set("n", "<F12>", function() dap.step_out() end, { desc = "Debug: Step out" })
    vim.keymap.set("n", "<leader>db", function() dap.toggle_breakpoint() end, { desc = "Debug: Toggle breakpoint" })
    vim.keymap.set("n", "<leader>du", function() dapui.toggle() end, { desc = "Debug: Toggle UI" })

    vim.notify("DAP ready", vim.log.levels.INFO, { title = "Debug" })
  end,
}
