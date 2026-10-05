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

local function has_inline_fill(buf, group)
	for _, ns in pairs(vim.api.nvim_get_namespaces()) do
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
			local details = mark[4]
			if details.virt_text_pos == "inline" and details.virt_text and details.virt_text[1][2] == group then
				return true
			end
		end
	end
	return false
end

local function has_heading_cap(buf, cap, position)
	local ns = assert(vim.api.nvim_get_namespaces().nvim_config_markdown_codeblocks)
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local details = mark[4]
		if
			details.virt_text_pos == position
			and details.virt_text
			and details.virt_text[1][1] == cap
			and details.virt_text[1][2] == "MdRenderH1Edge"
		then
			return true
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

-- Widths of the virtual page margin drawn on each rendered row.
local function page_margins(buf)
	local namespace = require("config.markdown_layout").namespace
	local widths = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
		local details = mark[4]
		assert(mark[3] == 0 and details.virt_text_pos == "inline", "page margin is not inline at the row start")
		assert(widths[mark[2] + 1] == nil, "a row has more than one page margin")
		widths[mark[2] + 1] = vim.api.nvim_strwidth(details.virt_text[1][1])
	end
	return widths
end

local function assert_page_margin(buf, win, margin)
	local widths = page_margins(buf)
	for row = 1, vim.api.nvim_buf_line_count(buf) do
		assert(widths[row] == margin, ("row %d has margin %s, expected %d"):format(row, tostring(widths[row]), margin))
	end
	assert(vim.wo[win].breakindentopt == "shift:" .. margin, "wrapped rows do not continue after the margin")
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
require("config.markdown_navigation").setup({
	allowed = function()
		return true
	end,
	definition = function()
		return false
	end,
	marksman = function()
		return false
	end,
})

test("pinned renderer installs the guarded image policy", function()
	assert(view.PIN == pinned, "host pin drifted")
	assert(view.configure_renderer(), "pinned renderer could not initialize")
	local image = require("md-render.image")
	local supported = require("config.markdown_images").supported()
	assert(image.supports_kitty() == supported, "md-render ignored the detected image capability")
	assert(not image.has_mmdc() and not image.has_plantuml(), "diagram fences may execute renderers")
	assert(not image.is_video_file("clip.mp4"), "video may render automatically")
	-- The remaining specs exercise layout, not images; keep them terminal-independent.
	require("config.markdown_images")._reset({ supported = false })
	require("config.viewer_commands")
	assert(vim.fn.exists(":MarkdownView") == 2, "MarkdownView command is missing")
	assert(vim.fn.exists(":MarkdownImages") == 2, "MarkdownImages command is missing")
end)

