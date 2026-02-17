return {
	"MeanderingProgrammer/render-markdown.nvim",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	opts = {},
	config = function()
		require("render-markdown").setup({})
		vim.api.nvim_create_user_command("MarkdownRender", function(opts)
			local args = vim.trim(opts.args or "")
			if args == "" then
				require("render-markdown").toggle()
				return
			end
			vim.cmd("RenderMarkdown " .. args)
		end, {
			nargs = "?",
			complete = function(arglead)
				local items = {
					"enable",
					"disable",
					"toggle",
					"buf_enable",
					"buf_disable",
					"buf_toggle",
					"preview",
					"log",
					"expand",
					"contract",
					"debug",
					"config",
					"set",
					"set_buf",
					"get",
				}
				if arglead == "" then
					return items
				end
				local matches = {}
				for _, item in ipairs(items) do
					if vim.startswith(item, arglead) then
						matches[#matches + 1] = item
					end
				end
				return matches
			end,
			desc = "Render markdown (in buffer)",
		})
	end,
}
