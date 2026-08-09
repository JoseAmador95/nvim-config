vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local original_editor = package.loaded["config.editor"]
local original_schedule = vim.schedule
local opened = {}
package.loaded["config.editor"] = {
	open_file_in_tab = function(path, position)
		opened[#opened + 1] = { path = path, position = position }
	end,
}
vim.schedule = function(callback)
	callback()
end

local spec = require("plugins.trouble")
local item = { filename = repo .. "/AGENTS.md", pos = { 12, 3 } }
spec.opts.keys["<cr>"](nil, { item = item })
spec.opts.keys["<2-leftmouse>"](nil, { item = item })
assert(#opened == 2, "enter and double click did not use shared navigation")
for _, call in ipairs(opened) do
	assert(call.path == item.filename and call.position.lnum == 12 and call.position.col == 4)
end

local closed = 0
spec.opts.keys.o({
	close = function()
		closed = closed + 1
	end,
}, { item = item })
assert(closed == 1 and #opened == 3, "o did not close Trouble after capturing the target")

for _, name in ipairs({
	"lsp_definitions",
	"lsp_declarations",
	"lsp_implementations",
	"lsp_references",
	"lsp_type_definitions",
}) do
	assert(spec.opts.modes[name].auto_jump == false, name .. " still auto-jumps a single result")
end

package.loaded["config.editor"] = original_editor
vim.schedule = original_schedule
print("trouble_spec: tab-aware open actions passed")
vim.cmd("quitall!")
