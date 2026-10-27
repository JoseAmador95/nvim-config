local MiniTest = require("mini.test")
local helpers = require("tests.helpers")
local child = MiniTest.new_child_neovim()
local root = vim.fn.getcwd()
local source_root = vim.env.NVIM_CONFIG_SCREENSHOT_SOURCE or root
assert(
	source_root == root or vim.env.NVIM_CONFIG_UPDATE_SCREENSHOTS == "1",
	"alternate renderer sources are only for baseline capture"
)
local engine = vim.env.NVIM_CONFIG_MD_RENDER_ROOT or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "md-render.nvim")
local T = MiniTest.new_set({ hooks = { post_case = child.stop } })

T["reading view"] = MiniTest.new_set({ parametrize = { { 48, true }, { 140, true }, { 80, false } } })
T["reading view"]["headings tables and code preserve screen geometry"] = function(width, wrapped)
	child.start({ "-u", "NONE", "-i", "NONE" })
	child.lua_func(function(runtime, plugin, columns, wrap)
		vim.opt.runtimepath:prepend(runtime)
		vim.opt.runtimepath:prepend(runtime .. "/local-plugins/markdown-view.nvim")
		vim.opt.runtimepath:prepend(plugin)
		vim.opt.runtimepath:prepend(vim.fs.dirname(plugin) .. "/nvim-treesitter/runtime")
		require("config.local_plugins").setup()
		vim.o.lines, vim.o.columns = 36, columns
		vim.o.laststatus, vim.o.showtabline, vim.o.cmdheight = 0, 0, 1
		vim.o.number, vim.o.relativenumber = false, false
		vim.o.signcolumn = "no"
		vim.o.swapfile, vim.o.showmode = false, false
		vim.o.background = "light"
		vim.api.nvim_set_hl(0, "Normal", { fg = 0x202020, bg = 0xffffff })
		local view = require("config.markdown_view")
		assert(view.configure_renderer())
		require("config.markdown_images")._reset({ supported = false })
		view.setup()
		vim.bo.filetype = "markdown"
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {
			"# Reading page",
			"",
			"A **bold** paragraph with Unicode 漢字 and a [link](https://example.invalid).",
			"",
			"| Key | Value |",
			"| --- | --- |",
			"| 漢字 | https://example.invalid/complete/unbroken/table/cell |",
			"",
			"```lua",
			"local value = 1",
			"return 'Complete code extends across the page ................................'",
			"```",
			"",
			"> [!NOTE]",
			"> The source stays editable.",
			"",
			"## Final heading",
			"The end.",
		})
		view.toggle()
		view.set_wrap(wrap)
		vim.cmd("normal! gg0")
	end, source_root, engine, width, wrapped)
	helpers.screenshot(
		child.get_screenshot(),
		root .. "/tests/screenshots/markdown-" .. width .. "-" .. tostring(wrapped)
	)
end

return T
