-- Real pinned-renderer snapshots, canonical anchors and screen geometry.
-- Run after screen allocation with -c 'lua dofile(...)', not -l.
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.o.lines = 44
vim.o.columns = 140
local root = vim.fn.getcwd()
local plugin = vim.env.NVIM_CONFIG_MD_RENDER_ROOT or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "md-render.nvim")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plugin)
vim.opt.runtimepath:prepend(vim.fs.joinpath(vim.fs.dirname(plugin), "nvim-treesitter", "runtime"))
require("config.local_plugins").setup()
local view = require("config.markdown_view")
assert(view.configure_renderer())
local review = require("config.native_review")
local markdown = require("native_review.markdown")
local adapter = require("config.review_markdown")
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
local failures, count = {}, 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end
local function entry(old, new)
	return {
		identity = "history\0sample.md\0sample.md",
		layer = "history",
		status = "M",
		old_path = "sample.md",
		new_path = "sample.md",
		path = "sample.md",
		old_text = old,
		new_text = new,
		old_oid = string.rep("1", 40),
		new_oid = string.rep("2", 40),
		old_mode = "100644",
		new_mode = "100644",
		hunks = vim.text.diff(old, new, { result_type = "indices" }),
	}
end
local function prepare(old, new, width)
	local value = entry(old, new)
	local before = vim.deepcopy(value)
	local result, err = markdown.prepare(value, width or 60)
	assert(result, err)
	assert(vim.deep_equal(before, value), "rendering changed the frozen Git entry")
	return result, value
