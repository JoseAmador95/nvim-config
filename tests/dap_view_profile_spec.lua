vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("dap_view_profile_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(vim.env.NVIM_DAP_UI == "dap-view", "test did not start with the dap-view override")
				assert(require("config.dap_ui").selected() == "dap-view", "environment override was not selected")
				require("lazy").load({ plugins = { "nvim-dap" } })

				assert(package.loaded["dap-view"], "selected dap-view module was not loaded")
				assert(package.loaded.dapui == nil, "dap-ui loaded alongside dap-view")
				for _, command in ipairs({ "DapViewOpen", "DapViewClose", "DapViewToggle", "DapViewWatch" }) do
					assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
				end

				local dap = require("dap")
				assert(dap.defaults.fallback.switchbuf == "usevisible,usetab,newtab")
				assert(type(dap.listeners.after.event_initialized.nvim_config_dap_ui) == "function")
				assert(type(dap.listeners.before.event_terminated.nvim_config_dap_ui) == "function")
				assert(type(dap.listeners.before.event_exited.nvim_config_dap_ui) == "function")
				assert(dap.listeners.after.event_initialized.dapui_config == nil, "legacy dap-ui listener remains")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			print("dap_view_profile_spec: 1 test passed")
			vim.cmd("quitall!")
		end)
	end,
})
