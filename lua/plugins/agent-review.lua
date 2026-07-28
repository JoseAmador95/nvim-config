-- lua/plugins/agent-review.lua
-- The agent-review workflow has no external plugin: the code lives in
-- lua/config/agent_review/. This spec exists so the feature is a first-class
-- lazy.nvim entry (visible in :Lazy, gated on VS Code like every other
-- terminal-only feature) and so nothing of it is paid for until a <leader>v key
-- or an :AgentReview* command is used.
--
-- `dir` points at the config itself, which is already on the runtimepath: the
-- spec installs nothing, it only carries the load triggers.
--
-- The keys below are declared without a right-hand side on purpose. They are
-- lazy triggers: the real mappings (with their descriptions) are owned by
-- config.agent_review.setup() and its siblings, so they are defined in exactly
-- one place.
return {
	{
		dir = vim.fn.stdpath("config"),
		name = "agent-review",
		cond = function()
			return not vim.g.vscode
		end,
		lazy = true,
		keys = {
			{ "<leader>vv", desc = "Agent review: dashboard" },
			{ "<leader>vs", desc = "Agent review: snapshot (arm the review)" },
			{ "<leader>vf", desc = "Agent review: machine pass (checks -> quickfix)" },
			{ "<leader>vy", desc = "Agent review: build the prompt for the agent" },
			{ "<leader>va", desc = "Agent review: accept hunk under cursor" },
			{ "<leader>vx", desc = "Agent review: reject hunk (mark only)" },
			{ "<leader>vc", desc = "Agent review: comment on hunk under cursor" },
			{ "]v", desc = "Agent review: next unreviewed hunk" },
			{ "[v", desc = "Agent review: previous unreviewed hunk" },
		},
		cmd = {
			"AgentReviewSnapshot",
			"AgentReviewReset",
			"AgentReviewDashboard",
			"AgentReviewNext",
			"AgentReviewPrev",
			"AgentReviewAccept",
			"AgentReviewReject",
			"AgentReviewComment",
			"AgentReviewPrompt",
			"AgentReviewCheck",
		},
		config = function()
			require("config.agent_review").setup()
		end,
	},
}
