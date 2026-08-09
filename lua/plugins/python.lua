return {
	"linux-cultist/venv-selector.nvim",
	commit = "cc4bb3975de8835291f9bb45889e96c6b2795fc4",
	cmd = { "VenvSelect", "VenvSelectCached" },
	ft = "python",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "folke/snacks.nvim" },
	opts = {
		-- A non-empty no-op hook prevents venv-selector's default LSP restart
		-- hook. config.python owns the root-scoped Pyright restart; Ruff stays
		-- attached and untouched.
		hooks = {
			function()
				return 0
			end,
		},
		options = {
			picker = "snacks",
			cached_venv_automatic_activation = false,
			activate_venv_in_terminal = false,
			set_environment_variables = false,
			override_notify = false,
			notify_user_on_venv_activation = false,
			on_venv_activate_callback = function()
				vim.schedule(function()
					require("config.python").refresh_current()
				end)
			end,
		},
	},
	config = function(_, opts)
		require("venv-selector").setup(opts)
		require("config.python").setup()
	end,
}