test("editor opens one focused, live, read-only tab and preserves the editable source", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"# Original heading",
		"",
		"[jump](#original-heading)",
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
	assert(has_inline_fill(render_buf, "MdRenderCodeBlockBackground"), "code shading leaves a gap after the last cell")
	assert(has_highlight(render_buf, "MdRenderH1"), "heading text is not highlighted")
	assert(has_highlight(render_buf, "MdRenderH1Band"), "heading has no soft page-width band")
	assert(
		has_heading_cap(render_buf, "", "overlay") and has_heading_cap(render_buf, "", "inline"),
		"heading lost its rounded ends"
	)
	assert(has_code_label(render_buf, "mermaid"), "rendered code lost the fence language")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>mv", "n", false, true)), "render close mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "n", false, true)), "render diagram mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "x", false, true)), "render selection mapping is missing")
	local session = assert(require("md-render").preview._toggle_sessions[source])
	assert(session.opts.text_scale == false, "editor heading scale misaligns the pastel pill")
	assert(#session.content.text_placements == 0, "editor heading still paints terminal-scaled text")
	local anchor_link
	for _, link in ipairs(session.content.link_metadata) do
		if link.url == "#original-heading" then
			anchor_link = link
			break
		end
	end
	assert(anchor_link, "rendered heading link has no metadata")
	vim.api.nvim_win_set_cursor(render_win, { anchor_link.line + 1, anchor_link.col_start })
	local gd = vim.fn.maparg("gd", "n", false, true)
	assert(type(gd.callback) == "function", "rendered gd mapping is missing")
	gd.callback()
	assert(
		vim.api.nvim_win_get_cursor(render_win)[1] == session.content.heading_anchors["original-heading"] + 1,
		"gd did not follow the heading inside the reading view"
	)

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
	assert(vim.wo[win].wrap, "reading view permits horizontal scrolling")
	assert_page_margin(buf, win, expected_margin)
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		assert(vim.api.nvim_strwidth(line) <= expected_width, "render exceeded the 120-column page")
	end
	local blank_row, text_row
	for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line == " " then
			blank_row = blank_row or row
		elseif line:find("A paragraph", 1, true) then
			text_row = row
			assert(line:find("^  A paragraph"), "page margin leaked into the rendered text: " .. line)
		end
	end
	assert(blank_row, "blank row has no cursor cell after the margin")
	vim.api.nvim_win_set_cursor(win, { assert(text_row, "paragraph row is missing"), 0 })
	vim.cmd("normal! Vy")
	assert(vim.fn.getreg('"'):find("^  A paragraph"), "linewise yank copied the page margin")
	vim.cmd("normal! 30zl")
	assert(vim.fn.winsaveview().leftcol == 0, "reading view scrolled horizontally")
	local link = assert(session.content.link_metadata[1], "rendered link has no metadata")
	local link_line = vim.api.nvim_buf_get_lines(buf, link.line, link.line + 1, false)[1]
	assert(link_line:sub(link.col_start + 1, link.col_end) == "a link", "link metadata misses the rendered text")
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
	assert(vim.wo[win].wrap and vim.fn.winsaveview().leftcol == 0, "resize reenabled horizontal scrolling")
	assert_page_margin(buf, win, expected_margin)
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		assert(vim.api.nvim_strwidth(line) <= expected_width, "resize exceeded the page width")
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

-- Headless Neovim 0.12 aborts when it redraws two tab pages after 'columns'
-- changed at runtime, so screen checks use the startup width.
test("the cursor and Visual selections stay out of the page margin", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	assert(vim.o.columns == 80, "screen checks need the startup width")
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "First paragraph.", "", "Second paragraph." })
	vim.bo[source].filetype = "markdown"
	view.toggle()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local margin = assert(require("md-render").preview._toggle_sessions[source]).opts.nvim_config_page_margin
	assert(margin > 0, "an 80-column window has no page margin")
	local text_row, blank_row
	for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:match("^%s*$") then
			blank_row = blank_row or row
		elseif line:find("First paragraph", 1, true) then
			text_row = row
		end
	end
	assert(text_row and blank_row, "render lacks a text row or a blank row")
	for _, row in ipairs({ text_row, blank_row }) do
		vim.api.nvim_win_set_cursor(win, { row, 0 })
		vim.cmd("redraw")
		assert(vim.fn.wincol() == margin + 1, "the cursor sits in the page margin on row " .. row)
	end
	vim.api.nvim_win_set_cursor(win, { text_row, 0 })
	vim.cmd("redraw")
	local screen_row = vim.fn.screenpos(win, text_row, 1).row
	local text_column = margin + 3
	local idle = vim.fn.screenattr(screen_row, text_column)
	vim.cmd("normal! V")
	vim.cmd("redraw")
	local selected = vim.fn.screenattr(screen_row, text_column)
	assert(selected ~= idle, "Visual mode did not highlight the text")
	for column = 1, margin do
		assert(vim.fn.screenattr(screen_row, column) ~= selected, "Visual highlights the page margin")
	end
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
end)

