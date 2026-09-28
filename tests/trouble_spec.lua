vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local original_editor = package.loaded["config.editor"]
local original_item = package.loaded["trouble.item"]
local original_review_source = package.loaded["trouble.sources.review"]
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

package.loaded["trouble.item"] = {
	new = function(value)
		return value
	end,
}
package.loaded["trouble.sources.review"] = nil
local review_source = require("trouble.sources.review")
local review_items
review_source.get(function(items)
	review_items = items
end)
assert(vim.deep_equal(review_items, {}), "inactive review source did not return an empty Trouble result")
assert(package.loaded["config.native_review"] == nil, "Trouble activated the native review runtime")
for name in pairs(package.loaded) do
	assert(
		name ~= "native_review" and name:sub(1, #"native_review.") ~= "native_review.",
		name .. " crossed the review boundary while Trouble was observed"
	)
end

package.loaded["config.native_review"] = {
	controller = {
		snapshot = function()
			return {
				root = repo,
				items = {
					{
						id = "custom-1",
						type = "custom",
						status = "open",
						body = "body",
						anchor = { kind = "file", path = "README.md" },
					},
				},
			}
		end,
	},
	comment_types = {
		get = function(id)
			assert(id == "custom")
			return { severity = vim.diagnostic.severity.WARN }
		end,
	},
}
review_source.get(function(items)
	review_items = items
end)
assert(
	#review_items == 1 and review_items[1].severity == vim.diagnostic.severity.WARN,
	"custom review type severity was lost"
)
package.loaded["config.native_review"] = nil

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
package.loaded["trouble.item"] = original_item
package.loaded["trouble.sources.review"] = original_review_source
vim.schedule = original_schedule
print("trouble_spec: lazy review source and tab-aware open actions passed")
vim.cmd("quitall!")
