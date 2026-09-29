vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "

local repo = vim.fn.getcwd()
local plugin_root = vim.env.NVIM_CONFIG_MD_RENDER_ROOT
	or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "md-render.nvim")
assert(vim.uv.fs_stat(plugin_root), "md-render.nvim checkout is required for markdown_view_spec")
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	plugin_root .. "/lua/?.lua",
	plugin_root .. "/lua/?/init.lua",
	package.path,
}, ";")

local pinned = "cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74"
package.loaded["config.lazy_lock"] = {
	plugin = function()
		return { branch = "main", commit = pinned }
	end,
}

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

local function contains(buf, fragment)
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(fragment, 1, true) then
			return true
		end
	end
	return false
end

local function table_text(buf)
	local parts = {}
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find("│", 1, true) then
			parts[#parts + 1] = line:gsub("│", ""):gsub("─", ""):gsub("%s", "")
		end
	end
	return table.concat(parts)
end

local function has_highlight(buf, group)
	for _, ns in pairs(vim.api.nvim_get_namespaces()) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
			if mark[4].hl_group == group then
				return true
			end
		end
	end
	return false
end

local function has_code_label(buf, language)
	local ns = vim.api.nvim_get_namespaces().nvim_config_markdown_codeblocks
	assert(ns, "code-block decoration namespace is missing")
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local detail = mark[4]
		if detail.virt_lines then
			for _, row in ipairs(detail.virt_lines) do
				for _, chunk in ipairs(row) do
					if chunk[1]:find(language, 1, true) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function assert_render_winhighlight(win)
	local current = vim.wo[win].winhighlight
	assert(current:find("Normal:NormalFloat", 1, true), "render lost an existing Normal mapping")
	assert(current:find("String:MdRenderCodeBlock", 1, true), "render lacks its window-only String mapping")
	assert(not current:find("String:ErrorMsg", 1, true), "render retained the old String mapping")
	local _, count = current:gsub("String:MdRenderCodeBlock", "")
	assert(count == 1, "render duplicated its String mapping")
end

local pager = require("config.pager")
pager.active = false
local view = require("config.markdown_view")

test("pinned renderer installs a media-free reading mode", function()
	assert(view.PIN == pinned, "host pin drifted")
	assert(view.configure_renderer(), "pinned renderer could not initialize")
	assert(not require("md-render.image").supports_kitty(), "automatic media remained enabled")
	require("config.viewer_commands")
	assert(vim.fn.exists(":MarkdownView") == 2, "MarkdownView command is missing")
end)

test("editor opens one focused, live, read-only tab and preserves the editable source", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"# Original heading",
		"",
		"```mermaid",
		"graph LR; A-->B",
		"```",
		"![remote](https://example.invalid/image.png)",
	})
	vim.bo[source].filetype = "markdown"
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>mv", "n", false, true)), "source view mapping is missing")
	local source_win = vim.api.nvim_get_current_win()
	local source_tab = vim.api.nvim_get_current_tabpage()
	local prior_winhighlight = vim.wo[source_win].winhighlight
	local source_winhighlight = "Normal:NormalFloat,String:ErrorMsg,StatusLine:StatusLineNC"
	vim.wo[source_win].winhighlight = source_winhighlight
	local system = vim.system
	local external_media = {}
	vim.system = function(argv, opts, callback)
		if argv[1] == "npx" or argv[1] == "curl" then
			external_media[#external_media + 1] = argv[1]
		end
		return system(argv, opts, callback)
	end

	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == 2, "MarkdownView did not create exactly one new tab")
	local render_tab = vim.api.nvim_get_current_tabpage()
	assert(render_tab ~= source_tab, "reading view did not get its own tab")
	assert(#vim.api.nvim_tabpage_list_wins(render_tab) == 1, "reading view created a split")
	assert(#vim.api.nvim_tabpage_list_wins(source_tab) == 1, "reading view split the source tab")
	assert(vim.api.nvim_win_get_buf(source_win) == source, "source buffer was replaced")
	assert(vim.bo[source].modifiable, "source became noneditable")
	local render_win = vim.api.nvim_get_current_win()
	local render_buf = vim.api.nvim_win_get_buf(render_win)
	assert(vim.b[render_buf].md_render, "tab does not show md-render output")
	assert(not vim.bo[render_buf].modifiable and vim.bo[render_buf].readonly, "reading view is editable")
	assert(vim.wo[source_win].winhighlight == source_winhighlight, "render changed the editable source highlights")
	assert_render_winhighlight(render_win)
	assert(vim.wo[render_win].winhighlight:find("StatusLine:StatusLineNC", 1, true), "render lost another mapping")
	assert(has_highlight(render_buf, "String"), "rendered code block does not use the String highlight")
	assert(has_highlight(render_buf, "MdRenderCodeBlockBackground"), "rendered code has no shaded background")
	assert(has_code_label(render_buf, "mermaid"), "rendered code lost the fence language")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>mv", "n", false, true)), "render close mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "n", false, true)), "render diagram mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "x", false, true)), "render selection mapping is missing")

	vim.api.nvim_set_current_tabpage(source_tab)
	view.toggle()
	assert(vim.api.nvim_get_current_tabpage() == render_tab, "source invocation did not focus its existing view")
	assert(#vim.api.nvim_list_tabpages() == 2, "source invocation created another view")

	vim.api.nvim_buf_set_lines(source, 0, 1, false, { "# Updated heading" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	assert(
		vim.wait(1000, function()
			return contains(render_buf, "Updated heading")
		end),
		"unsaved source changes did not reach the reading view"
	)
	assert(#external_media == 0, "render started an automatic npx/curl job")

	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == 1, "second toggle did not close the view")
	assert(vim.api.nvim_get_current_tabpage() == source_tab, "closing render did not return to source tab")
	assert(vim.api.nvim_get_current_win() == source_win, "closing render did not restore source focus")
	assert(vim.wo[source_win].winhighlight == source_winhighlight, "closing render changed source highlights")
	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == 2, "reopening created the wrong number of tabs")
	local reopened = vim.api.nvim_get_current_win()
	assert(vim.b[vim.api.nvim_win_get_buf(reopened)].md_render, "reopened render window is missing")
	assert_render_winhighlight(reopened)
	view.toggle()
	assert(vim.wo[source_win].winhighlight == source_winhighlight, "reopening changed source highlights")
	vim.wo[source_win].winhighlight = prior_winhighlight
	vim.system = system
	vim.api.nvim_buf_delete(source, { force = true })
end)

test("manual tab close can reopen the live view", function()
	vim.cmd("tabonly")
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Reopen me" })
	vim.bo[source].filetype = "markdown"
	local source_tab = vim.api.nvim_get_current_tabpage()
	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == 2, "reading tab did not open")
	vim.cmd("tabclose")
	assert(vim.api.nvim_get_current_tabpage() == source_tab, "manual tab close did not return to source")
	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == 2, "reading tab did not reopen")
	assert(contains(vim.api.nvim_get_current_buf(), "Reopen me"), "reopened tab lost the source text")
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
end)

