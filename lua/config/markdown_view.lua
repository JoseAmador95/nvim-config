-- Host-owned Markdown reading view. The source stays editable in the full
-- editor; md-render owns the live rendered buffer and its scroll mapping.
local M = {}

local deferred = require("config.deferred")
local lazy_lock = require("config.lazy_lock")
local pager = require("config.pager")

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve Markdown view host")
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

M.PIN = "cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74" -- md-render.nvim v3.10.3

local renderer
local image
local ready = false
local notified_error
local previews = {}
local pager_source_requested = {}
local pager_filetype_pending = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "Markdown" })
end

local function fail(message)
	if notified_error ~= message then
		notify(message, vim.log.levels.ERROR)
		notified_error = message
	end
	return nil, message
end

local function disable_upstream_entrypoints()
	for _, name in ipairs({
		"MdRender",
		"MdRenderTab",
		"MdRenderToggle",
		"MdRenderSplit",
		"MdRenderPager",
		"MdRenderDemo",
		"MdRenderAuto",
	}) do
		pcall(vim.api.nvim_del_user_command, name)
	end
	for _, name in ipairs({ "preview", "preview-tab", "toggle", "auto", "split", "demo" }) do
		pcall(vim.keymap.del, "n", "<Plug>(md-render-" .. name .. ")")
	end
end

function M.lock_ok()
	local entry, lock_err = lazy_lock.plugin(repo_root, "md-render.nvim")
	if not entry then
		return nil, lock_err
	end
	if entry.commit ~= M.PIN then
		return nil, ("md-render.nvim must be pinned to v3.10.3 (%s); lock has %s"):format(M.PIN, entry.commit)
	end
	return true
end

local function checkout_ok(image_module, render_module)
	local image_source = debug.getinfo(image_module._set_kitty_supported, "S")
	local split_source = debug.getinfo(render_module.preview.split, "S")
	local image_path = image_source and image_source.source:match("^@(.+)$")
	local split_path = split_source and split_source.source:match("^@(.+)$")
	if not image_path or not split_path then
		return nil, "renderer source path is unavailable"
	end
	local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(image_path))))
	if
		vim.fs.normalize(image_path) ~= vim.fs.joinpath(root, "lua", "md-render", "image.lua")
		or vim.fs.normalize(split_path) ~= vim.fs.joinpath(root, "lua", "md-render", "preview.lua")
	then
		return nil, "renderer modules came from different checkouts"
	end
	local head = vim.system({ "git", "-C", root, "rev-parse", "--verify", "HEAD" }, { text = true }):wait()
	if head.code ~= 0 or vim.trim(head.stdout or "") ~= M.PIN then
		return nil, "loaded renderer checkout differs from the v3.10.3 pin"
	end
	local status = vim.system({ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }, { text = true })
		:wait()
	if status.code ~= 0 or vim.trim(status.stdout or "") ~= "" then
		return nil, "loaded renderer checkout has local changes"
	end
	return true
end

-- v3.10.3 has no public switch for all automatic media. Disable its private
-- Kitty capability before any preview starts; without it, fences stay code
-- blocks and no Mermaid npx fallback or remote image fetch can run. Keep the
-- public download callback as a second guard against remote fetches.
function M.configure_renderer()
	ready = false
	image = nil
	renderer = nil
	local locked, lock_err = M.lock_ok()
	if not locked then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: " .. tostring(lock_err))
	end
	local ok_image, image_module = deferred.try("md-render.image")
	local ok_renderer, render_module = deferred.try("md-render")
	if not ok_image or not ok_renderer then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: md-render.nvim could not load")
	end
	if
		type(image_module._set_kitty_supported) ~= "function"
		or type(image_module.set_download_fn) ~= "function"
		or type(render_module.preview) ~= "table"
		or type(render_module.preview.split) ~= "function"
		or type(render_module.preview.toggle) ~= "function"
		or type(render_module.preview._toggle_sessions) ~= "table"
	then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: v3.10.3 media guard contract changed")
	end
	local checked, checkout_err = checkout_ok(image_module, render_module)
	if not checked then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: " .. checkout_err)
	end
	local blocked = function(_, _, callback)
		callback(false)
		return true
	end
	local installed, install_err = pcall(function()
		image_module.set_download_fn(blocked)
		image_module._set_kitty_supported(false)
	end)
	if not installed then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: could not disable automatic media: " .. tostring(install_err))
	end
	image = image_module
	renderer = render_module
	ready = true
	return true
