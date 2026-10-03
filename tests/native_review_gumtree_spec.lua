-- Installed parsers are read-only; source fixtures never use a live file/buffer.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")
if vim.env.NVIM_REVIEW_PARSER_ROOT then
	vim.opt.runtimepath:append(vim.env.NVIM_REVIEW_PARSER_ROOT)
end

local gumtree = require("native_review.gumtree")
local failures, count = {}, 0
local original_parser = gumtree._parser

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	gumtree._parser = original_parser
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function entry(old, new, extension)
	return { path = "does-not-exist." .. (extension or "lua"), old_text = old, new_text = new }
end

local function exported(model)
	local trees, err = gumtree.export(model)
	assert(trees, err)
	return trees
end

local function node(tree, kind, label, occurrence)
	local found = 0
	for _, value in ipairs(tree.nodes) do
		if value.type == kind and (label == nil or value.label == label) then
			found = found + 1
			if found == (occurrence or 1) then
				return value
			end
		end
	end
	error("missing exported node: " .. kind .. " " .. tostring(label))
end

local function match(old, new)
	return { src = old.key, dest = new.key }
end

local function update(old, new)
	return { action = "update-node", tree = old.key, label = new.label }
end

local function normalized(trees, matches, actions)
	local result, err = gumtree.normalize(trees, { matches = matches, actions = actions })
	assert(result, err)
	return result
end

test("Lua Python C and C++ export all anonymous tokens and comments", function()
	for _, fixture in ipairs({
		{ "lua", "-- comment\nlocal answer = 3 % 2\n", "comment", "=" },
		{ "py", "# comment\nanswer = 3 % 2\n", "comment", "=" },
		{ "c", "// comment\nint answer = 3 % 2;\n", "comment", ";" },
		{ "cpp", "// comment\nnamespace demo { int answer = 3 % 2; }\n", "comment", "{" },
	}) do
		local model = entry(fixture[2], fixture[2], fixture[1])
		local before = vim.deepcopy(model)
		local trees = exported(model)
		local comment = node(trees.old, fixture[3])
		assert(fixture[2]:sub(comment.first + 1, comment.last):find("comment", 1, true))
		assert(node(trees.old, fixture[4]).label == fixture[4])
		assert(node(trees.old, "%").label == "%", "percent token corrupted the node key")
		assert(trees.old.xml == trees.new.xml)
		assert(vim.deep_equal(model, before), "export mutated frozen model")
	end
end)

test("Unicode CRLF and missing final newline preserve byte coordinates and XML labels", function()
	local old = 'def café():\r\n    value = "a😀"\r\n    return value'
	local new = old:gsub("value", "other")
	local trees = exported(entry(old, new, "py"))
	local a, b = node(trees.old, "identifier", "value", 2), node(trees.new, "identifier", "other", 2)
	local result = normalized(trees, { match(a, b) }, { update(a, b) })
	assert(vim.deep_equal(result.relations, {
		{
			kind = "identifier_update",
			old = { start_line = 3, start_col = 11, end_line = 3, end_col = 16 },
			new = { start_line = 3, start_col = 11, end_line = 3, end_col = 16 },
		},
	}))
	local unicode = node(trees.old, "identifier", "café")
	assert(unicode.last - unicode.first == 5)
	assert(trees.old.source.text == old and trees.new.source.text == new)
	local comment = exported(entry('--[[a\r\n\t<&">]]', '--[[a\r\n\t<&">]]'))
	assert(comment.old.xml:find("&#13;&#10;&#9;&lt;&amp;&quot;&gt;", 1, true))
end)