end
local function changed_text(result, kind)
	local words = {}
	for _, row in ipairs(result.projection.rows) do
		if row.kind == kind then
			for _, range in ipairs(row.detail) do
				words[#words + 1] = row.text:sub(range.start_col + 1, range.end_col)
			end
		end
	end
	return table.concat(words)
end
test("visual words retain exact paragraph ranges on both sides", function()
	local result = prepare(
		"# Wait\n\nWait **30 seconds** before\ncontinuing.\n",
		"# Wait\n\nWait **60 seconds** before\ncontinuing.\n"
	)
	assert(result.status == "changed")
	assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
	local old_row, new_row
	for index, row in ipairs(result.projection.rows) do
		if row.kind == "old" then
			old_row = index
		elseif row.kind == "new" then
			new_row = index
		end
	end
	for _, index in ipairs({ old_row, new_row }) do
		local range = assert(review.projection.resolve_range(result.projection, index, index))
		assert(range.start_line == 3 and range.end_line == 4)
	end
	assert(not review.projection.resolve_range(result.projection, old_row, new_row))
end)
test("source wrapping, whitespace, link destinations and line endings can be visually equal", function()
	for _, values in ipairs({
		{ "Wait 30 seconds before\ncontinuing.\n", "Wait 30 seconds before continuing.\n" },
		{ "Wait 30 seconds.\n", "Wait  30 seconds.\n" },
		{ "[documentation](https://example.invalid/v1)\n", "[documentation](https://example.invalid/v2)\n" },
		{ "**bold** and _italic_\n", "**bold** and *italic*\n" },
		{ "# Heading\r\n\r\nText\r\n", "# Heading\n\nText" },
	}) do
		assert(prepare(values[1], values[2]).status == "unchanged", vim.inspect(values))
	end
end)
test("styles and structure remain visual changes", function()
	for _, values in ipairs({
		{ "**bold**\n", "bold\n" },
		{ "# Heading\n", "## Heading\n" },
		{ "- item\n", "1. item\n" },
		{ "```lua\nreturn 1\n```\n", "```python\nreturn 1\n```\n" },
	}) do
		assert(prepare(values[1], values[2]).status == "changed")
	end
end)
test("structural replacements keep whole-block emphasis", function()
	for _, values in ipairs({
		{ "# Heading\n", "## Heading\n" },
		{ "- item\n", "item\n" },
		{ "- item\n", "1. item\n" },
		{ "> quoted\n", "quoted\n" },
		{ "> quoted\n", "> > quoted\n" },
		{ "```lua\nreturn 1\n```\n", "```python\nreturn 1\n```\n" },
		{ "| Key |\n| --- |\n| old |\n", "| Key |\n| --- |\n| new |\n| extra |\n" },
	}) do
		local result, value = prepare(values[1], values[2])
		assert(result.status == "changed", vim.inspect(values))
		for _, rendered in ipairs({ result, assert(markdown.prepare(value, 12, result)) }) do
			assert(changed_text(rendered, "old") == "" and changed_text(rendered, "new") == "", vim.inspect(values))
		end
	end
	for _, values in ipairs({
		{ "# Wait 30\n", "# Wait 60\n" },
		{ "- Wait 30\n", "* Wait 60\n" },
	}) do
		local result = prepare(values[1], values[2])
		assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
	end
end)
test("ambiguous unmatched block runs keep whole-block emphasis after resize", function()
	for _, values in ipairs({
		{ "Alpha old paragraph.\n\nBeta old paragraph.\n\nTail\n", "Beta new paragraph.\n\nTail\n" },
		{ "Alpha old paragraph.\n\nTail\n", "Alpha new paragraph.\n\nBeta new paragraph.\n\nTail\n" },
		{
			"Alpha old paragraph.\n\nBeta old paragraph.\n\nTail\n",
			"Alpha new paragraph.\n\nBeta new paragraph.\n\nTail\n",
		},
	}) do
		local result, value = prepare(values[1], values[2])
		assert(result.status == "changed")
		local resized = assert(markdown.prepare(value, 12, result))
		assert(resized.comparison == result.comparison)
		for _, rendered in ipairs({ result, resized }) do
			assert(changed_text(rendered, "old") == "" and changed_text(rendered, "new") == "")
		end
	end
end)
test("table cells have word detail and never truncate", function()
	local result =
		prepare("| Key | Value |\n| --- | --- |\n| delay | 30 |\n", "| Key | Value |\n| --- | --- |\n| delay | 60 |\n")
	assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
	local long = string.rep("a", 80)
	local narrow = prepare(
		"| Key | Value |\n| --- | --- |\n| delay | " .. long .. " |\n",
		"| Key | Value |\n| --- | --- |\n| delay | " .. long .. " |\n",
		20
	)
	assert(narrow.status == "unchanged")
	for _, row in ipairs(narrow.projection.rows) do
		assert(vim.fn.strdisplaywidth(row.text) <= 20 and not row.text:find("…", 1, true))
	end
end)
test("a table cell change marks only its logical row across widths", function()
	local before = "| Key | Value |\n| --- | --- |\n| alpha | stable |\n| delay | 30 |\n| gamma | stable |\n"
	for _, replacement in ipairs({ "60", "a much longer changed value" }) do
		local result, value = prepare(before, (before:gsub("30", replacement)))
		local comparison = result.comparison
		for _, width in ipairs({ 60, 24, 14, 8, 4, 60 }) do
			result = assert(markdown.prepare(value, width, result))
			assert(result.comparison == comparison)
			assert(#result.projection.hunks == 1)
			for _, row in ipairs(result.projection.rows) do
				if row.kind == "old" or row.kind == "new" then
					local range = assert(row[row.kind .. "_range"])
					assert(range.first == 4 and range.last == 4, "unchanged table row was marked as changed")
				end
			end
			for _, line in ipairs({ 1, 2, 3, 5 }) do
				local old_row = assert(result.projection.by_source.old[line])
				local new_row = assert(result.projection.by_source.new[line])
				assert(old_row == new_row and result.projection.rows[new_row].kind == "context")
			end
			if replacement == "60" then
				assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
			end
		end
	end
end)
test("table row insertion and deletion retain shifted and repeated context rows", function()
	local before =
		"| Key | Value |\n| --- | --- |\n| alpha | stable |\n| beta | stable |\n| beta | stable |\n| gamma | stable |\n"
	local after = before:gsub("| alpha | stable |\n", "| alpha | stable |\n| inserted | new |\n", 1)
	for _, deleted in ipairs({ false, true }) do
		local result, value = prepare(deleted and after or before, deleted and before or after)
		local comparison = result.comparison
		for _, width in ipairs({ 60, 20, 4, 60 }) do
			result = assert(markdown.prepare(value, width, result))
			assert(result.comparison == comparison)
			local changed_side = deleted and "old" or "new"
			for _, row in ipairs(result.projection.rows) do
				if row.kind == "old" or row.kind == "new" then
					local range = assert(row[row.kind .. "_range"])
					assert(row.kind == changed_side and range.first == 4 and range.last == 4)
				end
			end
			for line = 4, 6 do
				local lhs = result.projection.by_source.old[deleted and line + 1 or line]
				local rhs = result.projection.by_source.new[deleted and line or line + 1]
				assert(lhs == rhs and result.projection.rows[assert(lhs)].kind == "context")
			end
			local footer = result.projection.rows[#result.projection.rows]
			assert(footer.kind == "context" and not footer.anchorable)
		end
	end
end)
test("wrapped table rows anchor one source line and border frames have no anchor", function()
	local before =
		"| Alpha | Beta | Gamma | Delay |\n| --- | --- | --- | --- |\n| one | two | three | 30 |\n| four | five | six | 40 |\n"
	local result, value = prepare(before, (before:gsub("30", "60")))
	for _, width in ipairs({ 60, 20, 4 }) do
		result = assert(markdown.prepare(value, width, result))
		for _, projection in ipairs({ result.projection, result.split_projections.old, result.split_projections.new }) do
			for _, side in ipairs({ "old", "new" }) do
				local first, last
				for index, row in ipairs(projection.rows) do
					local range = row[side .. "_range"]
					if range and range.first == 3 then
						first, last = first or index, index
					end
				end
				if first then
					local range = assert(review.projection.resolve_range(projection, first, last, side))
					assert(range.start_line == 3 and range.end_line == 3)
				end
			end
			assert(not review.projection.resolve_range(projection, #projection.rows, #projection.rows))
		end
	end
end)
test("table row blocks preserve surrounding spacing and visible content", function()
	local text = "Before\n\n| Key | Value |\n| --- | --- |\n| alpha | stable |\n| beta | stable |\n\nAfter\n"
	for _, width in ipairs({ 60, 20, 4 }) do
		local snapshot = assert(adapter.build_snapshot({ text = text, path = "sample.md", width = width }))
		local tables = 0
		for _, block in ipairs(snapshot.blocks) do
			if block.table_rows then
				tables = tables + 1
				local flattened = {}
				for _, row in ipairs(block.table_rows.blocks) do
					vim.list_extend(flattened, row.lines)
				end
				assert(vim.deep_equal(flattened, block.lines), "row expansion lost table content or spacing")
			end
		end
		assert(tables == 1)
		assert(prepare(text, text, width).status == "unchanged")
	end
end)
test("table word spans survive grid, field/value and very narrow reflow", function()
	for _, before in ipairs({
		"| Alpha | Beta | Gamma | Delay |\n| --- | --- | --- | --- |\n| one | two | three | 30 |\n",
		"| Café│日本語 | Beta | Gamma | Delay |\n| --- | --- | --- | --- |\n| one │ two | | same | **30** |\n| other | | same | **30** |\n",
		"| | |\n| --- | --- |\n| 30 | value |\n",
	}) do
		local result, value = prepare(before, (before:gsub("30", "60", 1)))
		local comparison = result.comparison
		for _, width in ipairs({ 60, 30, 24, 20, 14, 8, 4, 60 }) do
			result = assert(markdown.prepare(value, width, result))
			assert(result.comparison == comparison and result.status == "changed")
			assert(
				changed_text(result, "old") == "30" and changed_text(result, "new") == "60",
				("width %d lost or misassigned table word spans"):format(width)
			)
			for _, row in ipairs(result.projection.rows) do
				assert(vim.fn.strdisplaywidth(row.text) <= width)
			end
		end
	end
end)
test("stacked tables highlight repeated changed headers beside every source row", function()
	local before =
		"| Alpha | Beta | Gamma | Delay |\n| --- | --- | --- | --- |\n| one | two | three | 30 |\n| four | five | six | 40 |\n"
	local result, value = prepare(before, (before:gsub("Delay", "Delay v2")))
	assert(changed_text(result, "new") == " v2")
	local resized = assert(markdown.prepare(value, 20, result))
	assert(resized.comparison == result.comparison)
	assert(changed_text(resized, "new") == "v2v2", changed_text(resized, "new"))
	assert(changed_text(resized, "old") == "")
end)
test("resize preserves visual equality and code bytes while reflowing", function()
	local text = "# Title\n\nA paragraph with **styled words** and a longlonglonglonglongword.\n\n```lua\nlocal value = '"
		.. string.rep("a", 100)
		.. "'\n```\n"
	local signatures
	for _, width in ipairs({ 18, 40, 90 }) do
		local document = assert(adapter.build_snapshot({ text = text, width = width, path = "sample.md" }))
		local current = vim.tbl_map(function(block)
			return block.fingerprint
		end, document.blocks)
		if signatures then
			assert(vim.deep_equal(signatures, current), "width changed visual signatures")
		end
		signatures = current
		assert(prepare(text, text, width).status == "unchanged")
		for _, block in ipairs(document.blocks) do
			for _, line in ipairs(block.lines) do
				assert(vim.fn.strdisplaywidth(line) <= width)
			end
		end
	end
end)
test("media references stay visible and cannot access live files or network", function()
	local image = require("md-render.image")
	local resolve = image.resolve
	local bad = {
		{ "![local](example.png)", "![local](example.png)" },
		{ "![remote](https://example.invalid/image.png)", "![remote](https://example.invalid/image.png)" },
		{ "<img src='https://example.invalid/image.png'>", "![image](https://example.invalid/image.png)" },
		{ "![local][ref]\n\n[ref]: example.png", "![local](example.png)" },
		{ "![local]\n\n[local]: example.png", "![local](example.png)" },
	}
	local system, expand, dimensions = vim.system, vim.fn.expand, image.image_dimensions
	local function forbidden(...)
		error(debug.traceback("review accessed a media resource: " .. vim.inspect({ ... })))
	end
	vim.system, vim.fn.expand, image.image_dimensions = forbidden, forbidden, forbidden
	local ok, err = xpcall(function()
		for _, values in ipairs(bad) do
			local doc = assert(adapter.build_snapshot({ text = values[1] .. "\n", width = 100, path = "sample.md" }))
			assert(vim.tbl_contains(doc.blocks[1].lines, "  " .. values[2]))
		end
		assert(prepare("```mermaid\nA-->B\n```\n", "```plantuml\nA-->B\n```\n").status == "changed")
	end, debug.traceback)
	vim.system, vim.fn.expand, image.image_dimensions = system, expand, dimensions
	assert(ok, err)
	assert(prepare("![image][ref]\n\n[ref]: old.png\n", "![image][ref]\n\n[ref]: new.png\n").status == "changed")
	local code =
		assert(adapter.build_snapshot({ text = "`![no](image.png)`\n\n```md\n![no](image.png)\n```\n", width = 40 }))
	for _, block in ipairs(code.blocks) do
		for _, signature in ipairs(block.signature) do
			assert(signature[1] ~= "image-reference")
		end
	end
	assert(image.resolve == resolve, "review replaced the reading-view guard")
	assert(prepare("![image](old.png)\n", "![image](new.png)\n").status == "changed")
end)
test("footnotes anchor their complete definition and code receives word detail", function()
	local before = "Body[^x]\n\n[^x]: Wait 30 seconds\n  before continuing.\n\nTail\n"
	local after = before:gsub("30", "60")
	local result = prepare(before, after, 24)
	for index, row in ipairs(result.projection.rows) do
		if row.text:find("Wait", 1, true) then
			local range = assert(review.projection.resolve_range(result.projection, index, index))
			assert(range.start_line == 3 and range.end_line == 4)
		end
	end
	assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
	local code = prepare("```lua\nreturn 30\n```\n", "```lua\nreturn 60\n```\n", 8)
	assert(changed_text(code, "old") == "30" and changed_text(code, "new") == "60")
end)
test("resize reuses comparison and maps word edits through fresh Unicode rows", function()
	local result, value = prepare("日本語 café é **30**\n\n---\n", "日本語 café é **60**\n\n---\n", 60)
	local resized = assert(markdown.prepare(value, 8, result))
	assert(resized.comparison == result.comparison, "resize reran the comparison")
	assert(changed_text(resized, "old") == "30" and changed_text(resized, "new") == "60")
	for _, row in ipairs(resized.projection.rows) do
		assert(vim.fn.strdisplaywidth(row.text) <= 8)
	end
end)
test("added, deleted and empty documents have only real block anchors", function()
	for _, deleted in ipairs({ false, true }) do
		local value = entry(deleted and "Text\n" or "", deleted and "" or "Text\n")
		if deleted then
			value.new_path = nil
		else
			value.old_path = nil
		end
		value.deleted = deleted
		local result = assert(markdown.prepare(value, 50))
		local filler = deleted and result.split_projections.new or result.split_projections.old
		assert(not review.projection.resolve_range(filler, 1, 1))
	end
	assert(prepare("", "").status == "unchanged")
end)
test("rendered selections cannot skip hidden source or reverse original block order", function()
	local text = "# Heading\n\n[ref]: https://example.invalid\n\nParagraph\n"
	local result = prepare(text, text)
	local projection = result.projection
	assert(not review.projection.resolve_range(projection, projection.by_source.new[1], projection.by_source.new[5]))
	local adjacent = "# Heading\n\nParagraph\n"
	projection = prepare(adjacent, adjacent).projection
	local range = assert(review.projection.resolve_range(projection, 1, #projection.rows))
	assert(range.start_line == 1 and range.end_line == 3)
	local upward = assert(review.projection.resolve_range(projection, #projection.rows, 1))
	assert(vim.deep_equal(range, upward), "upward Visual selection lost its normalized source range")
	local reordered = "Body[^x]\n\n[^x]: Earlier definition\n\nTail\n"
	projection = prepare(reordered, reordered).projection
	local tail, definition
	for index, row in ipairs(projection.rows) do
		if row.new_range and row.new_range.first == 5 then
			tail = index
		elseif tail and row.new_range and row.new_range.first == 3 then
			definition = index
			break
		end
	end
	assert(tail and definition, "fixture has no footnote shown after a later source block")
	local reordered_rows = vim.deepcopy(projection)
	-- Isolate the two actual anchored rows from the footnote separator.
	reordered_rows.rows = { projection.rows[tail], projection.rows[definition] }
	local invalid, err = review.projection.resolve_range(reordered_rows, 1, 2)
	assert(not invalid and err == "rendered selection reverses source order")
	local large = string.rep("word ", 4200)
	local bounded = prepare(large .. "old\n", large .. "new\n")
	assert(bounded.status == "changed" and changed_text(bounded, "old") == "" and changed_text(bounded, "new") == "")
end)
test("inline and split preserve read-only buffers, block anchors and screen alignment", function()
	local before = "# Title\n\nA short old paragraph.\n\n```lua\nreturn 1\n```\n\nTail\n"
	local after =
		"# Title\n\nA longer new paragraph that occupies several rows when wrapped.\n\n```lua\nreturn 2\n```\n\nTail\n"
	for _, layout in ipairs({ "inline", "split" }) do
		for _, context in ipairs({ "full", "hunks" }) do
			vim.cmd("enew!")
			local value = entry(before, after)
			local state = review.mode.new({ root = fixture, model = { entries = { value } } })
			assert(review.mode.enable(state))
			local ok, err = xpcall(function()
				assert(
					review.presenter.show(
						state,
						value,
						{ layout = layout, context = context, markdown_view = "render" }
					)
				)
				local p = state.presentation
				assert(p.origin_engine.id == "markdown-visual")
				for _, pane in ipairs(p.inline and { p.inline } or { p.left, p.right }) do
					assert(vim.bo[pane.buf].readonly and not vim.bo[pane.buf].modifiable)
					assert(review.lsp.blocked(pane.buf) and vim.b[pane.buf].nvim_review_role == "markdown")
					assert(not vim.wo[pane.win].diff and not vim.wo[pane.win].wrap)
				end
				if p.right then
					local function aligned()
						vim.cmd("redraw!")
						local lhs = p.left.projection.by_source.old[9]
						local rhs = p.right.projection.by_source.new[9]
						assert(
							vim.fn.screenpos(p.left.win, lhs, 1).row == vim.fn.screenpos(p.right.win, rhs, 1).row,
							"tail blocks are misaligned"
						)
					end
					aligned()
					vim.api.nvim_win_set_width(p.left.win, 38)
					vim.api.nvim_exec_autocmds("VimResized", {})
					vim.wait(30, function()
						return false
					end, 5)
					p = state.presentation
					aligned()
					vim.api.nvim_win_call(p.right.win, function()
						vim.cmd("normal! 2\5")
					end)
					vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(p.right.win) })
					aligned()
				end
			end, debug.traceback)
			review.mode.disable(state)
			assert(ok, err)
		end
	end
end)
test("table backgrounds and visible split alignment follow rows after resize", function()
	local before = "| Key | Value |\n| --- | --- |\n| alpha | stable |\n| delay | 30 |\n| gamma | stable |\n"
	local after = before:gsub("30", "a much longer changed value that wraps")
	for _, layout in ipairs({ "inline", "split" }) do
		for _, context in ipairs({ "full", "hunks" }) do
			vim.cmd("enew!")
			local value = entry(before, after)
			local state = review.mode.new({ root = fixture, model = { entries = { value } } })
			assert(review.mode.enable(state))
			local ok, err = xpcall(function()
				assert(
					review.presenter.show(
						state,
						value,
						{ layout = layout, context = context, markdown_view = "render" }
					)
				)
				local comparison = state.presentation.engine_result.comparison
				for _, resize in ipairs({ false, true }) do
					local p = state.presentation
					if resize then
						vim.api.nvim_win_set_width((p.left or p.inline).win, 32)
						vim.api.nvim_exec_autocmds("VimResized", {})
						vim.wait(30, function()
							return false
						end, 5)
						p = state.presentation
						assert(p.engine_result.comparison == comparison)
					end
					for _, item in ipairs(p.decorations) do
						local projection = p.inline and p.projection
							or (item.buf == p.left.buf and p.left.projection or p.right.projection)
						for _, mark in
							ipairs(vim.api.nvim_buf_get_extmarks(item.buf, item.namespace, 0, -1, { details = true }))
						do
							local group = mark[4].hl_group
							if group == "NvimReviewNativeDiffOld" or group == "NvimReviewNativeDiffNew" then
								local row = projection.rows[mark[2] + 1]
								local range = row[row.kind .. "_range"]
								assert(
									range and range.first == 4 and range.last == 4,
									"unchanged table row received a diff background"
								)
							end
						end
					end
					if p.right then
						local lhs, rhs = p.left.projection.by_source.old[5], p.right.projection.by_source.new[5]
						vim.api.nvim_win_set_cursor(p.right.win, { rhs, 0 })
						vim.cmd("redraw!")
						vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(p.right.win) })
						vim.cmd("redraw!")
						local left, right = vim.fn.screenpos(p.left.win, lhs, 1), vim.fn.screenpos(p.right.win, rhs, 1)
						assert(
							left.row > 0 and right.row > 0 and left.row == right.row,
							"table context rows are not visibly aligned"
						)
					end
				end
			end, debug.traceback)
			review.mode.disable(state)
			assert(ok, err)
		end
	end
end)
test("code edits mark only original lines across containers and widths", function()
	local body = "local stable = 1\nlocal delay = 30\nreturn stable\n"
	for _, sample in ipairs({
		{ "```lua\n" .. body .. "```\n", 3 },
		{ "```\n" .. body .. "```\n", 3 },
		{ "```unknown-language\n" .. body .. "```\n", 3 },
		{ "> ```lua\n> " .. body:gsub("\n", "\n> ") .. "```\n", 3 },
		{ "- intro\n\n  ```lua\n  " .. body:gsub("\n", "\n  ") .. "```\n", 5 },
	}) do
		local result, value = prepare(sample[1], (sample[1]:gsub("30", "60")))
		local comparison = result.comparison
		for _, width in ipairs({ 60, 24, 8, 4, 60 }) do
			result = assert(markdown.prepare(value, width, result))
			assert(result.comparison == comparison, "resize reclassified code lines")
			assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
			for index, row in ipairs(result.projection.rows) do
				if row.kind == "old" or row.kind == "new" then
					local range = assert(review.projection.resolve_range(result.projection, index, index))
					assert(
						range.start_line == sample[2] and range.end_line == sample[2],
						"unchanged code received an edit"
					)
				end
			end
			for _, side in ipairs({ "old", "new" }) do
				for _, source in ipairs({ sample[2] - 1, sample[2] + 1 }) do
					local row = result.projection.rows[assert(result.projection.by_source[side][source])]
					assert(row.kind == "context", "stable code line lost context")
				end
			end
		end
	end
end)
test("inserted and deleted code lines preserve repeated and blank context", function()
	local before = "```lua\nprint('repeat')\n\nprint('repeat')\nreturn 1\n```\n"
	local after = before:gsub("\n\n", "\n\nlocal added = 2\n")
	for _, deleted in ipairs({ false, true }) do
		local result, value = prepare(deleted and after or before, deleted and before or after)
		for _, width in ipairs({ 60, 8, 4 }) do
			result = assert(markdown.prepare(value, width, result))
			local changed, stable = 0, 0
			for _, row in ipairs(result.projection.rows) do
				if row.kind == "old" or row.kind == "new" then
					local side = deleted and "old" or "new"
					assert(row.kind == side and row[side .. "_range"].first == 4 and row[side .. "_range"].last == 4)
					changed = changed + 1
				elseif row.old_range and row.old_range.kind == "code_line" then
					stable = stable + 1
				end
			end
			assert(changed > 0 and stable >= 4)
		end
	end
end)
test("code line blocks preserve text, spacing, labels and exact wrapped anchors", function()
	local text =
		"Before\n\n```lua\nlocal message = '日本語 café é longlonglongword'\n\nreturn message\n```\n\nAfter\n"
	for _, width in ipairs({ 60, 18, 4 }) do
		local document = assert(adapter.build_snapshot({ text = text, width = width }))
		for _, block in ipairs(document.blocks) do
			if block.code_lines then
				local lines = {}
				for _, child in ipairs(block.code_lines.blocks) do
					vim.list_extend(lines, child.lines)
				end
				assert(vim.deep_equal(lines, block.lines), "line decomposition lost code or spacing")
			end
		end
		local result = prepare(text, (text:gsub("message", "changed")), width)
		for _, projection in ipairs({ result.projection, result.split_projections.old, result.split_projections.new }) do
			for index, row in ipairs(projection.rows) do
				if row.anchorable and (row.old_range or row.new_range).kind == "code_line" then
					local range = assert(review.projection.resolve_range(projection, index, index))
					assert(range.start_line == range.end_line)
				elseif not row.anchorable then
					assert(not review.projection.resolve_range(projection, index, index))
				end
			end
		end
	end
end)
test("syntax captures use full frozen fences, aliases and multiline byte ranges", function()
	for _, sample in ipairs({
		{ "lua", "local message = [[\n日本語 café é\n]]\nreturn 30", "lua", "@string.lua" },
		{ "py", "def value():\n    text = '''日本語\ncafé é'''\n    return 30", "python", "@string.python" },
		{ "sh", "echo '日本語 café é'\nsleep 30", "bash", "@string.bash" },
	}) do
		local text = "```" .. sample[1] .. "\n" .. sample[2] .. "\n```\n"
		local result, value = prepare(text, (text:gsub("30", "60")))
		for _, width in ipairs({ 60, 8, 4 }) do
			result = assert(markdown.prepare(value, width, result))
			for _, side in ipairs({ "old", "new" }) do
				local projection, syntax, strings = result.split_projections[side], 0, 0
				for _, entry in ipairs(projection.highlights) do
					for _, group in ipairs(entry.groups) do
						if group.syntax then
							syntax = syntax + 1
							assert(group.hl:sub(-#sample[3]) == sample[3] and group.priority > 4100)
							local line = projection.rows[entry.line + 1].text
							assert(group.col >= 0 and group.end_col <= #line and group.end_col > group.col)
							if group.hl == sample[4] then
								strings = strings + 1
							end
						end
					end
				end
				assert(syntax > 0 and strings > 0, "wrapped multiline code lost its language highlights")
			end
		end
	end
	local parser = vim.treesitter.get_string_parser
	vim.treesitter.get_string_parser = function(text, language, options)
		return language ~= "lua" and parser(text, language, options) or nil
	end
	local ok, err = xpcall(function()
		local result = prepare("```lua\nreturn 30\n```\n", "```lua\nreturn 60\n```\n")
		assert(changed_text(result, "old") == "30" and changed_text(result, "new") == "60")
	end, debug.traceback)
	vim.treesitter.get_string_parser = parser
	assert(ok, err)
end)
test("OLD multiline syntax cannot bleed into NEW code or change line identity", function()
	local before = "```py\ndef value():\n    text = '''open\n    return 30\n```\n"
	local after = before:gsub("'''open", "'''closed'''"):gsub("30", "60")
	local result = prepare(before, after)
	local projection = result.split_projections.new
	local line = assert(projection.by_source.new[4])
	local keyword, string = false, false
	for _, entry in ipairs(projection.highlights) do
		if entry.line == line - 1 then
			for _, group in ipairs(entry.groups) do
				keyword = keyword or group.hl:match("^@keyword.*%.python$") ~= nil
				string = string or group.hl == "@string.python"
			end
		end
	end
	assert(keyword and not string, "NEW code inherited OLD's unterminated string")
	local same = before:gsub("'''open", "'''closed'''")
	local unchanged_line = prepare(before, same).projection
	assert(
		unchanged_line.rows[assert(unchanged_line.by_source.new[4])].kind == "context",
		"syntax recoloring fabricated an edit"
	)
end)
test("code line backgrounds preserve visible syntax through layouts and resize", function()
	local before = "```lua\nlocal stable = 1\nlocal value = 30\nreturn stable\n```\n"
	local value = entry(before, (before:gsub("30", "60")))
	local previous = {}
	local colors = {
		Normal = { fg = 0xEEEEEE, bg = 0x101010 },
		DiffDelete = { bg = 0x301010 },
		DiffAdd = { bg = 0x103010 },
		MdRenderCodeBlockBackground = { bg = 0x151515 },
		["@keyword.lua"] = { fg = 0xC0FFEE },
		["@number.lua"] = { fg = 0x123ABC },
	}
	for name, definition in pairs(colors) do
		previous[name] = vim.api.nvim_get_hl(0, { name = name })
		vim.api.nvim_set_hl(0, name, definition)
	end
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "markdown-code-test" })
	vim.api.nvim__inspect_cell(1, 0, 0)
	local function attribute(item, line, column)
		local position = vim.fn.screenpos(item.win, line, column)
		assert(position.row > 0 and position.col > 0, "code cell is not visibly on screen")
		return vim.api.nvim__inspect_cell(1, position.row - 1, position.col - 1)[2]
	end
	local ok, err = xpcall(function()
		for _, layout in ipairs({ "inline", "split" }) do
			for _, context in ipairs({ "full", "hunks" }) do
				vim.cmd("enew!")
				local state = review.mode.new({ root = fixture, model = { entries = { value } } })
				assert(review.mode.enable(state))
				local shown, show_err = xpcall(function()
					assert(
						review.presenter.show(
							state,
							value,
							{ layout = layout, context = context, markdown_view = "render" }
						)
					)
					local comparison = state.presentation.engine_result.comparison
					for _, resize in ipairs({ false, true }) do
						if resize then
							vim.api.nvim_win_set_width((state.presentation.left or state.presentation.inline).win, 24)
							vim.api.nvim_exec_autocmds("VimResized", {})
							vim.wait(30, function()
								return false
							end, 5)
						end
						local p = state.presentation
						assert(p.engine_result.comparison == comparison)
						for _, item in ipairs(p.inline and { p.inline } or { p.left, p.right }) do
							vim.wo[item.win].cursorline = false
						end
						vim.cmd("redraw!")
						for _, item in ipairs(p.inline and { p.inline } or { p.left, p.right }) do
							local projection = item.projection or p.projection
							local changed = 0
							for line, row in ipairs(projection.rows) do
								if row.text:find("local", 1, true) then
									local keyword = attribute(item, line, assert(row.text:find("local", 1, true)))
									assert(keyword.foreground == 0xC0FFEE, "diff replaced keyword foreground")
									if row.kind == "context" then
										assert(keyword.background == 0x151515, "unchanged code has a diff background")
									end
								end
								if row.kind == "old" or row.kind == "new" then
									assert(row[row.kind .. "_range"].first == 3, "stable line is marked changed")
									local position = vim.fn.screenpos(item.win, line, 1)
									local background = attribute(item, line, 1).background
									for column = vim.fn.strdisplaywidth(row.text), p.engine_result.width - 1 do
										local padding = vim.api.nvim__inspect_cell(
											1,
											position.row - 1,
											position.col - 1 + column
										)[2]
										assert(
											padding.background == background,
											"code padding hid the line diff background"
										)
									end
									for _, range in ipairs(row.detail) do
										local number = attribute(item, line, range.start_col + 1)
										assert(
											number.foreground == 0x123ABC and number.background ~= 0x151515,
											"word diff lost visible syntax"
										)
										changed = changed + 1
									end
								end
							end
							assert(changed > 0)
						end
						if p.right then
							local lhs, rhs = p.left.projection.by_source.old[4], p.right.projection.by_source.new[4]
							vim.api.nvim_win_set_cursor(p.right.win, { rhs, 0 })
							vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(p.right.win) })
							vim.cmd("redraw!")
							local left, right =
								vim.fn.screenpos(p.left.win, lhs, 1), vim.fn.screenpos(p.right.win, rhs, 1)
							assert(
								left.row > 0 and right.row > 0 and left.row == right.row,
								"code context is not visibly aligned"
							)
						end
					end
				end, debug.traceback)
				review.mode.disable(state)
				assert(shown, show_err)
			end
		end
	end, debug.traceback)
	for name, definition in pairs(previous) do
		vim.api.nvim_set_hl(0, name, definition)
	end
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "markdown-code-restored" })
	assert(ok, err)
end)
test("renderer failure retains the previous presentation", function()
	vim.cmd("enew!")
	local value = entry("old\n", "new\n")
	local state = review.mode.new({ root = fixture, model = { entries = { value } } })
	assert(review.mode.enable(state))
	assert(review.presenter.show(state, value, { layout = "inline", context = "full" }))
	local previous = state.presentation
	local original = adapter.build_snapshot
	adapter.build_snapshot = function()
		return nil, "deliberate renderer failure"
	end
	local shown, err = review.presenter.show(state, value, { markdown_view = "render" })
	adapter.build_snapshot = original
	assert(not shown and err == "deliberate renderer failure" and state.presentation == previous)
	review.mode.disable(state)
end)
review.controller.teardown()
vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_markdown_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
