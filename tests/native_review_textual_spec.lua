vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")
require("config.local_plugins").setup()
local engines = require("config.native_review").engines
local projection = require("native_review.projection")
local moves = require("native_review.moves")

local T = MiniTest.new_set()
local function main(value)
	local result
	engines.prepare("main", value, function(prepared, err)
		result = assert(prepared, err)
	end)
	return assert(result)
end

local function entry(old, new, hunks)
	return {
		old_text = old,
		new_text = new,
		old_path = "sample.lua",
		new_path = "sample.lua",
		hunks = hunks or vim.text.diff(old, new, { result_type = "indices" }),
	}
end
local block = "local alpha = 1\nlocal beta = 2\nreturn alpha + beta\n"
local middle = "unchanged one\nunchanged two\nunchanged three\nunchanged four\nunchanged five\n"
local function exact(value)
	return moves.detect(assert(projection.build(value)))
end
T["unique exact moved blocks retain counterpart coordinates across hunks"] = function()
	local value = entry(block .. middle, middle .. block, { { 1, 3, 0, 0 }, { 8, 0, 6, 3 } })
	local original = vim.deepcopy(value)
	local result = main(value)
	assert(#result.relations == 1)
	local relation = result.relations[1]
	assert(relation.kind == "move" and relation.old.start_line == 1 and relation.old.end_line == 3)
	assert(relation.new.start_line == 6 and relation.new.end_line == 8)
	assert(vim.deep_equal(original, value))
end
T["repeated blocks are ambiguous and short fragments are omitted"] = function()
	assert(#exact(entry(block .. block, "replaced\n" .. block, { { 1, 6, 1, 4 } })) == 0)
	assert(#exact(entry("alpha beta\ngamma delta\n", "prefix\nalpha beta\ngamma delta\n", { { 1, 2, 1, 3 } })) == 0)
	assert(#exact(entry("a\nb\nc\n", "prefix\na\nb\nc\n", { { 1, 3, 1, 4 } })) == 0)
end
T["longest blocks win without overlapping suffix relations"] = function()
	local extended = block .. "local gamma = 3\n"
	local found = exact(entry(extended .. middle, middle .. extended, { { 1, 4, 0, 0 }, { 9, 0, 6, 4 } }))
	assert(#found == 1 and found[1].old.end_line == 4)
end
T["edited, CRLF, and final-newline changes are never exact moves"] = function()
	for _, modified in ipairs({ block:gsub("beta = 2", "beta = 3"), block:gsub("\n", "\r\n"), block:sub(1, -2) }) do
		assert(#exact(entry(block, modified, { { 1, 3, 1, 3 } })) == 0)
	end
end
T["binary entries bypass textual analysis"] = function()
	local value = entry("\0", "\1")
	value.binary = true
	assert(#main(value).relations == 0)
end
T["large move analysis is visibly bounded without losing the textual diff"] = function()
	local old = string.rep("alpha beta gamma\n", 50000)
	local result = main(entry(old, old, { { 1, 50000, 1, 50000 } }))
	assert(result.relations_limited and #result.relations == 0 and result.presentation == "native")
end
return T
