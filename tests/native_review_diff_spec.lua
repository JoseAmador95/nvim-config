vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")

local diff = require("native_review.diff")
local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end

local function entry(old_text, new_text)
	return {
		old_text = old_text,
		new_text = new_text,
		hunks = vim.text.diff(old_text, new_text, { result_type = "indices" }),
	}
end

local function changed(value, side)
	local source = vim.split(value[side .. "_text"], "\n", { plain = true })
	local result, err = diff.refine(value)
	assert(result, err)
	assert(err == nil, "successful refinement returned an error")
	local found = {}
	for _, range in ipairs(result[side]) do
		found[#found + 1] = { range.line, source[range.line]:sub(range.start_col + 1, range.end_col) }
	end
	return found, result
end

local function equal(expected, actual)
	assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

test("separated changes highlight only their differing characters", function()
	local value = entry("local timeout = 30; retry = 2\n", "local timeout = 60; retry = 4\n")
	equal({ { 1, "3" }, { 1, "2" } }, changed(value, "old"))
	equal({ { 1, "6" }, { 1, "4" } }, changed(value, "new"))
end)

test("mostly replaced words include the single surviving grapheme at any position", function()
	for _, pair in ipairs({ { "control", "array" }, { "cable", "crown" }, { "limit", "reset" } }) do
		local value = entry('message = "' .. pair[1] .. '"\n', 'message = "' .. pair[2] .. '"\n')
		local original = vim.deepcopy(value)
		equal({ { 1, pair[1] } }, changed(value, "old"))
		equal({ { 1, pair[2] } }, changed(value, "new"))
		equal(original, value)
	end
end)

test("whole-word emphasis preserves separators and small or substantial matching portions", function()
	local value = entry("control(cable) + limit\n", "array(crown) + reset\n")
	equal({ { 1, "control" }, { 1, "cable" }, { 1, "limit" } }, changed(value, "old"))
	equal({ { 1, "array" }, { 1, "crown" }, { 1, "reset" } }, changed(value, "new"))
	equal({ { 1, "a" }, { 1, "c" } }, changed(entry("abcd\n", "wbyd\n"), "old"))
	equal({ { 1, "s" } }, changed(entry("item\n", "items\n"), "new"))
	equal({ { 1, "b" } }, changed(entry("ab\n", "ac\n"), "old"))
end)

test("whole-word emphasis counts graphemes while retaining UTF-8 byte boundaries", function()
	for _, pair in ipairs({ { "café", "tôté" }, { "caé", "rué" } }) do
		local value = entry('"' .. pair[1] .. '"\r\n', '"' .. pair[2] .. '"')
		for _, side in ipairs({ "old", "new" }) do
			local word = side == "old" and pair[1] or pair[2]
			local ranges, result = changed(value, side)
			equal({ { 1, word } }, ranges)
			equal({ { line = 1, start_col = 1, end_col = 1 + #word } }, result[side])
		end
	end
end)

test("word boundaries do not inherit the current buffer's keyword option", function()
	local previous = vim.bo.iskeyword
	local value = entry("control(cable)\n", "array(crown)\n")
	local expected = assert(diff.refine(value))
	for _, setting in ipairs({ "", "@,48-57,_,(,)" }) do
		vim.bo.iskeyword = setting
		local result, err = diff.refine(value)
		vim.bo.iskeyword = previous
		assert(result, err)
		equal(expected, result)
	end
end)

test("inserted lines do not displace replacement matching", function()
	local value = entry(
		"local timeout = 30\nlocal retries = 2\nreturn run(timeout, retries)\n",
		"local enabled = true\nlocal timeout = 60\nlocal retries = 4\nreturn run(timeout, retries)\n"
	)
	equal({ { 1, "3" }, { 2, "2" } }, changed(value, "old"))
	equal({ { 2, "6" }, { 3, "4" } }, changed(value, "new"))
end)

test("insertions and deletions within a line keep exclusive byte ranges", function()
	local value = entry('local value = "abc"\n', 'local value = "abXYc"\n')
	equal({}, changed(value, "old"))
	equal({ { 1, "XY" } }, changed(value, "new"))
	equal({ { 1, "XY" } }, changed(entry(value.new_text, value.old_text), "old"))
end)

test("Unicode graphemes include composing marks and joined emoji", function()
	local value = entry('local label = "café é 👩‍💻"\n', 'local label = "cafè è 👨‍💻"\n')
	equal({ { 1, "é" }, { 1, "é" }, { 1, "👩‍💻" } }, changed(value, "old"))
	equal({ { 1, "è" }, { 1, "è" }, { 1, "👨‍💻" } }, changed(value, "new"))
end)

test("tabs and whitespace changes are not ignored", function()
	equal({ { 1, "\t" } }, changed(entry("\tlocal x = 1\n", " local x = 1 \n"), "old"))
	equal({ { 1, " " }, { 1, " " } }, changed(entry("\tlocal x = 1\n", " local x = 1 \n"), "new"))
end)

test("CRLF and missing final newline never invent visible character changes", function()
	local value = entry("local x = 30\r\n", "local x = 60")
	equal({ { 1, "3" } }, changed(value, "old"))
	equal({ { 1, "6" } }, changed(value, "new"))
	equal({}, changed(entry("same\r\n", "same\n"), "old"))
	equal({}, changed(entry("same\n", "same"), "new"))
end)

test("pure added and deleted lines retain line-only decorations", function()
	equal({}, changed(entry("", "new\n"), "new"))
	equal({}, changed(entry("old\n", ""), "old"))
end)

test("over-budget blocks retain canonical hunks and return bounded detail", function()
	local value = entry(string.rep("a", 5000) .. "\n", string.rep("b", 5000) .. "\n")
	local hunks = vim.deepcopy(value.hunks)
	local result = assert(diff.refine(value))
	assert(result.limited and #result.old == 0 and #result.new == 0)
	equal(hunks, value.hunks)
end)

test("common prefixes and suffixes are removed before the grapheme budget", function()
	local value = entry(string.rep("x", 5000) .. "30\n", string.rep("x", 5000) .. "60\n")
	local ranges, result = changed(value, "new")
	equal({ { 1, "6" } }, ranges)
	assert(not result.limited)
end)

test("metadata and binary entries never invoke textual refinement", function()
	local value = entry("old\n", "new\n")
	value.binary = true
	equal({ old = {}, new = {}, limited = false }, assert(diff.refine(value)))
	value.binary = false
	value.metadata_only = true
	equal({ old = {}, new = {}, limited = false }, assert(diff.refine(value)))
end)

test("presentation caches reuse exact content and reject changed bytes or hunks", function()
	local state = {}
	local value = entry("local x = 30\n", "local x = 60\n")
	local first = assert(diff.for_entry(state, value))
	assert(diff.for_entry(state, vim.deepcopy(value)) == first)
	local different = entry(value.old_text, "local x = 70\n")
	assert(diff.for_entry(state, different) ~= first)
	different.hunks = {}
	equal({ old = {}, new = {}, limited = false }, assert(diff.for_entry(state, different)))
end)

test("out-of-range canonical hunks fail without caching invalid ranges", function()
	local value = entry("old\n", "new\n")
	value.hunks = { { 2, 1, 1, 1 } }
	local state = {}
	local result, err = diff.for_entry(state, value)
	assert(not result and err:find("exceeds its source", 1, true) and not state.intraline_cache)
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("passed %d native review diff specs"):format(count))
