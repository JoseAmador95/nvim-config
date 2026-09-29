vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local codeblocks = require("config.markdown_codeblocks")
local palette = require("config.palette")

vim.o.background = "light"
vim.api.nvim_set_hl(0, "Normal", { bg = 0xffffff, fg = 0x1f2328 })
vim.api.nvim_set_hl(0, "String", { fg = 0xa31515 })
palette.apply_markdown()

local buf = vim.api.nvim_create_buf(false, true)
local first_lines = {
	"    local value = 1",
	"    print(value)",
	"",
	"    frontmatter value",
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, first_lines)

local session = {
	buf = buf,
	opts = { nvim_config_page_margin = 4, nvim_config_page_width = 32 },
	content = {
		lines = first_lines,
		highlights = {
			{ line = 0, groups = { { col = 4, hl = "String" } } },
			{ line = 1, groups = { { col = 4, hl = "String" } } },
			{ line = 3, groups = { { col = 4, hl = "String" } } },
		},
		code_blocks = { { language = "lua\27[31m ignored", start_line = 0, end_line = 1, prefix_len = 4 } },
	},
}

local namespace = assert(vim.api.nvim_get_namespaces().nvim_config_markdown_codeblocks)

local function marks()
	return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
end

local function find(row, predicate)
	for _, mark in ipairs(marks()) do
		if mark[2] == row and predicate(mark[4]) then
			return mark
		end
	end
	return nil
end

codeblocks.decorate(session)
local first_background = assert(
	find(0, function(details)
		return details.hl_group == "MdRenderCodeBlockBackground"
	end),
	"code text has no bounded background"
)
assert(first_background[3] == 4 and first_background[4].end_col == #first_lines[1], "background shades a side margin")
assert(not first_background[4].hl_eol and not first_background[4].line_hl_group, "background fills the window")
local padding = assert(
	find(0, function(details)
		return details.virt_text ~= nil
	end),
	"code line has no shaded padding"
)
assert(#padding[4].virt_text[1][1] == 36 - vim.fn.strdisplaywidth(first_lines[1]), "code region width is wrong")
assert(padding[4].virt_text_pos == "inline", "code background leaves a gap after the final character")
assert(not find(3, function(details)
	return details.hl_group == "MdRenderCodeBlockBackground"
end), "non-code String content gained a code background")
local label = assert(
	find(0, function(details)
		return details.virt_lines ~= nil
	end),
	"language label is absent"
)
assert(label[4].virt_lines_above == true, "language label is not above its code block")
assert(label[4].virt_lines[1][2][1] == " lua ", "language label includes unsafe fence text")
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == first_lines[1], "decoration changed rendered text")

local rebuilt_lines = { "    print('new')", "ordinary text" }
session.rebuild = function(self)
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, rebuilt_lines)
	self.content = {
		lines = rebuilt_lines,
		highlights = { { line = 0, groups = { { col = 4, hl = "String" } } } },
		code_blocks = { { language = "python", start_line = 0, end_line = 0, prefix_len = 4 } },
	}
end
codeblocks.protect_rebuild(session)
codeblocks.protect_rebuild(session)
session:rebuild()
local rebuilt_label = assert(
	find(0, function(details)
		return details.virt_lines ~= nil
	end),
	"rebuild lost language label"
)
assert(rebuilt_label[4].virt_lines[1][2][1] == " python ", "rebuild kept a stale language label")
assert(not find(3, function(details)
	return details.hl_group == "MdRenderCodeBlockBackground"
end), "rebuild kept a stale code background")

print("markdown_codeblocks_spec: labels and bounded code backgrounds passed")
vim.cmd("quitall!")
