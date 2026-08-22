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
		-- Replacing venv-selector's default hooks keeps restart ownership here.
		-- The hook's bufnr is the Python origin even while its picker has focus.
		hooks = {
			function(python_path, _, bufnr)
				require("config.python").refresh_current(bufnr, python_path)
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
		},
	},
	config = function(_, opts)
		require("venv-selector").setup(opts)
		-- The pinned plugin registers PEP 723 automation that runs `uv sync`
		-- merely by opening a script. Discovery here is read-only; retain the
		-- manual picker while removing that install-capable autocmd surface.
		vim.api.nvim_del_augroup_by_name("VenvSelectorUvDetect")
		require("config.python").setup()
	end,
}