test("empty created deleted and equal snapshots remain native full textual results", function()
	for _, texts in ipairs({
		{ "", "" },
		{ "", "local x = 1" },
		{ "local x = 1\n", "" },
		{ "local x = 1", "local x = 1" },
	}) do
		local trees = exported(entry(texts[1], texts[2]))
		local result = normalized(trees, {}, {})
		assert(result.presentation == "native" and result.structural_only == false and #result.relations == 0)
	end
end)

test("crossing moved functions retain original source order and coexisting identifier edits", function()
	local old = "def first():\n    value = 1\n    return value\n\ndef second():\n    return 2\n"
	local new = "def second():\n    return 2\n\ndef first():\n    other = 1\n    return other\n"
	local trees = exported(entry(old, new, "py"))
	local first_old, first_new =
		node(trees.old, "function_definition", nil, 1), node(trees.new, "function_definition", nil, 2)
	local second_old, second_new =
		node(trees.old, "function_definition", nil, 2), node(trees.new, "function_definition", nil, 1)
	local ident_old, ident_new = node(trees.old, "identifier", "value"), node(trees.new, "identifier", "other")
	local first_name_old, first_name_new =
		node(trees.old, "identifier", "first"), node(trees.new, "identifier", "first")
	local result = normalized(trees, {
		match(second_old, second_new),
		match(ident_old, ident_new),
		match(first_old, first_new),
		match(first_name_old, first_name_new),
	}, {
		{ action = "move-tree", tree = second_old.key, parent = "untrusted parent position", at = 9000 },
		{ action = "move-tree", tree = first_name_old.key },
		update(ident_old, ident_new),
		{ action = "move-tree", tree = first_old.key },
		{ action = "move-tree", tree = first_old.key },
	})
	assert(#result.relations == 3, vim.inspect(result.relations))
	assert(
		result.relations[1].kind == "move"
			and result.relations[1].old.start_line == 1
			and result.relations[1].new.start_line == 4
	)
	assert(
		result.relations[2].kind == "identifier_update"
			and result.relations[2].old.start_line == 2
			and result.relations[2].new.start_line == 5
	)
	assert(
		result.relations[3].kind == "move"
			and result.relations[3].old.start_line == 5
			and result.relations[3].new.start_line == 1
	)
	assert(result.projection == nil and result.aligned_lines == nil, "GumTree reordered or filtered Main")
end)

test("literal and comment updates cannot become identifier changes", function()
	local trees = exported(entry("-- before\nlocal x = 1", "-- after\nlocal x = 2"))
	local a, b = node(trees.old, "number"), node(trees.new, "number")
	local c, d = node(trees.old, "comment_content"), node(trees.new, "comment_content")
	assert(#normalized(trees, { match(a, b), match(c, d) }, { update(a, b), update(c, d) }).relations == 0)
end)

test("duplicate matches and actions collapse while conflicts and unmapped nodes fail", function()
	local trees = exported(entry("local before = before", "local after = after"))
	local a, b = node(trees.old, "identifier", "before"), node(trees.new, "identifier", "after")
	local c = node(trees.new, "identifier", "after", 2)
	assert(#normalized(trees, { match(a, b), match(a, b) }, { update(a, b), update(a, b) }).relations == 1)
	for _, malformed in ipairs({
		{ matches = { match(a, b), match(a, c) }, actions = {} },
		{ matches = { { src = "identifier: before [7,10]", dest = b.key } }, actions = {} },
		{ matches = {}, actions = { { action = "move-tree", tree = a.key, parent = b.key, at = 0 } } },
		{ matches = { match(a, b) }, actions = { { action = "update-node", tree = a.key, label = "wrong" } } },
		{ matches = { match(a, b) }, actions = { { action = "unknown", tree = a.key } } },
		{ matches = {}, actions = { { action = "delete-node", tree = "fabricated" } } },
		{ matches = "wrong", actions = {} },
		{ matches = {}, actions = { [2] = {} } },
		{},
	}) do
		local result, err = gumtree.normalize(trees, malformed)
		assert(not result and err, vim.inspect(malformed))
	end
end)

test("normalizer validates frozen label contents and byte boundaries again", function()
	for _, corrupt in ipairs({ "content", "boundary", "ambiguous" }) do
		local trees = exported(entry("café = 1", "other = 1", "py"))
		local a, b = node(trees.old, "identifier", "café"), node(trees.new, "identifier", "other")
		local decoded = { matches = { match(a, b) }, actions = { update(a, b) } }
		if corrupt == "content" then
			a.label = "fabricated"
		elseif corrupt == "boundary" then
			a.last = a.last - 1
		else
			trees.old.lookup[a.key] = false
		end
		local result, err = gumtree.normalize(trees, decoded)
		assert(not result and err)
	end
end)

test("unsupported metadata binary UTF-8 XML and syntax errors fall back explicitly", function()
	for _, model in ipairs({
		entry("x", "y", "rs"),
		entry("local x =", "local x = 1"),
		entry("function f( return", ""),
		entry("\0", ""),
		entry("\1", ""),
		entry("\239\191\190", ""),
		entry("\192\175", ""),
		entry("\240\159\152", ""),
		entry("\237\160\128", ""),
		vim.tbl_extend("force", entry("", ""), { metadata_only = true }),
		vim.tbl_extend("force", entry("", ""), { binary = true }),
		vim.tbl_extend("force", entry("", ""), { old_path = "old.py", new_path = "new.lua" }),
	}) do
		local result, called
		gumtree.prepare(model, {
			analyze = function()
				called = true
			end,
		}, function(value)
			result = value
		end)
		assert(result and result.fallback_reason and not called, vim.inspect(model))
	end
end)

test("missing parser and combined byte/node limits use Main before starting a process", function()
	local result, err = gumtree.export(entry(string.rep(" ", 524289), string.rep(" ", 524288)))
	assert(not result and err:find("1 MiB", 1, true))
	local nodes, node_err = gumtree.export(entry(string.rep("local x = 1\n", 5000), string.rep("local x = 1\n", 5000)))
	assert(not nodes and node_err:find("50000 node", 1, true), node_err)
	gumtree._parser = function()
		error("parser is unavailable")
	end
	local trees, parser_err = gumtree.export(entry("", ""))
	assert(not trees and parser_err:find("parser is unavailable", 1, true))
end)

test("prepare clones frozen input, accepts only valid JSON, and suppresses cancelled or duplicate callbacks", function()
	local model = entry("local before = 1", "local after = 1")
	local trees = exported(model)
	local a, b = node(trees.old, "identifier", "before"), node(trees.new, "identifier", "after")
	local raw = vim.json.encode({ matches = { match(a, b) }, actions = { update(a, b) } })
	local capture, calls, stopped = nil, {}, 0
	local adapter = {
		analyze = function(request, callback)
			assert(request.entry ~= model and request.entry.old_text == model.old_text)
			assert(request.trees.old == trees.old.xml and request.trees.new == trees.new.xml)
			request.entry.old_text = "attempted mutation"
			capture = callback
			return function()
				stopped = stopped + 1
			end
		end,
	}
	local cancel = gumtree.prepare(model, adapter, function(result, err)
		calls[#calls + 1] = { result, err }
	end)
	assert(model.old_text == "local before = 1")
	capture(raw)
	capture(raw)
	assert(#calls == 1 and #calls[1][1].relations == 1)
	cancel()
	cancel()
	assert(stopped == 1)
	calls = {}
	local cancel_pending = gumtree.prepare(model, adapter, function(result, err)
		calls[#calls + 1] = { result, err }
	end)
	cancel_pending()
	capture(raw)
	assert(#calls == 0)
	for _, invalid in ipairs({ "not-json", "{}", "null", "[]" }) do
		local outcome, error_message
		gumtree.prepare(model, {
			analyze = function(_, callback)
				callback(invalid)
			end,
		}, function(result, err)
			outcome, error_message = result, err
		end)
		assert(not outcome and error_message)
	end
end)

test("prepare reports missing adapter and thrown or failed execution without mutating Main", function()
	for _, adapter in ipairs({
		{},
		{
			analyze = function()
				error("injected error")
			end,
		},
		{
			analyze = function(_, callback)
				callback(nil, "process failed")
			end,
		},
	}) do
		local result, err
		gumtree.prepare(entry("", ""), adapter, function(value, message)
			result, err = value, message
		end)
		assert(result == nil and type(err) == "string")
	end
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_gumtree_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
