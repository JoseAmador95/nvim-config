local deferred = require("config.deferred")

return {
	{
		"iamcco/markdown-preview.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "MarkdownPreview", "MarkdownPreviewStop", "MarkdownPreviewToggle" },
		init = function()
			vim.g.mkdp_filetypes = { "markdown" }
			vim.g.mkdp_preview_options = {
				uml = {},
				maid = {},
				disable_sync_scroll = 0,
				sync_scroll_type = "middle",
			}
		end,
		config = function(plugin)
			local ok, err = deferred.load("config.tool_bootstrap").markdown_preview(plugin.dir)
			assert(ok, err)
		end,
		keys = {
			{ "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", desc = "Markdown preview" },
		},
	},
}