test("centered page reflows on resize and keeps links aligned", function()
	vim.cmd("tabonly")
	local columns = vim.o.columns
	vim.o.columns = 180
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"---",
		"title: Centered",
		"---",
		"",
		"A paragraph with [a link](https://example.com/centered).",
		"",
		"```lua",
		"print('hello')",
		"```",
		"",
		"---",
	})
	vim.bo[source].filetype = "markdown"
	local source_tab = vim.api.nvim_get_current_tabpage()
	view.toggle()
	local render_tab = vim.api.nvim_get_current_tabpage()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_get_current_buf()
	local session = assert(require("md-render").preview._toggle_sessions[source])
	local layout = require("config.markdown_layout")
	local expected_width, expected_margin = layout.measure(win)
	assert(expected_width == 120, "wide page did not cap at 120 columns")
	assert(session.opts.max_width == layout.render_width(expected_width), "renderer used the wrong page width")
	assert(session.opts.nvim_config_page_margin == expected_margin, "page has the wrong left margin")
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		assert(line:sub(1, expected_margin) == string.rep(" ", expected_margin), "page line is not centered")
		assert(vim.api.nvim_strwidth(line) <= expected_margin + expected_width, "render exceeded the 120-column page")
	end
	local link = assert(session.content.link_metadata[1], "rendered link has no metadata")
	assert(link.col_start >= expected_margin, "link metadata omitted the page margin")
	local function assert_link_extmark()
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, session.ns, 0, -1, { details = true })) do
			if mark[4].url == "https://example.com/centered" then
				assert(mark[3] == session.content.link_metadata[1].col_start, "clickable link misses rendered text")
				return
			end
		end
		error("clickable link extmark is missing")
	end
	assert_link_extmark()
	-- A user-created split narrows the render window without replacing the
	-- source tab. It also exercises ownership-safe preview closure below.
	vim.cmd("vnew")
	local user_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_width(win, 100)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_exec_autocmds("WinResized", {})
	expected_width, expected_margin = layout.measure(win)
	assert(expected_width < 120, "test split did not narrow the reading page")
	assert(session.opts.max_width == layout.render_width(expected_width), "resize did not update renderer width")
	assert(session.opts.nvim_config_page_margin == expected_margin, "resize did not recenter the page")
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		assert(line:sub(1, expected_margin) == string.rep(" ", expected_margin), "resize lost centering")
		assert(vim.api.nvim_strwidth(line) <= expected_margin + expected_width, "resize exceeded the page width")
	end
	assert_link_extmark()
	assert(has_code_label(buf, "lua"), "language label vanished after reflow")
	view.toggle()
	assert(vim.api.nvim_get_current_tabpage() == source_tab, "closing render did not return to source")
	assert(vim.api.nvim_tabpage_is_valid(render_tab), "closing render discarded a user-created split")
	assert(vim.api.nvim_win_is_valid(user_win), "closing render discarded the user's window")
	vim.api.nvim_set_current_tabpage(render_tab)
	vim.cmd("tabclose")
	vim.api.nvim_set_current_tabpage(source_tab)
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

