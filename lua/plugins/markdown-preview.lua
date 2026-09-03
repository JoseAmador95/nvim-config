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
			local ok_bootstrap, bootstrap = deferred.try("config.tool_bootstrap")
			local ok_repair, repair = deferred.try("verified_tools.markdown_preview")
			if not ok_bootstrap or not ok_repair then
				return
			end
			for _, record in ipairs(bootstrap.engine().records() or {}) do
				if record.identity and record.identity.name == "markdown-preview" and record.status == "succeeded" then
					repair.repair(plugin.dir, record)
					break
				end
			end
		end,
		keys = {
			{ "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", desc = "Markdown preview" },
		},
	},
}
