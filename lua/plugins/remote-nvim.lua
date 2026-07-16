-- Remote development, VSCode Remote-SSH style: launches a headless Neovim on the
-- remote host and connects a local TUI, syncing this config to the remote.
--
-- Local deps:  ssh, curl, nvim (devpod >= 0.5.0 optional, for devcontainers).
-- Remote deps: SSH server, bash, curl/wget, GitHub connectivity (unless offline).
--
-- Hosts come from ~/.ssh/config. The whole config is copied to the remote, so
-- mason re-installs servers/tools there on first start. ~/.nvim-local.lua lives
-- in $HOME (outside the copied config), so each remote host keeps its own local
-- settings (see config.local_config).
--
-- Commands: :RemoteStart :RemoteStop :RemoteInfo :RemoteCleanup
--           :RemoteConfigDel :RemoteLog   (also in :Cheatsheet commands)
-- Keymaps:  <leader>R… — Rs start, Rx stop, Ri info, Rc cleanup,
--           Rd config-del, Rl log (grouped as "remote" in which-key).
-- Health:   :checkhealth remote-nvim
-- Usage:    see docs/remote-nvim.md
return {
	"amitds1997/remote-nvim.nvim",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "RemoteStart", "RemoteStop", "RemoteInfo", "RemoteCleanup", "RemoteConfigDel", "RemoteLog" },
	keys = {
		{ "<leader>Rs", "<cmd>RemoteStart<cr>", desc = "Remote: iniciar / conectar a host" },
		{ "<leader>Rx", "<cmd>RemoteStop<cr>", desc = "Remote: detener sesión" },
		{ "<leader>Ri", "<cmd>RemoteInfo<cr>", desc = "Remote: info de sesión" },
		{ "<leader>Rc", "<cmd>RemoteCleanup<cr>", desc = "Remote: limpiar host remoto" },
		{ "<leader>Rd", "<cmd>RemoteConfigDel<cr>", desc = "Remote: borrar config guardada" },
		{ "<leader>Rl", "<cmd>RemoteLog<cr>", desc = "Remote: ver log" },
	},
	dependencies = {
		"nvim-lua/plenary.nvim",
		"MunifTanjim/nui.nvim",
		"nvim-telescope/telescope.nvim",
	},
	config = function()
		require("remote-nvim").setup({
			-- Source remote hosts from your personal ~/.ssh/config only.
			ssh_config = {
				ssh_config_file_paths = { vim.fn.expand("~/.ssh/config") },
			},
			-- Devcontainers run through devpod (needs `devpod` >= 0.5.0 and a
			-- container runtime, e.g. OrbStack/Docker). See docs/remote-nvim.md.
			devpod = {
				-- List stopped containers too, so reconnecting to an existing
				-- devcontainer doesn't force a rebuild.
				container_list = "all",
			},
		})
	end,
}