end

local function ensure_renderer()
	if not ready then
		return fail("Markdown reading view unavailable: md-render.nvim is not configured")
	end
	-- Reassert the guard in case an unrelated consumer reset the plugin cache.
	image._set_kitty_supported(false)
	return renderer.preview
end

local function win_state(win)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local ok, state = pcall(vim.api.nvim_win_get_var, win, "md_render_state")
	if not ok or type(state) ~= "table" then
		return nil
	end
	if state.mode ~= "render" or vim.api.nvim_win_get_buf(win) ~= state.render_buf then
		return nil
	end
	if not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then
		return nil
	end
	return state
end

local function source_for_window(win)
	local state = win_state(win)
	return state and state.source_buf or vim.api.nvim_win_get_buf(win), state
end

local function protect_render_buffer(win)
	local state = win_state(win)
	if not state then
		return nil
	end
	vim.bo[state.render_buf].modifiable = false
	vim.bo[state.render_buf].readonly = true
	return state
end

local function tracked_preview(tab)
	local preview = previews[tab]
	if not preview then
		return nil
	end
	if
		not vim.api.nvim_win_is_valid(preview.win)
		or not vim.api.nvim_tabpage_is_valid(tab)
		or vim.api.nvim_win_get_tabpage(preview.win) ~= tab
		or not win_state(preview.win)
	then
		previews[tab] = nil
		return nil
	end
	return preview
end

local function find_render_win(tab, source_buf)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		local state = win_state(win)
		if state and state.source_buf == source_buf then
			return win
		end
	end
	return nil
end

local function close_preview(preview)
	previews[preview.tab] = nil
	if vim.api.nvim_win_is_valid(preview.win) then
		vim.api.nvim_win_close(preview.win, true)
	end
end

local function editor_toggle()
	local preview_api = ensure_renderer()
	if not preview_api then
		return
	end
	local tab = vim.api.nvim_get_current_tabpage()
	local current_win = vim.api.nvim_get_current_win()
	local source_buf = source_for_window(current_win)
	local existing = tracked_preview(tab)
	if existing then
		close_preview(existing)
		if existing.source_buf == source_buf then
			return
		end
	end
	local untracked = find_render_win(tab, source_buf)
	if untracked then
		vim.api.nvim_win_close(untracked, true)
		return
	end
	if vim.bo[source_buf].filetype ~= "markdown" then
		notify("MarkdownView requires a Markdown source buffer")
		return
	end
	local source_win = current_win
	if win_state(current_win) then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			if vim.api.nvim_win_get_buf(win) == source_buf then
				source_win = win
				break
			end
		end
	end
	if not vim.api.nvim_win_is_valid(source_win) or vim.api.nvim_win_get_buf(source_win) ~= source_buf then
		notify("Open the Markdown source before creating its reading view")
		return
	end
	local old_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(source_win)
	local ok, err = pcall(preview_api.split, { mods = { vertical = true, split = "belowright" } })
	if not ok then
		vim.api.nvim_set_current_win(old_win)
		fail("Could not open Markdown reading view: " .. tostring(err))
		return
	end
	local render_win = find_render_win(tab, source_buf)
	if not render_win then
		fail("Could not identify Markdown reading view after opening the split")
		return
	end
	protect_render_buffer(render_win)
	vim.keymap.set("n", "<leader>mv", M.toggle, {
		buffer = vim.api.nvim_win_get_buf(render_win),
		desc = "Close Markdown reading view",
	})
	previews[tab] = { tab = tab, source_buf = source_buf, win = render_win }
	vim.api.nvim_set_current_win(source_win)
