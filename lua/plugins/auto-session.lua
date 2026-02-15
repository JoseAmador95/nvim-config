return {
	"rmagatti/auto-session",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		log_level = "error",
		auto_restore = true,
		auto_save = true,
		auto_create = true,
		auto_restore_last_session = false,
		show_auto_restore_notif = false,
		bypass_save_filetypes = { "neo-tree" },
	},
	config = function(_, opts)
		vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"
		require("auto-session").setup(opts)
	end,
}