test("page padding shifts every byte-column metadata field", function()
	local layout = require("config.markdown_layout")
	local content = {
		lines = { "abc", "xyz" },
		highlights = { { line = 0, groups = { { col = 0, end_col = 3 }, { col = 0, end_col = -1 } } } },
		link_metadata = { { line = 0, col_start = 1, col_end = 3 } },
		code_blocks = { { start_line = 1, end_line = 1, prefix_len = 2, source_lines = { "raw" } } },
		image_placements = { { line = 0, col = 1 } },
		text_placements = { { line = 0, col = 1, icon_col = 0 } },
		source_line_map = { 4, 5 },
		heading_anchors = { heading = 1 },
	}
	layout.center_content(content, { nvim_config_page_margin = 7 })
	assert(content.lines[1] == "       abc" and content.lines[2] == "       xyz", "text was not padded")
	assert(content.highlights[1].groups[1].col == 7, "highlight start was not shifted")
	assert(content.highlights[1].groups[1].end_col == 10, "highlight end was not shifted")
	assert(content.highlights[1].groups[2].end_col == -1, "end-of-line sentinel was changed")
	assert(content.link_metadata[1].col_start == 8 and content.link_metadata[1].col_end == 10, "link was not shifted")
	assert(content.code_blocks[1].prefix_len == 9, "Tree-sitter prefix was not shifted")
	assert(content.code_blocks[1].source_lines[1] == "raw", "original code source was changed")
	assert(content.image_placements[1].col == 8, "image column was not shifted")
	assert(
		content.text_placements[1].col == 8 and content.text_placements[1].icon_col == 7,
		"scaled text was not shifted"
	)
	assert(content.source_line_map[1] == 4 and content.heading_anchors.heading == 1, "row metadata changed")
end)

