return {
	{
		"iamcco/markdown-preview.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "MarkdownPreview", "MarkdownPreviewStop", "MarkdownPreviewToggle" },
		init = function(plugin)
			vim.g.mkdp_filetypes = { "markdown" }
			vim.g.mkdp_preview_options = {
				uml = {},
				maid = {},
				disable_sync_scroll = 0,
				sync_scroll_type = "middle",
			}

			local ok_bootstrap, bootstrap = pcall(require, "config.tool_bootstrap")
			local ok_repair, repair = pcall(require, "verified_tools.markdown_preview")
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
