return {
	"MeanderingProgrammer/render-markdown.nvim",
	ft = "markdown",
	cond = function()
		return not vim.g.vscode
	end,
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	opts = {},
	config = function()
		require("render-markdown").setup({ render_modes = true })

		-- render-markdown defaults lean dark; override the groups that read
		-- worst on a light background and hand control back to its generated
		-- colors when dark. Applied on every ColorScheme so the overrides
		-- survive theme reapplies (including the background-follow reapply in
		-- colorscheme.lua).
		local function apply_overrides()
			local set = vim.api.nvim_set_hl
			if vim.o.background == "light" then
				set(0, "RenderMarkdownCode", { bg = "#e8e8e8" })
				set(0, "RenderMarkdownCodeInline", { bg = "#e0e0e0", fg = "#383838" })
				set(0, "RenderMarkdownH1Bg", { bg = "#d6e4f0" })
				set(0, "RenderMarkdownH2Bg", { bg = "#dceadb" })
				set(0, "RenderMarkdownH3Bg", { bg = "#f0e6cc" })
				set(0, "RenderMarkdownH4Bg", { bg = "#ead9e6" })
				set(0, "RenderMarkdownH5Bg", { bg = "#dce6ea" })
				set(0, "RenderMarkdownH6Bg", { bg = "#e2e2e2" })
			else
				set(0, "RenderMarkdownCode", { link = "ColorColumn" })
				set(0, "RenderMarkdownCodeInline", { link = "RenderMarkdownCode" })
				for i = 1, 6 do
					set(0, "RenderMarkdownH" .. i .. "Bg", { link = "RenderMarkdownH" .. i })
				end
			end
		end

		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("RenderMarkdownBgFollow", { clear = true }),
			callback = apply_overrides,
		})
		apply_overrides()

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