test("wide tables open without losing cell text and still allow manual collapse", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local columns = vim.o.columns
	vim.o.columns = 68
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"| Item | Description |",
		"| --- | --- |",
		"| A | A complete sentence that continues until the very end |",
		"| U | https://example.com/very/long/segment/without/spaces |",
	})
	vim.bo[source].filetype = "markdown"
	local source_win = vim.api.nvim_get_current_win()
	local source_tab = vim.api.nvim_get_current_tabpage()
	view.toggle()
	local win = vim.api.nvim_get_current_win()
	assert(vim.b[vim.api.nvim_win_get_buf(win)].md_render, "reading view did not open")
	local buf = vim.api.nvim_win_get_buf(win)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	assert(session.expand_state[1] == true, "table did not expand by default: " .. vim.inspect(session.expand_state))
	local parsed = assert(require("md-render").MarkdownTable.parse(vim.api.nvim_buf_get_lines(source, 0, -1, false)))
	assert(parsed.rows[2][2].text:find("spaces", 1, true), "parser shortened URL: " .. parsed.rows[2][2].text)
	local url_cell = parsed.rows[2][2]
	local url_link = assert(url_cell.links[1], "bare URL lost its link metadata")
	assert(url_cell.text:sub(url_link.col_start + 1, url_link.col_end) == url_link.url, "full URL link range is wrong")
	local labelled = assert(require("md-render").MarkdownTable.parse({
		"| Label |",
		"| --- |",
		"| [https://example…](https://example.com/whole) |",
	}))
	assert(labelled.rows[1][1].text == "https://example…", "an intentional short link label was changed")
	local direct = require("md-render").MarkdownTable.render(parsed, "", nil, false)
	assert(table.concat(direct):find("spaces", 1, true), "natural table shortened URL: " .. table.concat(direct))
	local text = table_text(buf)
	assert(text:find("Acompletesentencethatcontinuesuntiltheveryend", 1, true), "prose cell was shortened: " .. text)
	assert(
		text:find("https://example.com/very/long/segment/without/spaces", 1, true),
		"URL cell was shortened: " .. text
	)
	assert(not contains(buf, "…"), "expanded table still contains an ellipsis")
	assert(not vim.wo[win].wrap, "wide table cannot scroll horizontally")
	assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "table view opened beside the source")

	local row
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find("│ A ", 1, true) then
			row = i
			break
		end
	end
	assert(row, "table row was not rendered")
	local toggle
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if mapping.lhs == "<CR>" then
			toggle = mapping.callback
			break
		end
	end
	assert(type(toggle) == "function", "table expansion mapping is missing")
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_cursor(win, { row, 0 })
	toggle()
	assert(contains(buf, "…"), "manual table collapse did not take effect")
	toggle()
	assert(not contains(buf, "…"), "manual table expansion did not restore full content")
	vim.api.nvim_set_current_tabpage(source_tab)
	assert(vim.api.nvim_get_current_win() == source_win, "table view changed the source window")

	vim.api.nvim_buf_set_lines(source, 3, 4, false, { "| U | https://example.com/updated/fully |" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	assert(
		vim.wait(1000, function()
			return table_text(buf):find("https://example.com/updated/fully", 1, true) ~= nil
		end),
		"live update did not preserve the complete edited table cell"
	)
	vim.api.nvim_set_current_win(win)
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

test("pager opens wide Markdown tables with their complete cells", function()
	pager.active = true
	vim.cmd("only")
	local columns = vim.o.columns
	vim.o.columns = 46
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"---",
		"title: Table",
		"---",
		"",
		"| Name | Value |",
		"| --- | --- |",
		"| Kana | 長い日本語の文章を最後まで表示する |",
		"| URL | https://example.com/very/long/segment/without/spaces |",
		"| P | A long sentence with enough words to exceed the preview width and still reach the final token |",
	})
	vim.bo[source].filetype = "markdown"
	local win = vim.api.nvim_get_current_win()
	local source_wrap = vim.wo[win].wrap
	view.toggle()
	local buf = vim.api.nvim_win_get_buf(win)
	local text = table_text(buf)
	assert(text:find("長い日本語の文章を最後まで表示する", 1, true), "pager shortened the CJK cell")
	assert(
		text:find("https://example.com/very/long/segment/without/spaces", 1, true),
		"pager shortened the URL cell: " .. text
	)
	assert(text:find("stillreachthefinaltoken", 1, true), "frontmatter table was not fully expanded")
	assert(
		require("md-render").preview._toggle_sessions[source].expand_state[2] == true,
		"frontmatter table did not expand"
	)
	assert(not contains(buf, "…"), "pager table still contains an ellipsis")
	assert(not vim.wo[win].wrap, "pager table cannot scroll horizontally")
	local headers, separators, values = {}, {}, {}
	for column = 1, 20 do
		headers[column] = string.char(64 + column)
		separators[column] = "---"
		values[column] = column == 20 and "Z" or string.char(96 + column)
	end
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"| " .. table.concat(headers, " | ") .. " |",
		"| " .. table.concat(separators, " | ") .. " |",
		"| " .. table.concat(values, " | ") .. " |",
	})
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	assert(
		vim.wait(1000, function()
			return table_text(buf):find("Z", 1, true) ~= nil
		end),
		"pager did not preserve the last column of a wide table"
	)
	local text_width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
	local wider_than_window = false
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		wider_than_window = wider_than_window or vim.api.nvim_strwidth(line) > text_width
	end
	assert(
		wider_than_window and not vim.wo[win].wrap,
		"wide columns cannot be reached by horizontal scrolling: "
			.. vim.inspect({
				width = text_width,
				wrap = vim.wo[win].wrap,
				state = require("md-render").preview._toggle_sessions[source].expand_state,
				lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
			})
	)
	assert(not contains(buf, "…"), "wide table lost cell text")
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager did not restore its source")
	assert(vim.wo[win].wrap == source_wrap, "pager changed the source wrap setting")
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
	pager.active = false
