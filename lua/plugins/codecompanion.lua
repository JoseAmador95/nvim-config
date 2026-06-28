-- AI assistant using the Claude subscription (no API key).
--
-- CodeCompanion talks to Claude through the `claude_code` ACP adapter, which
-- authenticates with an OAuth token from `claude setup-token`. Store the token
-- in ~/.nvim-local.lua as env.CLAUDE_CODE_OAUTH_TOKEN (see config.local_config);
-- it is exported early by apply_env, before this plugin loads.
--
-- External dep: Node with `npx`. The Zed ACP adapter
-- (@zed-industries/claude-agent-acp) is fetched and cached automatically by npx
-- on first use, so there is no manual `npm install -g` step.
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
						return require("codecompanion.adapters").extend("claude_code", {
							-- Run the ACP adapter through npx so it auto-installs and
							-- caches on first use (no global npm install needed).
							commands = {
								default = { "npx", "-y", "@zed-industries/claude-agent-acp" },
								yolo = { "npx", "-y", "@zed-industries/claude-agent-acp", "--yolo" },
							},
							env = {
								CLAUDE_CODE_OAUTH_TOKEN = vim.env.CLAUDE_CODE_OAUTH_TOKEN,
							},
						})
					end,
				},
			},
			strategies = {
				chat = { adapter = "claude_code" },
				inline = { adapter = "claude_code" },
			},
		},
		config = function(_, opts)
			if not vim.env.CLAUDE_CODE_OAUTH_TOKEN or vim.env.CLAUDE_CODE_OAUTH_TOKEN == "" then
				vim.notify(
					"CodeCompanion: set env.CLAUDE_CODE_OAUTH_TOKEN in ~/.nvim-local.lua "
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
