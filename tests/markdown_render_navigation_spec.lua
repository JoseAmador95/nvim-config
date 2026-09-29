vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local opened = {}
package.loaded["config.editor"] = {
	open_file_in_tab = function(path)
		opened[#opened + 1] = path
	end,
}

local pager = require("config.pager")
local markdown_navigation = require("config.markdown_navigation")
local render_navigation = require("config.markdown_render_navigation")

local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p", 448) == 1)
local readme = vim.fs.joinpath(root, "README.md")
local guide = vim.fs.joinpath(root, "guide.md")
assert(vim.fn.writefile({ "# Guide" }, guide) == 0)

local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source, readme)
local source_lines = {
	"# Local",
	"[doc](guide.md) [section](guide.md#part) [ref][guide]",
	"[local](#local)",
}
vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
vim.bo[source].filetype = "markdown"

local allowed = true
local marksman = {}
markdown_navigation.setup({
	allowed = function()
		return allowed
	end,
	definition = function()
		return false
	end,
	marksman = function(bufnr, line, column)
		marksman[#marksman + 1] = { bufnr, line, column }
		return true
	end,
})

local render = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(render, 0, -1, false, {
	"    # Local",
	"    doc section ref",
	"    local",
})
vim.bo[render].filetype = "md-render"
vim.b[render].md_render = true
vim.api.nvim_set_current_buf(render)
local session = {
	buf = render,
	source_bufnr = source,
	content = {
		link_metadata = {
			{ line = 1, col_start = 4, col_end = 7, url = "guide.md" },
			{ line = 1, col_start = 8, col_end = 15, url = "guide.md#part" },
			{ line = 1, col_start = 16, col_end = 19, url = "guide.md#ref" },
			{ line = 2, col_start = 4, col_end = 9, url = "#local" },
		},
		source_line_map = { 1, 2, 3 },
		heading_anchors = { ["local"] = 0 },
	},
}

assert(render_navigation.attach(session), "rendered gd mapping did not attach")
local mapping = vim.fn.maparg("gd", "n", false, true)
assert(mapping.desc == "Open rendered Markdown link", "rendered gd mapping is missing")

vim.api.nvim_win_set_cursor(0, { 2, 5 })
assert(render_navigation.follow(session), "relative file link was not followed")
assert(
	vim.uv.fs_realpath(opened[1]) == vim.uv.fs_realpath(guide),
	"relative file did not use the source directory: " .. tostring(opened[1])
)

vim.api.nvim_win_set_cursor(0, { 2, 10 })
assert(render_navigation.follow(session), "file fragment was not sent to Marksman")
local fragment_at = assert(source_lines[2]:find("guide.md#part", 1, true))
assert(vim.deep_equal(marksman[1], { source, 2, fragment_at }), "fragment lost its source position")

vim.api.nvim_win_set_cursor(0, { 2, 17 })
assert(render_navigation.follow(session), "reference link was not sent to Marksman")
local reference_at = assert(source_lines[2]:find("ref", 1, true))
assert(vim.deep_equal(marksman[2], { source, 2, reference_at }), "reference lost its source label")

vim.api.nvim_win_set_cursor(0, { 3, 5 })
assert(render_navigation.follow(session), "local heading link was not followed in the render")
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 4 }), "heading jump left the reading view")

allowed = false
vim.api.nvim_win_set_cursor(0, { 3, 5 })
assert(not render_navigation.follow(session), "blocked source escaped through a local anchor")
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 5 }), "blocked anchor moved the cursor")
allowed = true

vim.api.nvim_win_set_cursor(0, { 1, 5 })
assert(not render_navigation.follow(session), "plain text became a link")
pager.active = true
assert(not render_navigation.attach(session), "editor navigation leaked into the pager")
pager.active = false

vim.fn.delete(root, "rf")
print("markdown_render_navigation_spec: passed")
