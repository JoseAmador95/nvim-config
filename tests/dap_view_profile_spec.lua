local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

T["dap view profile"] = function()
	require("lazy").load({ plugins = { "nvim-dap" } })

	assert(package.loaded["dap-view"], "dap-view module was not loaded")
	assert(package.loaded.dapui == nil, "dap-ui loaded alongside dap-view")
	for _, command in ipairs({ "DapViewOpen", "DapViewClose", "DapViewToggle", "DapViewWatch" }) do
		assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
	end

	local dap = require("dap")
	assert(dap.defaults.fallback.switchbuf == "usevisible,usetab,newtab")
	assert(type(dap.listeners.after.event_initialized.nvim_config_dap_ui) == "function")
	assert(type(dap.listeners.on_session.nvim_config_dap_ui) == "function")
	assert(dap.listeners.after.event_initialized.dapui_config == nil, "legacy dap-ui listener remains")
end
return T
