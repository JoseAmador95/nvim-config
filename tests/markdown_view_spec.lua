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

test("editor keeps raw source focused and one live right-side read-only view", function()
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
	local system = vim.system
	local external_media = {}
	vim.system = function(argv, opts, callback)
		if argv[1] == "npx" or argv[1] == "curl" then
			external_media[#external_media + 1] = argv[1]
		end
		return system(argv, opts, callback)
	end

	view.toggle()
	local wins = vim.api.nvim_tabpage_list_wins(0)
	assert(#wins == 2, "MarkdownView did not create exactly one split")
	assert(vim.api.nvim_get_current_win() == source_win, "preview stole source focus")
	assert(vim.api.nvim_win_get_buf(source_win) == source, "source buffer was replaced")
	assert(vim.bo[source].modifiable, "source became noneditable")
	local render_win = wins[1] == source_win and wins[2] or wins[1]
	local render_buf = vim.api.nvim_win_get_buf(render_win)
	assert(vim.b[render_buf].md_render, "split does not show md-render output")
	assert(not vim.bo[render_buf].modifiable and vim.bo[render_buf].readonly, "reading view is editable")
	assert(
		vim.api.nvim_win_get_position(render_win)[2] > vim.api.nvim_win_get_position(source_win)[2],
		"reading view is not on the right"
	)

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
	assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "second toggle did not close the view")
	view.toggle()
	assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "reopening created the wrong number of splits")
	view.toggle()
	vim.system = system
	vim.api.nvim_buf_delete(source, { force = true })
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
	pager.set_markdown_view(view)
	view.toggle()
	local rendered = vim.api.nvim_win_get_buf(win)
	assert(rendered ~= source and vim.b[rendered].md_render, "pager did not show the rendered document")
	assert(vim.bo[rendered].readonly and not vim.bo[rendered].modifiable, "pager render is editable")
	assert(vim.api.nvim_buf_is_valid(source), "pager discarded its Markdown source")
	local target = assert(view.diagram_target())
	assert(target.bufnr == source and target.row >= 1, "diagram extraction did not follow the source")
	assert(pager._apply_filetype(win, "text"), "picker could not change the rendered pager's source filetype")
	assert(vim.api.nvim_win_get_buf(win) == source, "pager did not reveal source for filetype change")
	vim.wait(100)
	assert(vim.api.nvim_win_get_buf(win) == source, "non-Markdown source was rendered")
	assert(pager._apply_filetype(win, "markdown"), "picker could not restore Markdown filetype")
	assert(
		vim.wait(1000, function()
			return vim.api.nvim_win_get_buf(win) ~= source
		end),
		"Markdown filetype change did not restore the reading view"
	)
	vim.cmd("SetFileType text")
	assert(vim.api.nvim_win_get_buf(win) == source, "SetFileType did not recover the rendered source")
	assert(vim.bo[source].filetype == "text", "SetFileType did not replace the detected Markdown filetype")
	vim.cmd("SetFileType markdown")
	assert(
		vim.wait(1000, function()
			return vim.api.nvim_win_get_buf(win) ~= source
		end),
		"SetFileType did not restore automatic Markdown rendering"
	)
	view.toggle()
	assert(vim.api.nvim_win_get_buf(win) == source, "pager mapping did not toggle back to source")
	vim.api.nvim_buf_delete(source, { force = true })
	pager.active = false
end)

test("missing private media guard fails closed", function()
	local image = require("md-render.image")
	local guard = image._set_kitty_supported
	image._set_kitty_supported = nil
	local configured = view.configure_renderer()
	assert(configured == nil, "view accepted a renderer without the media guard")
	local before = #vim.api.nvim_tabpage_list_wins(0)
	view.toggle()
	assert(#vim.api.nvim_tabpage_list_wins(0) == before, "view opened after media guard failure")
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
