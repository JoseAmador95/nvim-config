-- Claude subscription support through an ACP child process. Credentials are
-- resolved from local config and passed only to that child, never vim.env.

local acp_package = "@agentclientprotocol/claude-agent-acp@" .. require("config.toolchain").versions.claude_acp

local function copy_argv(argv)
	local copy = {}
	for index, value in ipairs(argv or {}) do
		copy[index] = value
	end
	return copy
end

local function resolve_acp_command()
	local config = require("config.local_config").get("codecompanion", {}) or {}
	if type(config.acp_command) == "table" and #config.acp_command > 0 then
		return copy_argv(config.acp_command)
	end

	local executable = require("config.tool_paths").external_executable("claude-agent-acp")
	if executable then
		return { executable }
	end
	return { "npx", "--yes", acp_package }
end

local function yolo_command(command)
	local argv = copy_argv(command)
	for _, argument in ipairs(argv) do
		if argument == "--yolo" then
			return argv
		end
	end
	argv[#argv + 1] = "--yolo"
	return argv
end

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
						local command = resolve_acp_command()
						return require("codecompanion.adapters").extend("claude_code", {
							commands = {
								default = command,
								yolo = yolo_command(command),
							},
							env = {
								CLAUDE_CODE_OAUTH_TOKEN = token,
							},
							handlers = {
								-- Upstream's handler exports the token into vim.env. The child
								-- already receives adapter.env, so only validate that value.
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
			local command = resolve_acp_command()
			if not command[1] or vim.fn.executable(command[1]) ~= 1 then
				vim.notify(
					("CodeCompanion: ACP command `%s` is not executable; configure codecompanion.acp_command."):format(
						tostring(command[1] or "")
					),
					vim.log.levels.WARN,
					{ title = "codecompanion" }
				)
			end
			require("codecompanion").setup(opts)
		end,
	},
}
