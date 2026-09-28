vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local original_editor = package.loaded["config.editor"]
local opened = {}
package.loaded["config.editor"] = {
	open_file_in_tab = function(path, options)
		opened[#opened + 1] = { path = path, options = vim.deepcopy(options) }
	end,
}
package.loaded["config.editor_actions"] = nil
local actions = require("config.editor_actions")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
	"src/first.lua:10:2: diagnostic",
	"(src/wrapped.lua:12:3),",
	"one.lua:1:2 two.lua:30:4",
	"plain.lua",
	'"quoted.lua:40:6",',
	"`backtick.lua:50:7`",
	"",
})

local function open_at(line, column, expected_path, expected_line, expected_column)
	vim.api.nvim_win_set_cursor(0, { line, column })
	assert(actions.open_file_under_cursor())
	local result = opened[#opened]
	assert(result.path == expected_path, vim.inspect(result))
	assert(result.options.lnum == expected_line and result.options.col == expected_column, vim.inspect(result))
end

open_at(1, 4, "src/first.lua", 10, 2)
open_at(1, 17, "src/first.lua", 10, 2)
open_at(2, 5, "src/wrapped.lua", 12, 3)
open_at(3, 18, "two.lua", 30, 4)
open_at(4, 3, "plain.lua", 1, 1)
open_at(5, 4, "quoted.lua", 40, 6)
open_at(6, 4, "backtick.lua", 50, 7)

vim.api.nvim_win_set_cursor(0, { 7, 0 })
local ok, err = actions.open_file_under_cursor()
assert(not ok and err:find("No file under cursor", 1, true), tostring(err))
assert(#opened == 7, "missing file token still opened a path")

vim.api.nvim_buf_delete(buf, { force = true })
package.loaded["config.editor_actions"] = nil
package.loaded["config.editor"] = original_editor

print("editor_actions_spec: location tokens and missing targets passed")
vim.cmd("quitall!")
