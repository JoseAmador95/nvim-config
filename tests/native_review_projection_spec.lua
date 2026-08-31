-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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

local projection = require("config.native_review").projection

local function entry(old_text, new_text, options)
	options = options or {}
	local old_path = options.old_path
	if old_path == nil then
		old_path = "old.lua"
	elseif old_path == false then
		old_path = nil
	end
	local new_path = options.new_path
	if new_path == nil then
		new_path = "new.lua"
	elseif new_path == false then
		new_path = nil
	end
	return {
		old_path = old_path,
		new_path = new_path,
		old_text = old_text,
		new_text = new_text,
		hunks = options.hunks ~= nil and options.hunks or vim.diff(old_text, new_text, { result_type = "indices" }),
	}
end

local function reconstruct(source)
	local values = {}
	for _, line in ipairs(source.lines) do
		values[#values + 1] = line.text .. line.terminator
	end
	return table.concat(values)
end

local function row_shape(value)
	local rows = {}
	for _, row in ipairs(value.rows) do
		rows[#rows + 1] = {
			kind = row.kind,
			text = row.text,
			old_line = row.old_line,
			new_line = row.new_line,
		}
	end
	return rows
end

test("replacement rows are context once then OLD before NEW", function()
	local value, err = projection.build(entry("keep\r\nold-a\r\nold-b\r\ntail", "keep\r\nnew-a\r\ntail"))
	assert(value, err)
	assert(
		vim.deep_equal(row_shape(value), {
			{ kind = "context", text = "keep", old_line = 1, new_line = 1 },
			{ kind = "old", text = "old-a", old_line = 2 },
			{ kind = "old", text = "old-b", old_line = 3 },
			{ kind = "new", text = "new-a", new_line = 2 },
			{ kind = "context", text = "tail", old_line = 4, new_line = 3 },
		}),
		vim.inspect(row_shape(value))
	)
	assert(value.by_source.old[1] == 1 and value.by_source.old[4] == 5)
	assert(value.by_source.new[1] == 1 and value.by_source.new[3] == 5)
	assert(value.hunks[1].first == 2 and value.hunks[1].last == 4)
	assert(reconstruct(value.sources.old) == value.sources.old.raw)
	assert(reconstruct(value.sources.new) == value.sources.new.raw)

	local old_range = assert(projection.resolve_range(value, 2, 3))
	assert(old_range.side == "old" and old_range.start_line == 2 and old_range.end_line == 3)
	local new_range = assert(projection.resolve_range(value, 4, 4))
	assert(new_range.side == "new" and new_range.start_line == 2 and new_range.end_line == 2)
	local mixed, mixed_err = projection.resolve_range(value, 3, 4)
	assert(mixed == nil and mixed_err:find("crosses OLD-only and NEW-only", 1, true), mixed_err)
	assert(projection.locate(value, "old", 1, "old.lua") == 1)
	assert(projection.locate(value, "right", 2, "new.lua") == 4)
	assert(vim.deep_equal(projection.rows_for_range(value, "left", 2, 3, "old.lua"), { 2, 3 }))
	assert(vim.deep_equal(projection.sections(value, 0), { { first = 2, hunks = { 1 }, last = 4 } }))
	assert(vim.deep_equal(projection.sections(value, 1), { { first = 1, hunks = { 1 }, last = 5 } }))
end)

test("range resolution uses exclusive rows, shared defaults, and a preferred shared side", function()
	local value = assert(projection.build(entry("before\nold\nafter\n", "before\nnew\nafter\n", {
		old_path = "before.lua",
		new_path = "after.lua",
	})))
	local shared = assert(projection.resolve_range(value, 1, 1))
	assert(shared.side == "new" and shared.path == "after.lua" and shared.start_line == 1)
	local preferred = assert(projection.resolve_range(value, 1, 1, "left"))
	assert(preferred.side == "old" and preferred.path == "before.lua" and preferred.start_line == 1)
	local old_with_context = assert(projection.resolve_range(value, 1, 2))
	assert(old_with_context.side == "old" and old_with_context.start_line == 1 and old_with_context.end_line == 2)
	local new_with_context = assert(projection.resolve_range(value, 3, 4))
	assert(new_with_context.side == "new" and new_with_context.start_line == 2 and new_with_context.end_line == 3)
	local mixed, mixed_err = projection.resolve_range(value, 2, 3)
	assert(mixed == nil and mixed_err:find("OLD-only and NEW-only", 1, true), mixed_err)
end)

test("BOF and EOF additions and deletions keep exact display order", function()
	local added = assert(projection.build(entry("middle\n", "head\nmiddle\ntail\n")))
	assert(
		vim.deep_equal(row_shape(added), {
			{ kind = "new", text = "head", new_line = 1 },
			{ kind = "context", text = "middle", old_line = 1, new_line = 2 },
			{ kind = "new", text = "tail", new_line = 3 },
		}),
		vim.inspect(row_shape(added))
	)
	assert(added.hunks[1].first == 1 and added.hunks[1].last == 1)
	assert(added.hunks[2].first == 3 and added.hunks[2].last == 3)

	local deleted = assert(projection.build(entry("head\nmiddle\ntail\n", "middle\n")))
	assert(
		vim.deep_equal(row_shape(deleted), {
			{ kind = "old", text = "head", old_line = 1 },
			{ kind = "context", text = "middle", old_line = 2, new_line = 1 },
			{ kind = "old", text = "tail", old_line = 3 },
		}),
		vim.inspect(row_shape(deleted))
	)
end)

test("line-ending and final-newline changes remain distinct real rows", function()
	local value = assert(projection.build(entry("same\r\nnext\r\n", "same\nnext")))
	assert(value.sources.old.fileformat == "dos" and value.sources.old.endofline)
	assert(value.sources.new.fileformat == "unix" and not value.sources.new.endofline)
	assert(reconstruct(value.sources.old) == "same\r\nnext\r\n")
	assert(reconstruct(value.sources.new) == "same\nnext")
	assert(#value.rows == 4, vim.inspect(row_shape(value)))
	assert(value.rows[1].kind == "old" and value.rows[1].terminator == "\r\n")
	assert(value.rows[2].kind == "old" and value.rows[2].terminator == "\r\n")
	assert(value.rows[3].kind == "new" and value.rows[3].terminator == "\n")
	assert(value.rows[4].kind == "new" and value.rows[4].terminator == "")

	local final_newline = assert(projection.build(entry("same\n", "same")))
	assert(vim.deep_equal(row_shape(final_newline), {
		{ kind = "old", text = "same", old_line = 1 },
		{ kind = "new", text = "same", new_line = 1 },
	}))
	assert(final_newline.rows[1].terminator == "\n" and final_newline.rows[2].terminator == "")
end)

test("renames anchor unchanged rows to NEW while retaining both reverse maps", function()
	local value = assert(projection.build(entry("one\ntwo\n", "one\ntwo\n", {
		old_path = "before.lua",
		new_path = "after.lua",
	})))
	assert(#value.rows == 2 and value.rows[1].kind == "context")
	assert(value.rows[1].old_path == "before.lua" and value.rows[1].new_path == "after.lua")
	local source = assert(projection.source_at(value, 1))
	assert(
		source.side == "new"
			and source.path == "after.lua"
			and source.old_path == "before.lua"
			and source.new_path == "after.lua"
			and source.source_line == 1
	)
	assert(projection.locate(value, "old", 2, "before.lua") == 2)
	assert(projection.locate(value, "new", 2, "after.lua") == 2)
	local missing, missing_err = projection.locate(value, "old", 1, "after.lua")
	assert(missing == nil and missing_err:find("path", 1, true), missing_err)
end)

test("added deleted and empty files expose only valid source anchors", function()
	local added = assert(projection.build(entry("", "new\n", { old_path = false, new_path = "added.lua" })))
	assert(#added.rows == 1 and added.rows[1].kind == "new" and added.rows[1].new_line == 1)
	local deleted = assert(projection.build(entry("old\n", "", { old_path = "deleted.lua", new_path = false })))
	assert(#deleted.rows == 1 and deleted.rows[1].kind == "old" and deleted.rows[1].old_line == 1)

	local empty_added = assert(projection.build(entry("", "", {
		old_path = false,
		new_path = "empty.lua",
		hunks = {},
	})))
	local source = assert(projection.source_at(empty_added, 1))
	assert(source.kind == "empty" and source.side == "new" and source.source_line == 0 and not source.anchorable)
	local range, range_err = projection.resolve_range(empty_added, 1, 1)
	assert(range == nil and range_err:find("file comment", 1, true), range_err)

	local empty_deleted = assert(projection.build(entry("", "", {
		old_path = "empty.lua",
		new_path = false,
		hunks = {},
	})))
	assert(empty_deleted.rows[1].anchor_side == "old" and empty_deleted.rows[1].path == "empty.lua")
end)

test("malformed supplied hunks fail validation instead of drifting", function()
	local value, err = projection.build(entry("one\ntwo\n", "one\nchanged\n", {
		hunks = { { 2, 1, 1, 1 } },
	}))
	assert(value == nil and err:find("unequal unchanged prefixes", 1, true), err)
	value, err = projection.build(entry("one\n", "one\n", { hunks = { { 4, 1, 4, 1 } } }))
	assert(value == nil and err:find("boundary", 1, true), err)
	value, err = projection.build(entry("one\n", "changed\n", { hunks = { { 1, 0, 1, 0 } } }))
	assert(value == nil and err:find("invalid indices", 1, true), err)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_projection_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