end)

test("pager keeps the source for filetype changes and diagram extraction", function()
	pager.active = true
	vim.cmd("only")
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"# Diagram",
		"",
		"```mermaid",
		"graph LR; A-->B",
		"```",
	})
	vim.bo[source].filetype = "markdown"
	local win = vim.api.nvim_get_current_win()
	local prior_winhighlight = vim.wo[win].winhighlight
	local source_winhighlight = "Normal:NormalFloat,String:ErrorMsg"
	vim.wo[win].winhighlight = source_winhighlight
	pager.set_markdown_view(view)
	view.toggle()
	local rendered = vim.api.nvim_win_get_buf(win)
	assert(rendered ~= source and vim.b[rendered].md_render, "pager did not show the rendered document")
	assert(vim.bo[rendered].readonly and not vim.bo[rendered].modifiable, "pager render is editable")
	assert_render_winhighlight(win)
	assert(has_highlight(rendered, "String"), "pager code block does not use the String highlight")
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager manual toggle did not restore source")
	assert(vim.wo[win].winhighlight == source_winhighlight, "pager manual toggle did not restore highlights")
	view.toggle()
	assert_render_winhighlight(win)
	assert(vim.api.nvim_buf_is_valid(source), "pager discarded its Markdown source")
	local target = assert(view.diagram_target())
	assert(target.bufnr == source and target.row >= 1, "diagram extraction did not follow the source")
	assert(pager._apply_filetype(win, "text"), "picker could not change the rendered pager's source filetype")
	assert(vim.api.nvim_win_get_buf(win) == source, "pager did not reveal source for filetype change")
	assert(
		vim.wo[win].winhighlight == source_winhighlight,
		"picker did not restore source highlights: " .. vim.wo[win].winhighlight
	)
	vim.wait(100)
	assert(vim.api.nvim_win_get_buf(win) == source, "non-Markdown source was rendered")
	assert(pager._apply_filetype(win, "markdown"), "picker could not restore Markdown filetype")
	assert(
		vim.wait(1000, function()
			return vim.api.nvim_win_get_buf(win) ~= source
		end),
		"Markdown filetype change did not restore the reading view"
	)
	assert_render_winhighlight(win)
	vim.cmd("SetFileType text")
	assert(vim.api.nvim_win_get_buf(win) == source, "SetFileType did not recover the rendered source")
	assert(vim.wo[win].winhighlight == source_winhighlight, "SetFileType did not restore source highlights")
	assert(vim.bo[source].filetype == "text", "SetFileType did not replace the detected Markdown filetype")
	vim.cmd("SetFileType markdown")
	assert(
		vim.wait(1000, function()
			return vim.api.nvim_win_get_buf(win) ~= source
		end),
		"SetFileType did not restore automatic Markdown rendering"
	)
	assert_render_winhighlight(win)
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager mapping did not toggle back to source")
	assert(vim.wo[win].winhighlight == source_winhighlight, "pager did not restore highlights after re-render")
	vim.wo[win].winhighlight = prior_winhighlight
	vim.api.nvim_buf_delete(source, { force = true })
	pager.active = false
end)

test("missing private media guard fails closed", function()
	local image = require("md-render.image")
	local guard = image._set_kitty_supported
	image._set_kitty_supported = nil
	local configured = view.configure_renderer()
	assert(configured == nil, "view accepted a renderer without the media guard")
	local before = #vim.api.nvim_list_tabpages()
	view.toggle()
	assert(#vim.api.nvim_list_tabpages() == before, "view opened after media guard failure")
	image._set_kitty_supported = guard
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("markdown_view_spec: %d tests passed", count))
vim.cmd("quitall!")
