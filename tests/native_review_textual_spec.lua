vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")
local textual = require("native_review.textual")
local projection = require("native_review.projection")
local moves = require("native_review.moves")
local failures, count = {}, 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
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
test("unique exact moved blocks retain counterpart coordinates across hunks", function()
	local value = entry(block .. middle, middle .. block, { { 1, 3, 0, 0 }, { 8, 0, 6, 3 } })
	local original = vim.deepcopy(value)
	local result = assert(textual.main(value))
	assert(#result.relations == 1)
	local relation = result.relations[1]
	assert(relation.kind == "move" and relation.old.start_line == 1 and relation.old.end_line == 3)
	assert(relation.new.start_line == 6 and relation.new.end_line == 8)
	assert(vim.deep_equal(original, value))
end)
test("repeated blocks are ambiguous and short fragments are omitted", function()
	assert(#exact(entry(block .. block, "replaced\n" .. block, { { 1, 6, 1, 4 } })) == 0)
	assert(#exact(entry("alpha beta\ngamma delta\n", "prefix\nalpha beta\ngamma delta\n", { { 1, 2, 1, 3 } })) == 0)
	assert(#exact(entry("a\nb\nc\n", "prefix\na\nb\nc\n", { { 1, 3, 1, 4 } })) == 0)
end)
test("longest blocks win without overlapping suffix relations", function()
	local extended = block .. "local gamma = 3\n"
	local found = exact(entry(extended .. middle, middle .. extended, { { 1, 4, 0, 0 }, { 9, 0, 6, 4 } }))
	assert(#found == 1 and found[1].old.end_line == 4)
end)
test("edited, CRLF, and final-newline changes are never exact moves", function()
	for _, modified in ipairs({ block:gsub("beta = 2", "beta = 3"), block:gsub("\n", "\r\n"), block:sub(1, -2) }) do
		assert(#exact(entry(block, modified, { { 1, 3, 1, 3 } })) == 0)
	end
end)
test("Patience owns a different alignment while canonical snapshots remain unchanged", function()
	local value = entry("e\na\nc\nb\nd\nb\nb\nb\nb\ne\na\nc\n", "e\nc\nf\ne\ne\ne\nb\nf\nb\nb\ne\nf\n")
	local original = vim.deepcopy(value)
	local diffopt = vim.o.diffopt
	local result = assert(textual.patience(value))
	assert(result.presentation == "projected" and result.structural_only == false)
	assert(not vim.deep_equal(value.hunks, result.display_hunks))
	assert(vim.deep_equal(original, value) and vim.o.diffopt == diffopt)
	local seen = { old = 0, new = 0 }
	for _, pair in ipairs(result.aligned_lines) do
		for _, side in ipairs({ "old", "new" }) do
			if pair[side .. "_line"] then
				seen[side] = seen[side] + 1
				assert(pair[side .. "_line"] == seen[side])
			end
		end
	end
	assert(seen.old == 12 and seen.new == 12)
end)
test("Patience retains character refinement, whitespace, empty files and source bytes", function()
	for _, value in ipairs({
		entry("local café = 30\r\n", "local café = 60"),
		entry("", "new\n"),
		entry("old\n", ""),
		entry("", ""),
		entry("\tvalue\n", " value\n"),
	}) do
		local result = assert(textual.patience(value))
		assert(
			result.projection.sources.old.raw == value.old_text and result.projection.sources.new.raw == value.new_text
		)
	end
	local result = assert(textual.patience(entry("local café = 30\n", "local café = 60\n")))
	assert(#result.intraline.new == 1 and result.intraline.new[1].end_col - result.intraline.new[1].start_col == 1)
end)
test("binary entries bypass textual analysis", function()
	local value = entry("\0", "\1")
	value.binary = true
	assert(textual.patience(value).fallback_reason)
	assert(#textual.main(value).relations == 0)
end)
test("large move analysis is visibly bounded without losing the textual diff", function()
	local old = string.rep("alpha beta gamma\n", 50000)
	local result = assert(textual.main(entry(old, old, { { 1, 50000, 1, 50000 } })))
	assert(result.relations_limited and #result.relations == 0 and result.presentation == "native")
end)
if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("native_review_textual_spec: %d tests passed"):format(count))