test("the virtual page margin keeps rendered text and byte columns intact", function()
	local layout = require("config.markdown_layout")
	local content = {
		lines = { "abc", "xyz", "" },
		highlights = { { line = 0, groups = { { col = 0, end_col = 3 }, { col = 0, end_col = -1 } } } },
		link_metadata = { { line = 0, col_start = 1, col_end = 3 } },
		code_blocks = { { start_line = 1, end_line = 1, prefix_len = 2, source_lines = { "raw" } } },
		image_placements = { { line = 0, col = 1 } },
		text_placements = { { line = 0, col = 1, icon_col = 0 } },
		source_line_map = { 4, 5 },
		heading_anchors = { heading = 1 },
	}
	local original = vim.deepcopy(content)
	layout.center_content(content, { nvim_config_page_margin = 7 })
	assert(content.lines[1] == "abc" and content.lines[2] == "xyz", "page margin was written into the text")
	assert(content.lines[3] == " ", "blank row has no cursor cell after the margin")
	for _, field in ipairs({ "highlights", "link_metadata", "code_blocks", "text_placements" }) do
		assert(vim.deep_equal(content[field], original[field]), field .. " byte columns were shifted")
	end
	assert(content.image_placements[1].col == 8, "Kitty image column lacks the margin")
	assert(content.source_line_map[1] == 4 and content.heading_anchors.heading == 1, "row metadata changed")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
	layout.pad(buf, 7)
	layout.pad(buf, 7)
	local widths = page_margins(buf)
	assert(#widths == 3 and widths[1] == 7 and widths[3] == 7, "every row needs exactly one page margin")
	layout.pad(buf, 0)
	assert(#page_margins(buf) == 0, "a zero margin left virtual padding behind")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("wide tables open without losing cell text and never collapse", function()
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
	assert(direct[1]:match("^┌") and direct[#direct]:match("^└"), "compact table lacks its horizontal caps")
	local text = table_text(buf)
	assert(text:find("Acompletesentencethatcontinuesuntiltheveryend", 1, true), "prose cell was shortened: " .. text)
	assert(
		text:find("https://example.com/very/long/segment/without/spaces", 1, true),
		"URL cell was shortened: " .. text
	)
	assert(not contains(buf, "…"), "expanded table still contains an ellipsis")
	assert(contains(buf, "┌") and contains(buf, "└"), "expanded table lacks its horizontal caps")
	assert(vim.wo[win].wrap, "wide table can scroll horizontally")
	vim.cmd("normal! 30zl")
	assert(vim.fn.winsaveview().leftcol == 0, "wide table shifted out of the reading area")
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
	assert(type(toggle) == "function", "renderer <CR> mapping is missing")
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_cursor(win, { row, 0 })
	toggle()
	assert(not contains(buf, "…"), "<CR> collapsed the table")
	assert(contains(buf, "┌") and contains(buf, "└"), "<CR> changed the table caps")
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
	assert(contains(buf, "┌") and contains(buf, "└"), "updated table lost its horizontal caps")
	vim.api.nvim_set_current_win(win)
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

local function keymap_callback(buf, lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if mapping.lhs == lhs then
			return mapping.callback
		end
	end
	error("renderer mapping is missing: " .. lhs)
end

local function find_row(buf, fragment)
	for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(fragment, 1, true) then
			return row
		end
	end
	error("rendered row is missing: " .. fragment)
end

local function max_width(buf, fragment)
	local width = 0
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if not fragment or line:find(fragment, 1, true) then
			width = math.max(width, vim.api.nvim_strwidth(line))
		end
	end
	return width
end

test("clicks and keys never change blocks or wrap", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local columns = vim.o.columns
	vim.o.columns = 68
	local code = string.rep("x", 100)
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"| Item | Description |",
		"| --- | --- |",
		"| A | A complete sentence that continues until the very end |",
		"",
		"```text",
		code,
		"```",
		"",
		"> [!TIP]- Folded",
		"> hidden callout body",
	})
	vim.bo[source].filetype = "markdown"
	view.toggle()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	assert(#session.content.expandable_regions == 0, "rendered blocks remain toggleable")
	assert(not contains(buf, "…"), "a block opened truncated")
	assert(contains(buf, code), "long code line was truncated")
	assert(vim.wo[win].wrap, "reading view did not open wrapped")

	local opened = {}
	local open = vim.ui.open
	local getmousepos = vim.fn.getmousepos
	vim.ui.open = function(target)
		opened[#opened + 1] = target
	end
	local margin = session.opts.nvim_config_page_margin
	local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for _, row in ipairs({ find_row(buf, "│ A "), find_row(buf, code) }) do
		vim.api.nvim_win_set_cursor(win, { row, 2 })
		keymap_callback(buf, "<CR>")()
		keymap_callback(buf, "za")()
		vim.fn.getmousepos = function()
			return { winid = win, line = row, column = 3, wincol = margin + 3, winrow = row }
		end
		keymap_callback(buf, "<LeftRelease>")()
		vim.fn.getmousepos = getmousepos
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before), "a click or key changed a block")
		assert(vim.wo[win].wrap, "a click or key changed wrap")
	end
	vim.ui.open = open
	assert(#opened == 0, "clicking a block opened a target")

	local fold = assert(session.content.callout_folds and session.content.callout_folds[1], "callout is not foldable")
	assert(not contains(buf, "hidden callout body"), "folded callout opened expanded")
	vim.api.nvim_win_set_cursor(win, { fold.header_line + 1, 2 })
	keymap_callback(buf, "<CR>")()
	assert(contains(buf, "hidden callout body"), "<CR> no longer unfolds callouts")

	local updated = string.rep("y", 100)
	vim.api.nvim_buf_set_lines(source, 5, 6, false, { updated })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	assert(
		vim.wait(1000, function()
			return contains(buf, updated)
		end),
		"live update truncated the edited code line"
	)
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

test("ToggleWrap owns the reading layout", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local columns = vim.o.columns
	vim.o.columns = 120
	local cell = vim.trim(string.rep("wide cell words ", 13))
	local code = string.rep("c", 150)
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"Intro paragraph.",
		"",
		"| Item | Description |",
		"| --- | --- |",
		"| A | " .. cell .. " |",
		"",
		"```text",
		code,
		"```",
	})
	vim.bo[source].filetype = "markdown"
	view.toggle()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	local text_width = require("config.markdown_layout").text_width(win)
	local function assert_wrapped(context)
		assert(vim.wo[win].wrap and vim.wo[win].linebreak, context .. ": reading view is not wrapped")
		assert(session.opts.nvim_config_wrap ~= false, context .. ": session lost the wrap mode")
		assert(max_width(buf, "│") <= text_width, context .. ": wrapped table exceeds the window")
		assert(not contains(buf, cell), context .. ": wrapped table kept the cell on one row")
		assert(vim.fn.winsaveview().leftcol == 0, context .. ": wrapped view scrolled horizontally")
	end
	local function assert_unwrapped(context)
		assert(not vim.wo[win].wrap and not vim.wo[win].linebreak, context .. ": reading view is wrapped")
		assert(session.opts.nvim_config_wrap == false, context .. ": session lost the nowrap mode")
		assert(contains(buf, cell), context .. ": natural-width table split its cell")
		assert(max_width(buf, cell) > text_width, context .. ": natural-width table fits the window")
		assert(contains(buf, code), context .. ": code line was truncated")
		assert(not contains(buf, "…"), context .. ": nowrap layout truncated a block")
	end
	assert_wrapped("open")

	local editor_actions = require("config.editor_actions")
	assert(editor_actions.toggle_wrap() == false, "ToggleWrap did not disable wrap")
	assert_unwrapped("toggle")
	vim.api.nvim_win_set_cursor(win, { find_row(buf, cell), 0 })
	vim.cmd("normal! 30zl")
	assert(vim.fn.winsaveview().leftcol > 0, "nowrap reading view cannot scroll horizontally")

	vim.api.nvim_buf_set_lines(source, 0, 1, false, { "Edited paragraph." })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	assert(
		vim.wait(1000, function()
			return contains(buf, "Edited paragraph.")
		end),
		"live update did not reach the reading view"
	)
	assert_unwrapped("live update")
	vim.api.nvim_exec_autocmds("WinResized", {})
	assert_unwrapped("resize")

	vim.cmd("setlocal wrap")
	assert_wrapped("setlocal wrap")
	assert(editor_actions.toggle_wrap() == false, "ToggleWrap did not disable wrap again")
	assert(editor_actions.toggle_wrap() == true, "ToggleWrap did not restore wrap")
	assert_wrapped("toggle back")
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

test("tables and code extend past the page to the window edge", function()
	vim.cmd("tabonly")
	vim.cmd("only")
	local columns = vim.o.columns
	vim.o.columns = 240
	local prose = vim.trim(string.rep("prose words ", 40))
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		prose,
		"",
		"| Item | Description |",
		"| --- | --- |",
		"| A | " .. vim.trim(string.rep("table words ", 25)) .. " |",
	})
	vim.bo[source].filetype = "markdown"
	view.toggle()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	local layout = require("config.markdown_layout")
	local page_width, _, block_width = layout.measure(win)
	assert(page_width == 120 and block_width == 180, "unexpected 240-column page geometry")
	assert(session.opts.nvim_config_block_width == layout.render_width(block_width), "renderer lacks the block width")
	local table_width = max_width(buf, "│")
	assert(table_width > page_width, "table stayed inside the 120-column page")
	assert(table_width <= block_width, "table extends past the window")
	assert(not contains(buf, "…"), "wide table was truncated")
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find("prose", 1, true) then
			assert(vim.api.nvim_strwidth(line) <= page_width, "prose left the reading page")
		end
	end
	view.toggle()
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
end)

test("every block builds complete within the block width", function()
	local preview = require("md-render").preview
	local lines = {
		"---",
		"summary: " .. vim.trim(string.rep("frontmatter words ", 6)) .. " fmend",
		"---",
		"",
		"| Item | Description |",
		"| --- | --- |",
		"| A | " .. vim.trim(string.rep("table words ", 12)) .. " tend |",
		"",
		"<table><tr><td>" .. vim.trim(string.rep("html words ", 8)) .. " hend</td></tr></table>",
		"",
		"```text",
		string.rep("f", 90),
		"```",
		"",
		"> [!NOTE]",
		"> ```text",
		"> " .. string.rep("q", 90),
		"> ```",
	}
	local function build(wrap)
		return preview.build_content(lines, {
			max_width = 40,
			nvim_config_block_width = 70,
			nvim_config_wrap = wrap,
			expand_state = {},
		})
	end
	for _, wrap in ipairs({ true, false }) do
		local content = build(wrap)
		local text = table.concat(content.lines, "\n")
		assert(#content.expandable_regions == 0, "built blocks remain toggleable")
		assert(not text:find("…", 1, true), "a block was truncated:\n" .. text)
		assert(text:find(string.rep("f", 90), 1, true), "fenced code was truncated")
		assert(text:find(string.rep("q", 90), 1, true), "callout code was truncated")
		for _, word in ipairs({ "fmend", "tend", "hend" }) do
			assert(text:find(word, 1, true), "block lost its final word: " .. word)
		end
		-- Callout bars also use │; a table's corners give its width.
		local table_width = 0
		for _, line in ipairs(content.lines) do
			if line:find("┐", 1, true) or line:find("┘", 1, true) then
				table_width = math.max(table_width, vim.api.nvim_strwidth(line))
			end
		end
		if wrap then
			assert(table_width > 40 and table_width <= 70, "wrapped table ignored the block width: " .. table_width)
		else
			assert(table_width > 70, "natural-width table was wrapped: " .. table_width)
		end
	end
end)

test("narrow tables keep full linked cells and outer borders", function()
	local tables = require("md-render").MarkdownTable
	local url = "https://example.com/very/long/segment/without/spaces"
	local parsed = assert(tables.parse({
		"| A | B | C | D | E | F | G | H |",
		"| --- | --- | --- | --- | --- | --- | --- | --- |",
		"| first | [" .. url .. "](" .. url .. ") | 長い日本語 | D | E | F | G | H |",
	}))
	local lines, highlights, links, _, offsets = tables.render(parsed, "  ", 30, true)
	assert(lines[1]:match("^  ┌") and lines[#lines]:match("^  └"), "stacked table lacks horizontal caps")
	assert(lines[1]:match("┐$") and lines[#lines]:match("┘$"), "stacked table caps are incomplete")
	assert(offsets[1] == 0 and offsets[#offsets] == 2, "stacked table cap source offsets are wrong")
	assert(highlights[1][1].hl == "FloatBorder" and highlights[#lines][1].hl == "FloatBorder")
	assert(#links[1] == 0 and #links[#links] == 0, "stacked table caps contain links")
	local linked = {}
	local seen = {}
	for row = 2, #lines - 1 do
		local line = lines[row]
		assert(vim.api.nvim_strwidth(line) <= 30, "narrow table extends beyond its width")
		assert(line:match("^  │") and line:match("│$"), "narrow table lost its outer borders")
		assert(offsets[row] == 2, "narrow table lost the source-row mapping")
		for _, link in ipairs(links[row]) do
			local key = table.concat({ row, link.col_start, link.col_end, link.url }, ":")
			if not seen[key] then
				seen[key] = true
				linked[link.url] = (linked[link.url] or "") .. line:sub(link.col_start + 1, link.col_end)
			end
		end
	end
	assert(linked[url] == url, "a wrapped table link lost visible text or its clickable byte range")
	assert(table.concat(lines):find("長い日本語", 1, true), "narrow table lost Unicode cell text")
	local literal = assert(tables.parse({
		"| Item | Description |",
		"| --- | --- |",
		"| x… | " .. url .. " |",
	}))
	local _, _, _, _, literal_offsets = tables.render(literal, "", 25, true)
	assert(literal_offsets[2] == 0, "literal ellipsis incorrectly triggered the stacked layout")
end)

test("table caps follow highlighted borders and preserve shifted metadata", function()
	local line = "  │ A │ literal │ text │"
	local borders = {}
	local next_byte = 1
	while true do
		local byte = line:find("│", next_byte, true)
		if not byte then
			break
		end
		borders[#borders + 1] = byte
		next_byte = byte + #"│"
	end
	assert(#borders == 4, "test fixture must contain one literal border glyph")
	local row_highlights = {
		{ col = borders[1] - 1, end_col = borders[1] - 1 + #"│ ", hl = "FloatBorder" },
		{ col = borders[2] - 1, end_col = borders[2] - 1 + #"│ ", hl = "FloatBorder" },
		{ col = borders[4] - 1, end_col = borders[4] - 1 + #"│", hl = "FloatBorder" },
	}
	local link = { col_start = borders[2] + #"│ ", col_end = borders[2] + #"│ " + 7, url = "example" }
	local adapter = dofile(repo .. "/lua/config/markdown_tables.lua")
	local fake_preview = {
		build_content = function()
			return {}
		end,
	}
	local fake_wrap = {
		split_ascii_syllables = function()
			return {}
		end,
	}
	local fake_table = {
		parse = function()
			return {}
		end,
		render = function(parsed)
			if parsed.empty then
				return {}, {}, {}, {}, {}
			end
			return { line, line }, { row_highlights, row_highlights }, { { link }, {} }, {
				{ line_offset = 0 },
				{ line_offset = 1 },
			}, { 0, 2 }
		end,
	}
	assert(adapter.configure(fake_preview, fake_wrap, fake_table), "fake table adapter could not initialize")
	local lines, highlights, links, images, offsets = fake_table.render({}, "  ", nil, true)
	assert(lines[1]:match("^  ┌") and lines[1]:match("┐$"), "top cap has wrong corners")
	assert(lines[#lines]:match("^  └") and lines[#lines]:match("┘$"), "bottom cap has wrong corners")
	local _, junctions = lines[1]:gsub("┬", "")
	assert(junctions == 1 and lines[#lines]:find("┴", 1, true), "literal │ became a column junction")
	assert(vim.api.nvim_strwidth(lines[1]) == vim.api.nvim_strwidth(line), "top cap changed table width")
	assert(vim.api.nvim_strwidth(lines[#lines]) == vim.api.nvim_strwidth(line), "bottom cap changed table width")
	assert(#links[1] == 0 and #links[#links] == 0 and links[2][1] == link, "cap shifted link metadata")
	assert(highlights[1][1].hl == "FloatBorder" and highlights[#lines][1].hl == "FloatBorder")
	assert(vim.deep_equal(offsets, { 0, 0, 2, 2 }), "cap source offsets are wrong")
	assert(images[1].line_offset == 1 and images[2].line_offset == 2, "image placements did not shift")
	local previous_ambiwidth = vim.o.ambiwidth
	vim.o.ambiwidth = "double"
	local double_ok, double_error = pcall(function()
		local double_lines = fake_table.render({}, "  ", nil, true)
		assert(vim.api.nvim_strwidth(double_lines[1]) == vim.api.nvim_strwidth(line), "double-width top cap shifted")
		assert(
			vim.api.nvim_strwidth(double_lines[#double_lines]) == vim.api.nvim_strwidth(line),
			"double-width bottom cap shifted"
		)
	end)
	vim.o.ambiwidth = previous_ambiwidth
	assert(double_ok, double_error)
	local empty_lines = fake_table.render({ empty = true }, "  ", nil, true)
	assert(#empty_lines == 0, "empty renderer output acquired a cap")
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
	local source_linebreak = vim.wo[win].linebreak
	local source_breakindent = vim.wo[win].breakindent
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
	assert(contains(buf, "┌") and contains(buf, "└"), "pager table lacks horizontal caps")
	assert(vim.wo[win].wrap, "pager table can scroll horizontally")
	vim.cmd("normal! 30zl")
	assert(vim.fn.winsaveview().leftcol == 0, "pager table shifted out of the reading area")
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
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		assert(vim.api.nvim_strwidth(line) <= text_width, "adapted table extends past the visible window")
		if line:find("│", 1, true) then
			assert(line:match("^%s*│") and line:match("│$"), "table lost an outer vertical border")
		end
	end
	vim.cmd("normal! 30zl")
	assert(vim.fn.winsaveview().leftcol == 0, "adapted table scrolled horizontally")
	assert(not contains(buf, "…"), "wide table lost cell text")
	assert(contains(buf, "┌") and contains(buf, "└"), "pager update lost horizontal caps")
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager did not restore its source")
	assert(vim.wo[win].wrap == source_wrap, "pager changed the source wrap setting")
	assert(vim.wo[win].linebreak == source_linebreak, "pager changed the source line-break setting")
	assert(vim.wo[win].breakindent == source_breakindent, "pager changed the source continuation indent")
	vim.api.nvim_buf_delete(source, { force = true })
	vim.o.columns = columns
	pager.active = false
end)

test("pager blocks use the window width and keep the wrap mode", function()
	pager.active = true
	local columns = vim.o.columns
	-- A headless window follows 'columns' only after a layout change.
	vim.o.columns = 160
	vim.cmd("vnew")
	vim.cmd("only")
	local cell = vim.trim(string.rep("pager cell words ", 6))
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, {
		"| Item | Description |",
		"| --- | --- |",
		"| A | " .. cell .. " |",
	})
	vim.bo[source].filetype = "markdown"
	local win = vim.api.nvim_get_current_win()
	local source_wrap = vim.wo[win].wrap
	view.toggle()
	local buf = vim.api.nvim_win_get_buf(win)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	assert(session.opts.nvim_config_block_width == 158, "pager block width ignores the window")
	assert(max_width(buf, "│") > 82, "pager table stayed inside the 80-column prose width")
	assert(max_width(buf, "│") <= 160, "pager table extends past the window")
	assert(contains(buf, cell) and not contains(buf, "…"), "pager table split or truncated its cell")

	assert(require("config.editor_actions").toggle_wrap() == false, "ToggleWrap did not disable pager wrap")
	assert(session.opts.nvim_config_wrap == false, "pager session lost the nowrap mode")
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager did not show its source")
	assert(vim.wo[win].wrap == source_wrap, "pager source inherited the render wrap mode")
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == buf, "pager did not show its render again")
	assert(not vim.wo[win].wrap, "pager render forgot the nowrap mode")

	vim.cmd("vnew")
	local other = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_width(win, 120)
	vim.api.nvim_exec_autocmds("WinResized", {})
	assert(session.opts.nvim_config_block_width == 118, "pager block width did not follow the resize")
	assert(not vim.wo[win].wrap, "resize reenabled pager wrap")
	vim.api.nvim_win_close(other, true)
	vim.api.nvim_set_current_win(win)
	assert(require("config.editor_actions").toggle_wrap() == true, "ToggleWrap did not restore pager wrap")
	view.toggle()
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
	assert(has_highlight(rendered, "MdRenderH1Band"), "pager heading lost its soft band")
	assert(
		has_heading_cap(rendered, "", "overlay") and has_heading_cap(rendered, "", "inline"),
		"pager heading lost its rounded ends"
	)
	local session = assert(require("md-render").preview._toggle_sessions[source])
	assert(session.opts.text_scale == false and #session.content.text_placements == 0, "pager scaled its heading")
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
	assert(
		require("md-render").preview._toggle_sessions[source].opts.text_scale == false,
		"auto-render scaled its heading"
	)
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
