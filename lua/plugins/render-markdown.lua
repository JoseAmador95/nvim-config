local redraw_profile = require("config.redraw_profile")
local deferred = require("config.deferred")
local local_config = require("config.local_config")
local palette = require("config.palette")

local configured = local_config.plugin("render_markdown", { preset = "subtle" })

local function apply_palette()
	palette.apply_markdown(configured.preset)
end

local render_opts = { render_modes = true }
if redraw_profile.low_bandwidth() then
	render_opts = {
		render_modes = { "n" },
		anti_conceal = { enabled = false },
	}
end

return {
	"MeanderingProgrammer/render-markdown.nvim",
	-- Must register its FileType observer before the first event. Loading this
	-- eagerly also covers Markdown piped to nvimpager, which has no BufReadPre.
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	-- Lazy runs every init callback before sourcing any plugin. Registering the
	-- host palette here means it runs before render-markdown's own ColorScheme
	-- callback, so the plugin derives its cached border colors from our public
	-- highlight groups rather than from the previous colorscheme.
	init = function()
		if vim.g.vscode then
			return
		end
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("NvimConfigRenderMarkdownPalette", { clear = true }),
			callback = apply_palette,
			desc = "Repaint render-markdown from the active colorscheme",
		})
		apply_palette()
	end,
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	opts = render_opts,
	config = function(_, opts)
		local renderer = deferred.load("render-markdown")
		renderer.setup(opts)

		vim.api.nvim_create_user_command("MarkdownRender", function(opts)
			local args = vim.trim(opts.args or "")
			if args == "" then
				renderer.toggle()
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
