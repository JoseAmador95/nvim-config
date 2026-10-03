-- Dependency-free coverage of the pinned structural JSON normalization.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")

local difftastic = require("native_review.difftastic")
local projection = require("native_review.projection")
local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function entry(old, new, options)
	return vim.tbl_extend("force", {
		path = "file.lua",
		old_path = "file.lua",
		new_path = "file.lua",
		old_text = old,
		new_text = new,
		hunks = vim.diff(old, new, { result_type = "indices" }),
	}, options or {})
end

local function change(first, last, content, highlight)
	return { start = first, ["end"] = last, content = content, highlight = highlight or "normal" }
end

local function side(line, changes)
	return { line_number = line, changes = changes or {} }
end

local function json(status, alignment, chunks)
	return {
		language = "Lua",
		path = "file.lua",
		status = status,
		aligned_lines = alignment,
		chunks = chunks,
	}
end

local function replaced(old, new)
	return json("changed", { { 0, 0 }, { 1, 1 } }, {
		{ { lhs = side(0, { change(0, #old, old) }), rhs = side(0, { change(0, #new, new) }) } },
	})
end

local function normalize(model, decoded)
	local value, err = difftastic.normalize(model, decoded)
	assert(value, err)
	return value
end

local function rejects(model, decoded, message)
	local value, err = difftastic.normalize(model, decoded)
	assert(value == nil and type(err) == "string", "malformed data was accepted")
	if message then
		assert(err:find(message, 1, true), err)
	end
end

local function rows(value)
	local result = {}
	for _, row in ipairs(value.rows) do
		result[#result + 1] = { kind = row.kind, text = row.text, old_line = row.old_line, new_line = row.new_line }
	end
	return result
end

test("real pinned JSON maps zero-based tokens to original CRLF byte columns", function()
	local old = 'local élève = "uno"\r\nreturn élève\r\n'
	local new = 'local élève = "dos"\r\nreturn élève\r\n'
	local decoded = vim.json.decode(
		'{"aligned_lines":[[0,0],[1,1],[2,2]],"chunks":[[{"lhs":{"line_number":0,"changes":[{"start":16,"end":21,"content":"\\"uno\\"","highlight":"string"}]},"rhs":{"line_number":0,"changes":[{"start":16,"end":21,"content":"\\"dos\\"","highlight":"string"}]}}]],"language":"Lua","path":"file.lua","status":"changed"}'
	)
	local model = entry(old, new)
	local original = vim.deepcopy(model)
	local value = normalize(model, decoded)
	assert(vim.deep_equal(value.intraline, {
		old = { { line = 1, start_col = 16, end_col = 21 } },
		new = { { line = 1, start_col = 16, end_col = 21 } },
	}))
	assert(vim.deep_equal(value.aligned_lines, { { old_line = 1, new_line = 1 }, { old_line = 2, new_line = 2 } }))
	assert(vim.deep_equal(rows(value.projection), {
		{ kind = "old", text = 'local élève = "uno"', old_line = 1 },
		{ kind = "new", text = 'local élève = "dos"', new_line = 1 },
		{ kind = "context", text = "return élève", old_line = 2, new_line = 2 },
	}))
	assert(value.projection.rows[1].terminator == "\r\n" and value.projection.sources.old.raw == old)
	assert(value.projection.hunks[1].first == 1 and value.projection.hunks[1].last == 2)
	assert(vim.deep_equal(model, original), "normalization changed the frozen entry")
end)

test("formatting differences remain separate unhighlighted source rows", function()
	local model = entry("local a=1\nreturn 1\n", "local a = 1\nreturn 2\n")
	local value = normalize(
		model,
		json("changed", { { 0, 0 }, { 1, 1 }, { 2, 2 } }, {
			{ { lhs = side(1, { change(7, 8, "1") }), rhs = side(1, { change(7, 8, "2") }) } },
		})
	)
	assert(vim.deep_equal(rows(value.projection), {
		{ kind = "context", text = "local a=1", old_line = 1 },
		{ kind = "context", text = "local a = 1", new_line = 1 },
		{ kind = "old", text = "return 1", old_line = 2 },
		{ kind = "new", text = "return 2", new_line = 2 },
	}))
	assert(value.line_changes.old[1] == nil and value.line_changes.new[1] == nil)
	assert(value.projection.by_source.old[1] == 1 and value.projection.by_source.new[1] == 2)
	assert(value.projection.hunks[1].first == 3 and value.projection.hunks[1].last == 4)
	assert(value.projection.hunks[1].old_start == 2 and value.projection.hunks[1].new_start == 2)
	assert(assert(projection.source_at(value.projection, 1)).side == "old")
	assert(assert(projection.resolve_range(value.projection, 1, 1)).start_line == 1)
end)

test("exact context requires matching terminators as well as matching visible bytes", function()
	local model = entry("keep\r\nold\n", "keep\nnew\n")
	local value = normalize(
		model,
		json("changed", { { 0, 0 }, { 1, 1 }, { 2, 2 } }, {
			{ { lhs = side(1, { change(0, 3, "old") }), rhs = side(1, { change(0, 3, "new") }) } },
		})
	)
	assert(#value.projection.rows == 4)
	assert(value.projection.rows[1].kind == "context" and value.projection.rows[1].new_line == nil)
	assert(value.projection.rows[2].kind == "context" and value.projection.rows[2].old_line == nil)
	assert(value.projection.rows[1].terminator == "\r\n" and value.projection.rows[2].terminator == "\n")
end)

test("unsorted chunks and ranges produce ordered structural hunks independent of byte hunks", function()
	local model = entry("format=1\nkeep\na1b2\nkeep\nold\n", "format = 1\nkeep\na3b4\nkeep\nnew\n")
	local value = normalize(
		model,
		json("changed", {
			{ 0, 0 },
			{ 1, 1 },
			{ 2, 2 },
			{ 3, 3 },
			{ 4, 4 },
			{ 5, 5 },
		}, {
			{ { rhs = side(4, { change(0, 3, "new") }), lhs = side(4, { change(0, 3, "old") }) } },
			{
				{
					lhs = side(2, { change(3, 4, "2"), change(1, 2, "1") }),
					rhs = side(2, { change(3, 4, "4"), change(1, 2, "3") }),
				},
			},
		})
	)
	assert(vim.deep_equal(value.intraline.old, {
		{ line = 3, start_col = 1, end_col = 2 },
		{ line = 3, start_col = 3, end_col = 4 },
		{ line = 5, start_col = 0, end_col = 3 },
	}))
	assert(#value.projection.hunks == 2)
	assert(value.projection.hunks[1].first == 4 and value.projection.hunks[1].last == 5)
	assert(value.projection.hunks[2].first == 7 and value.projection.hunks[2].last == 8)
	assert(value.projection.rows[1].hunk_index == nil)
end)

test("overlapping chunks reuse identical source records without duplicating ranges or anchors", function()
	local model = entry("keep\na1b2\nold\n", "keep\na3b4\nnew\n")
	local decoded = json("changed", { { 0, 0 }, { 1, 1 }, { 2, 2 }, { 3, 3 } }, {
		{
			{ lhs = side(0), rhs = side(0) },
			{
				lhs = side(1, { change(1, 2, "1"), change(3, 4, "2") }),
				rhs = side(1, { change(1, 2, "3"), change(3, 4, "4") }),
			},
		},
		{ { lhs = side(2, { change(0, 3, "old") }), rhs = side(2, { change(0, 3, "new") }) } },
	})
	local expected = normalize(model, decoded)
	local original = vim.deepcopy(model)
	table.insert(decoded.chunks[2], 1, vim.deepcopy(decoded.chunks[1][2]))
	table.insert(decoded.chunks[2], 1, vim.deepcopy(decoded.chunks[1][1]))
	-- A chunk can also repeat just one side of an aligned row.
	decoded.chunks[3] = { { lhs = vim.deepcopy(decoded.chunks[1][2].lhs) } }
	local value = normalize(model, decoded)
	assert(vim.deep_equal(value, expected), "overlapping chunks changed the normalized presentation")
	assert(vim.deep_equal(model, original), "overlapping chunks changed the frozen sources")
end)

test("repeated chunk records still validate contents and their opposite alignment", function()
	local model = entry("keep\nold\n", "keep\nnew\n")
	local decoded = json("changed", { { 0, 0 }, { 1, 1 }, { 2, 2 } }, {
		{ { lhs = side(1, { change(0, 3, "old") }), rhs = side(1, { change(0, 3, "new") }) } },
	})
	for _, changes in ipairs({ {}, { change(0, 3, "forged") }, { change(0, 2, "ol") } }) do
		local invalid = vim.deepcopy(decoded)
		invalid.chunks[2] = { { lhs = side(1, changes) } }
		rejects(model, invalid)
	end
	local reversed = vim.deepcopy(decoded)
	table.insert(reversed.chunks, 1, { { lhs = side(1) } })
	rejects(model, reversed, "disagree on a repeated source line")
	local invalid = vim.deepcopy(decoded)
	invalid.chunks[2] = { { lhs = vim.deepcopy(decoded.chunks[1][1].lhs), rhs = side(0) } }
	rejects(model, invalid, "disagree with aligned_lines")
end)

test("nullable one-sided alignment covers originals and omits virtual EOF", function()
	local model = entry("keep\nold", "keep\nextra\nnew\n")
	local decoded = vim.json.decode(
		'{"language":"Lua","path":"file.lua","status":"changed","aligned_lines":[[0,0],[null,1],[1,2],[2,3]],"chunks":[[{"rhs":{"line_number":1,"changes":[{"start":0,"end":5,"content":"extra","highlight":"normal"}]}},{"lhs":{"line_number":1,"changes":[{"start":0,"end":3,"content":"old","highlight":"normal"}]},"rhs":{"line_number":2,"changes":[{"start":0,"end":3,"content":"new","highlight":"normal"}]}}]]}'
	)
	local value = normalize(model, decoded)
	assert(vim.deep_equal(value.aligned_lines, {
		{ old_line = 1, new_line = 1 },
		{ new_line = 2 },
		{ old_line = 2, new_line = 3 },
	}))
	assert(value.projection.sources.old.line_count == 2 and value.projection.sources.new.line_count == 3)
	assert(value.projection.rows[3].terminator == "", "original missing final newline was rewritten")
	assert(#value.projection.rows == 4)
end)

test("actual blank trailing lines survive omission of only the synthetic EOF line", function()
	local value = normalize(
		entry("old\n\n", "new\n\n"),
		json("changed", { { 0, 0 }, { 1, 1 }, { 2, 2 } }, {
			{ { lhs = side(0, { change(0, 3, "old") }), rhs = side(0, { change(0, 3, "new") }) } },
		})
	)
	assert(#value.aligned_lines == 2 and #value.projection.rows == 3)
	assert(value.projection.rows[3].text == "" and value.projection.rows[3].old_line == 2)
	assert(value.projection.rows[3].new_line == 2 and value.projection.rows[3].terminator == "\n")
end)

test("Unicode ranges are exclusive byte columns including combining marks and astral scalars", function()
	local prefix = "é𝌆="
	local old, new = prefix .. "é", prefix .. "á"
	local decoded = json("changed", { { 0, 0 }, { 1, 1 } }, {
		{ { lhs = side(0, { change(#prefix, #old, "é") }), rhs = side(0, { change(#prefix, #new, "á") }) } },
	})
	local model = entry(old .. "\r\n", new .. "\r\n")
	local value = normalize(model, decoded)
	assert(value.intraline.old[1].start_col == 7 and value.intraline.old[1].end_col == 10)
	local malformed = vim.deepcopy(decoded)
	malformed.chunks[1][1].lhs.changes[1] = change(1, 2, old:sub(2, 2))
	rejects(model, malformed, "UTF-8")
	malformed.chunks[1][1].lhs.changes[1] = change(2, 3, old:sub(3, 3))
	rejects(model, malformed, "UTF-8")
end)

test("CRLF ranges validate retained CR bytes and clamp only the visible end column", function()
	local value = normalize(entry("old\r\n", "new\r\n"), replaced("old\r", "new\r"))
	assert(value.intraline.old[1].end_col == 3 and value.intraline.new[1].end_col == 3)
	assert(value.projection.sources.old.raw == "old\r\n")
	local invalid = replaced("old\r", "new\r")
	invalid.chunks[1][1].lhs.changes[1] = change(0, 5, "old\r\n")
	rejects(entry("old\r\n", "new\r\n"), invalid, "byte bounds")
end)

test("unchanged syntactic output uses local geometry without any structural highlights", function()
	local model = entry("local a=1\nreturn a", "local a = 1\nreturn a\n")
	local original = vim.deepcopy(model)
	local value = normalize(model, json("unchanged"))
	assert(value.status == "unchanged" and #value.projection.hunks == 0)
	assert(next(value.line_changes.old) == nil and next(value.line_changes.new) == nil)
	assert(#value.intraline.old == 0 and #value.intraline.new == 0)
	assert(vim.deep_equal(value.aligned_lines, { { old_line = 1, new_line = 1 }, { old_line = 2, new_line = 2 } }))
	for _, row in ipairs(value.projection.rows) do
		assert(row.kind == "context" and row.hunk_index == nil)
	end
	assert(#value.projection.rows == 4, "unequal text or terminators were merged")
	assert(vim.deep_equal(model, original))
end)

test("identical and empty unchanged files retain canonical source anchors", function()
	local value = normalize(entry("same\n", "same\n"), json("unchanged"))
	assert(
		#value.projection.rows == 1
			and value.projection.rows[1].old_line == 1
			and value.projection.rows[1].new_line == 1
	)
	value = normalize(entry("", ""), json("unchanged"))
	assert(#value.aligned_lines == 0 and #value.projection.rows == 1)
	assert(value.projection.rows[1].kind == "empty" and not value.projection.rows[1].anchorable)
	assert(#value.projection.hunks == 0)
end)

test("created and deleted files highlight all actual visible bytes and retain blank line anchors", function()
	for _, status in ipairs({ "created", "deleted" }) do
		local selected = status == "created" and "new" or "old"
		local model = selected == "new" and entry("", "é\r\n\r\ntail", { old_path = false })
			or entry("é\r\n\r\ntail", "", { new_path = false })
		local value = normalize(model, json(status))
		assert(vim.deep_equal(value.intraline[selected], {
			{ line = 1, start_col = 0, end_col = 2 },
			{ line = 3, start_col = 0, end_col = 4 },
		}))
		assert(vim.deep_equal(value.line_changes[selected], { true, true, true }))
		assert(#value.projection.rows == 3 and #value.projection.hunks == 1)
		assert(value.projection.hunks[1].first == 1 and value.projection.hunks[1].last == 3)
		assert(value.projection.rows[2].kind == selected and value.projection.rows[2].source_line == 2)
		assert(value.projection.rows[3].terminator == "")
	end
end)

test("Text and internal Text fallbacks publish no structural result", function()
	for _, language in ipairs({ "Text", "Text (exceeded DFT_GRAPH_LIMIT)", "Text (exceeded DFT_BYTE_LIMIT)" }) do
		local decoded = replaced("old", "new")
		decoded.language = language
		decoded.aligned_lines = "intentionally unused Text alignment"
		local value = normalize(entry("old\n", "new\n"), decoded)
		assert(value.fallback_reason:find(language, 1, true))
		assert(value.projection == nil and value.intraline == nil and value.aligned_lines == nil)
	end
end)

test("single-file metadata and canonical geometry are validated before analysis", function()
	local model = entry("old\n", "new\n")
	for _, invalid in ipairs({ {}, { json("unchanged") }, "string", json("unexpected") }) do
		rejects(model, invalid, "single-file object")
	end
	local invalid = replaced("old", "new")
	invalid.path = "different.lua"
	rejects(model, invalid, "path")
	invalid.path, invalid.language = "file.lua", ""
	rejects(model, invalid, "single-file object")
	rejects(entry("old\n", "new\n", { hunks = { { 5, 1, 5, 1 } } }), replaced("old", "new"))
end)

test("alignment rejects missing repeated reversed virtual out-of-range and noninteger maps", function()
	local model = entry("keep\nold\n", "keep\nnew\n")
	local invalid_alignments = {
		{},
		{ { 0, 0 } },
		{ { 0, 0 }, { 0, 1 } },
		{ { 1, 0 }, { 0, 1 } },
		{ { 0, 0 }, { 1, 1 }, { 2, 2 }, { 2, vim.NIL } },
		{ { 0, 0 }, { 1, 1 }, { 3, 2 } },
		{ { -1, 0 }, { 1, 1 } },
		{ { 0.5, 0 }, { 1, 1 } },
		{ { vim.NIL, vim.NIL }, { 0, 0 }, { 1, 1 } },
		{ { 0 }, { 1, 1 } },
		{ { 0, 0, 0 }, { 1, 1 } },
		{ { 0, 0 }, { 1, 1 }, unexpected = true },
	}
	for _, alignment in ipairs(invalid_alignments) do
		rejects(
			model,
			json("changed", alignment, {
				{ { lhs = side(1, { change(0, 3, "old") }), rhs = side(1, { change(0, 3, "new") }) } },
			})
		)
	end
end)

test("chunks reject inconsistent alignment conflicting repeats virtual EOF and malformed side maps", function()
	local model = entry("keep\nold\n", "keep\nnew\n")
	local alignment = { { 0, 0 }, { 1, 1 }, { 2, 2 } }
	for _, chunks in ipairs({
		{},
		{ {} },
		{ { {} } },
		{ { { lhs = false } } },
		{ { { lhs = side(1, { change(0, 3, "old") }), rhs = side(0) } } },
		{ { { lhs = side(2, { change(0, 0, "") }) } } },
		{ { { lhs = side(-1) } } },
		{ { { lhs = { line_number = 1, changes = false } } } },
		{ { { lhs = side(1, { change(0, 3, "old") }) }, { lhs = side(1) } } },
	}) do
		rejects(model, json("changed", alignment, chunks))
	end
end)

test("change ranges reject forged bytes invalid bounds highlights and overlapping spans", function()
	local model = entry("old\n", "new\n")
	for _, invalid_change in ipairs({
		change(-1, 2, "ol"),
		change(0, 4, "old\n"),
		change(2, 1, ""),
		change(0.5, 2, "ol"),
		change(0, 3, "forged"),
		change(0, 3, "old", "novel"),
		false,
	}) do
		local decoded = replaced("old", "new")
		decoded.chunks[1][1].lhs.changes = { invalid_change }
		rejects(model, decoded)
	end
	local overlap = replaced("old", "new")
	overlap.chunks[1][1].lhs.changes = { change(0, 2, "ol"), change(1, 3, "ld") }
	rejects(model, overlap, "overlap")
	local empty = replaced("old", "new")
	empty.chunks[1][1].lhs.changes = {}
	empty.chunks[1][1].rhs.changes = {}
	rejects(model, empty, "no structural ranges")
end)

test("adjacent novel spans merge without broadening over unchanged bytes", function()
	local decoded = replaced("old", "new")
	decoded.chunks[1][1].lhs.changes = { change(1, 3, "ld"), change(0, 1, "o") }
	local value = normalize(entry("old\n", "new\n"), decoded)
	assert(vim.deep_equal(value.intraline.old, { { line = 1, start_col = 0, end_col = 3 } }))
end)

test("local statuses reject contradictory bytes and unexpected analysis maps", function()
	rejects(entry("old\n", "new\n"), json("created"), "contradicts")
	rejects(entry("", ""), json("deleted"), "contradicts")
	rejects(entry("old\n", "new\n"), json("unchanged", { { 0, 0 } }), "must omit")
	rejects(entry("old\n", "new\n"), json("unchanged", nil, false), "must omit")
	assert(normalize(entry("old\n", "new\n"), json("unchanged", {}, {})).projection)
end)

test("lossy UTF-8 conversion cannot drift source coordinates", function()
	rejects(entry("\255\n", "new\n"), json("unchanged"), "not valid UTF-8")
	rejects(entry("\237\160\128\n", "new\n"), json("unchanged"), "not valid UTF-8")
	rejects(entry("\244\144\128\128\n", "new\n"), json("unchanged"), "not valid UTF-8")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("native_review_difftastic_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
