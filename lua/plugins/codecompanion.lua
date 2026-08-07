-- AI assistant using the Claude subscription (no API key).
--
-- CodeCompanion talks to Claude through the `claude_code` ACP adapter, which
-- authenticates with an OAuth token from `claude setup-token`. Store the token
-- in ~/.nvim-local.lua as codecompanion.oauth_token (see config.local_config).
-- The credential is passed only to the ACP child process and is never exported
-- to Neovim's process environment.
--
-- External dep: Node with `npx`. The Zed ACP adapter
-- (@agentclientprotocol/claude-agent-acp) is fetched and cached automatically
-- by npx on first use, so there is no manual `npm install -g` step.
local acp_package = "@agentclientprotocol/claude-agent-acp@" .. require("config.toolchain").versions.claude_acp

return {
	{
		"olimorris/codecompanion.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		dependencies = {
			"nvim-lua/plenary.nvim",
			"nvim-treesitter/nvim-treesitter",
		},
		cmd = {
			"CodeCompanion",
			"CodeCompanionChat",
			"CodeCompanionActions",
			"CodeCompanionCmd",
		},
		keys = {
			{ "<leader>aa", "<cmd>CodeCompanionActions<cr>", mode = { "n", "v" }, desc = "AI actions" },
			{ "<leader>ac", "<cmd>CodeCompanionChat Toggle<cr>", mode = { "n", "v" }, desc = "AI chat toggle" },
			{ "<leader>ai", "<cmd>CodeCompanion<cr>", mode = { "n", "v" }, desc = "AI inline prompt" },
			{ "<leader>ax", "<cmd>CodeCompanionChat Add<cr>", mode = "v", desc = "AI add selection to chat" },
		},
		opts = {
			adapters = {
				acp = {
					claude_code = function()
						local token = require("config.local_config").codecompanion_oauth_token()
						return require("codecompanion.adapters").extend("claude_code", {
							-- Run the ACP adapter through npx so it auto-installs and
							-- caches this reviewed version on first use.
							commands = {
								default = { "npx", "--yes", acp_package },
								yolo = {
									"npx",
									"--yes",
									acp_package,
									"--yolo",
								},
							},
							env = {
								CLAUDE_CODE_OAUTH_TOKEN = token,
							},
							handlers = {
								-- Upstream's handler copies the token into vim.env. The ACP
								-- process already receives adapter.env, so authentication only
								-- needs to confirm that the child credential was resolved.
								auth = function(self)
									local child_token = self.env_replaced and self.env_replaced.CLAUDE_CODE_OAUTH_TOKEN
									return child_token ~= nil and child_token ~= ""
								end,
							},
						})
					end,
				},
			},
			interactions = {
				chat = { adapter = "claude_code" },
				inline = { adapter = "claude_code" },
			},
		},
		config = function(_, opts)
			if not require("config.local_config").codecompanion_oauth_token() then
				vim.notify(
					"CodeCompanion: set codecompanion.oauth_token in ~/.nvim-local.lua "
						.. "(run `claude setup-token`) to enable the Claude subscription adapter.",
					vim.log.levels.WARN,
					{ title = "codecompanion" }
				)
			end
			if vim.fn.executable("npx") ~= 1 then
				vim.notify(
					"CodeCompanion: `npx` (Node.js) not found in PATH; the Claude ACP adapter cannot start.",
					vim.log.levels.WARN,
					{ title = "codecompanion" }
				)
			end
			require("codecompanion").setup(opts)
		end,
	},
}
