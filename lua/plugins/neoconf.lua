-- Neoconf remains the UI and global-settings backend. Project files are read
-- only by config.project_settings after explicit fingerprint approval.
return {
	"folke/neoconf.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		live_reload = false,
		local_settings = {},
		import = {
			vscode = false,
			coc = false,
			nlsp = false,
		},
		plugins = {
			lspconfig = { enabled = false },
			jsonls = { enabled = false },
			lua_ls = { enabled = false },
		},
	},
}