end

-- The pager uses md-render's same-window toggle so its source buffer remains
-- hidden and can still receive filetype changes and diagram extraction.
local function pager_toggle()
	local preview_api = ensure_renderer()
	if not preview_api then
		return
	end
	local win = vim.api.nvim_get_current_win()
	local source_buf, state = source_for_window(win)
	if state then
		preview_api.toggle()
		pager_source_requested[source_buf] = true
		return
	end
	if vim.bo[source_buf].filetype ~= "markdown" then
		notify("MarkdownView requires a Markdown source buffer")
		return
	end
	pager_source_requested[source_buf] = nil
	preview_api.toggle()
	protect_render_buffer(win)
end

function M.toggle()
	if pager.active then
		pager_toggle()
	else
		editor_toggle()
	end
end

function M.pager_show_source(win)
	if not pager.active or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local source_buf, state = source_for_window(win)
	if state then
		local preview_api = ensure_renderer()
		if not preview_api then
			return nil
		end
		vim.api.nvim_win_call(win, preview_api.toggle)
	end
	return source_buf
end

function M.pager_filetype_changed(buf)
	if not pager.active or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	pager_source_requested[buf] = nil
	if pager_filetype_pending[buf] then
		return
	end
	pager_filetype_pending[buf] = true
	vim.schedule(function()
		pager_filetype_pending[buf] = nil
		if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "markdown" or pager_source_requested[buf] then
			return
		end
		local preview_api = ensure_renderer()
		if not preview_api then
			return
		end
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
				vim.api.nvim_win_call(win, preview_api.toggle)
				protect_render_buffer(win)
			end
		end
	end)
end

function M.pager_initial_render()
	if pager.active then
		M.pager_filetype_changed(vim.api.nvim_get_current_buf())
	end
end

-- Resolve a rendered pager line back to the source. diagram-view accepts an
-- explicit source row, so the rendered buffer never has to be swapped out.
function M.diagram_target(selection)
	local win = vim.api.nvim_get_current_win()
	local source_buf, state = source_for_window(win)
	if not state then
		return { bufnr = source_buf, winid = win, selection = selection }
	end
	local sessions = renderer and renderer.preview._toggle_sessions
	local session = sessions and sessions[source_buf]
	if not session or type(session.rendered_to_source) ~= "function" then
		return nil, "Could not map the rendered Markdown position to its source"
	end
	local row = session:rendered_to_source(vim.api.nvim_win_get_cursor(win)[1])
	if selection then
		selection = {
			start_row = session:rendered_to_source(selection.start_row),
			end_row = session:rendered_to_source(selection.end_row),
		}
	end
	return { bufnr = source_buf, winid = win, row = row, selection = selection }
end

function M.setup()
	if vim.g.vscode then
		return
	end
	vim.api.nvim_create_user_command("MarkdownView", M.toggle, { desc = "Toggle rendered Markdown reading view" })
	if pager.active then
		pager.set_markdown_view(M)
		vim.keymap.set("n", "<leader>mv", M.toggle, { desc = "Toggle Markdown reading/source view" })
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "markdown",
			group = vim.api.nvim_create_augroup("PagerMarkdownView", { clear = true }),
			callback = function(args)
				M.pager_filetype_changed(args.buf)
			end,
		})
		vim.api.nvim_create_autocmd("VimEnter", {
			group = vim.api.nvim_create_augroup("PagerMarkdownInitialView", { clear = true }),
			once = true,
			callback = M.pager_initial_render,
		})
	else
		local function map(buf)
			vim.keymap.set("n", "<leader>mv", M.toggle, { buffer = buf, desc = "Toggle Markdown reading view" })
		end
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "markdown",
			group = vim.api.nvim_create_augroup("MarkdownViewKeymap", { clear = true }),
			callback = function(args)
				map(args.buf)
			end,
		})
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
				map(buf)
			end
		end
	end
end

return M
