return {
	{
		"iamcco/markdown-preview.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		ft = { "markdown" },
		cmd = { "MarkdownPreview", "MarkdownPreviewStop", "MarkdownPreviewToggle" },
		build = function()
			local root = vim.fn.stdpath("data") .. "/lazy/markdown-preview.nvim"
			local app_dir = root .. "/app"
			local version

			local ok, lines = pcall(vim.fn.readfile, root .. "/package.json")
			if ok and lines and #lines > 0 then
				local ok_json, pkg = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
				if ok_json and type(pkg) == "table" and pkg.version then
					version = "v" .. tostring(pkg.version)
				end
			end

			local cmd = "cd " .. vim.fn.shellescape(app_dir) .. " && ./install.sh"
			if version then
				cmd = cmd .. " " .. version
			end

			local output = vim.fn.system({ "bash", "-lc", cmd })
			if vim.v.shell_error ~= 0 then
				vim.notify("markdown-preview build failed: " .. output, vim.log.levels.ERROR)
			end
		end,
		init = function()
			vim.g.mkdp_filetypes = { "markdown" }
			vim.g.mkdp_preview_options = {
				uml = {},
				maid = {},
				disable_sync_scroll = 0,
				sync_scroll_type = "middle",
			}
		end,
		keys = {
			{ "<leader>mp", "<cmd>MarkdownPreviewToggle<cr>", desc = "Markdown preview" },
		},
	},
}
