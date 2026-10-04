-- Host-owned Markdown reading view. The source stays editable in the full
-- editor; md-render owns the live rendered buffer and its scroll mapping.
local M = {}

local deferred = require("config.deferred")
local lazy_lock = require("config.lazy_lock")
local markdown_codeblocks = require("config.markdown_codeblocks")
local markdown_layout = require("config.markdown_layout")
local markdown_tables = require("config.markdown_tables")
local pager = require("config.pager")
local palette = require("config.palette")
local markdown_render_navigation = not pager.active
		and not vim.g.vscode
		and require("config.markdown_render_navigation")
	or nil

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve Markdown view host")
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

M.PIN = "cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74" -- md-render.nvim v3.10.3

local renderer
local image
local ready = false
local configure_error
local notified_error
local previews = {}
local pager_source_requested = {}
local pager_filetype_pending = {}
-- Rebuilds in progress. md-render writes `wrap = not any_expanded` on every
-- rebuild; the wrap observer must not mistake that for the user's choice.
local rebuilding = 0
local render_winhighlight_var = "nvim_config_md_render_winhighlight"
local render_window_options_var = "nvim_config_md_render_window_options"

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

-- Lazy rewrites the shared lock from installed plugins only, so a restore
-- while md-render is missing prunes its entry and disables the spec.
local function lock_unavailable(lock_err)
	return (
		"Markdown reading view unavailable: %s; run git -C %s checkout -- lazy-lock.json, "
		.. "then :Lazy install md-render.nvim and restart"
	):format(tostring(lock_err), repo_root)
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
	local toggle_source = debug.getinfo(render_module.preview.toggle, "S")
	local image_path = image_source and image_source.source:match("^@(.+)$")
	local toggle_path = toggle_source and toggle_source.source:match("^@(.+)$")
	if not image_path or not toggle_path then
		return nil, "renderer source path is unavailable"
	end
	local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(image_path))))
	if
		vim.fs.normalize(image_path) ~= vim.fs.joinpath(root, "lua", "md-render", "image.lua")
		or vim.fs.normalize(toggle_path) ~= vim.fs.joinpath(root, "lua", "md-render", "preview.lua")
	then
		return nil, "renderer modules came from different checkouts"
	end
	local head = vim.system({ "git", "-C", root, "rev-parse", "--verify", "HEAD" }, { text = true }):wait()
	if head.code ~= 0 or vim.trim(head.stdout or "") ~= M.PIN then
		return nil,
			"loaded renderer checkout differs from the v3.10.3 pin; run :Lazy restore md-render.nvim and restart"
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
local function configure()
	ready = false
	image = nil
	renderer = nil
	local locked, lock_err = M.lock_ok()
	if not locked then
		disable_upstream_entrypoints()
		return fail(lock_unavailable(lock_err))
	end
	local ok_image, image_module = deferred.try("md-render.image")
	local ok_renderer, render_module = deferred.try("md-render")
	local ok_wrap, wrap_module = deferred.try("md-render.wrap")
	if not ok_image or not ok_renderer or not ok_wrap then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: md-render.nvim could not load")
	end
	if
		type(image_module._set_kitty_supported) ~= "function"
		or type(image_module.set_download_fn) ~= "function"
		or type(render_module.preview) ~= "table"
		or type(render_module.preview.toggle) ~= "function"
		or type(render_module.preview._toggle_sessions) ~= "table"
		or type(render_module.MarkdownTable) ~= "table"
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
	local tables_ready, tables_err = markdown_tables.configure(
		render_module.preview,
		wrap_module,
		render_module.MarkdownTable,
		markdown_layout.center_content
	)
	if not tables_ready then
		disable_upstream_entrypoints()
		return fail("Markdown reading view unavailable: " .. tables_err)
	end
	image = image_module
	renderer = render_module
	palette.apply_markdown()
	ready = true
	return true
end

function M.configure_renderer()
	local ok, err = configure()
	configure_error = not ok and err or nil
	return ok, err
end

local function ensure_renderer()
	if not ready then
		-- An explicit request must always explain itself, even when startup
		-- already reported the same configuration error.
		notified_error = nil
		if configure_error then
			return fail(configure_error)
		end
		local locked, lock_err = M.lock_ok()
		if not locked then
			return fail(lock_unavailable(lock_err))
		end
		-- Lazy skips config() for a plugin that is not installed, and startup
		-- never installs missing plugins. Name the explicit restore path.
		return fail(
			"Markdown reading view unavailable: md-render.nvim is not installed or was not loaded; "
				.. "run :Lazy install md-render.nvim (or scripts/provision-runtime --allow-network) and restart"
		)
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

local function render_winhighlight(value)
	local mappings = {}
	for mapping in value:gmatch("[^,]+") do
		if not mapping:match("^String:") then
			mappings[#mappings + 1] = mapping
		end
	end
	mappings[#mappings + 1] = "String:MdRenderCodeBlock"
	return table.concat(mappings, ",")
end

local function apply_render_winhighlight(win, source_winhighlight)
	local current = vim.api.nvim_get_option_value("winhighlight", { win = win })
	local ok, original = pcall(vim.api.nvim_win_get_var, win, render_winhighlight_var)
	if not ok then
		original = source_winhighlight or current
		vim.api.nvim_win_set_var(win, render_winhighlight_var, original)
	end
	local applied = render_winhighlight(original)
	if current ~= applied then
		vim.api.nvim_set_option_value("winhighlight", applied, { win = win })
	end
end

local function restore_render_window(win)
	local ok, original = pcall(vim.api.nvim_win_get_var, win, render_winhighlight_var)
	if ok then
		vim.api.nvim_set_option_value("winhighlight", original, { win = win })
		vim.api.nvim_win_del_var(win, render_winhighlight_var)
	end
	local has_options, options = pcall(vim.api.nvim_win_get_var, win, render_window_options_var)
	if has_options then
		for name, value in pairs(options) do
			vim.api.nvim_set_option_value(name, value, { win = win })
		end
		vim.api.nvim_win_del_var(win, render_window_options_var)
	end
end

local function keep_cursor_on_page(win, session)
	if not session or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then
		return
	end
	local margin = session.opts and session.opts.nvim_config_page_margin
	if type(margin) ~= "number" or margin <= 0 then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	if cursor[2] < margin then
		vim.api.nvim_win_set_cursor(win, { cursor[1], margin })
	end
end

local function remember_source_window_options(win)
	local has_options = pcall(vim.api.nvim_win_get_var, win, render_window_options_var)
	if not has_options then
		vim.api.nvim_win_set_var(win, render_window_options_var, {
			wrap = vim.wo[win].wrap,
			linebreak = vim.wo[win].linebreak,
			breakindent = vim.wo[win].breakindent,
		})
	end
end

-- The reading view's wrap mode belongs to its session, so it survives live
-- updates, resizes and pager source/render toggles. Only a change to the
-- window's 'wrap' option (:ToggleWrap, :setlocal wrap!) switches it.
local function wrap_mode(session)
	return not (session and session.opts and session.opts.nvim_config_wrap == false)
end

local function set_window_option(win, name, value)
	if vim.api.nvim_get_option_value(name, { win = win }) ~= value then
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
end

local function configure_render_window(win, session)
	remember_source_window_options(win)
	local wrap = wrap_mode(session)
	set_window_option(win, "wrap", wrap)
	set_window_option(win, "linebreak", wrap)
	set_window_option(win, "breakindent", true)
	if wrap then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview({ leftcol = 0 })
		end)
	end
end

local function protect_cursor_rebuild(session)
	if session.nvim_config_cursor_rebuild then
		return
	end
	local rebuild = session.rebuild
	session.rebuild = function(self, ...)
		rebuilding = rebuilding + 1
		local ok, result = pcall(function(...)
			local value = rebuild(self, ...)
			for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
				if vim.api.nvim_win_is_valid(win) then
					configure_render_window(win, self)
					keep_cursor_on_page(win, self)
				end
			end
			return value
		end, ...)
		rebuilding = rebuilding - 1
		if not ok then
			error(result, 0)
		end
		return result
	end
	session.nvim_config_cursor_rebuild = true
end

local function protect_render_buffer(win, source_winhighlight)
	local state = win_state(win)
	if not state then
		return nil
	end
	local session = renderer.preview._toggle_sessions[state.source_buf]
	if session then
		markdown_tables.protect_rebuild(session)
		markdown_codeblocks.protect_rebuild(session)
		protect_cursor_rebuild(session)
	end
	vim.bo[state.render_buf].modifiable = false
	vim.bo[state.render_buf].readonly = true
	configure_render_window(win, session)
	apply_render_winhighlight(win, source_winhighlight)
	palette.apply_markdown()
	if session then
		markdown_codeblocks.decorate(session)
		keep_cursor_on_page(win, session)
	end
	return state
end

local function tracked_preview(source_buf)
	local preview = previews[source_buf]
	if not preview then
		return nil
	end
	if
		not vim.api.nvim_win_is_valid(preview.win)
		or not vim.api.nvim_tabpage_is_valid(preview.tab)
		or vim.api.nvim_win_get_tabpage(preview.win) ~= preview.tab
		or not win_state(preview.win)
		or win_state(preview.win).source_buf ~= source_buf
	then
		previews[source_buf] = nil
		return nil
	end
	return preview
end

local function close_preview(preview)
	previews[preview.source_buf] = nil
	if not vim.api.nvim_tabpage_is_valid(preview.tab) then
		return
	end
	vim.api.nvim_set_current_tabpage(preview.tab)
	if #vim.api.nvim_tabpage_list_wins(preview.tab) > 1 then
		-- A user-created split belongs to the user, even inside our tab.
		vim.api.nvim_win_close(preview.win, true)
	elseif vim.api.nvim_tabpage_is_valid(preview.source_tab) and vim.api.nvim_list_tabpages()[2] then
		vim.cmd("tabclose")
	else
		-- The user may have closed the source tab manually. Keep this tab and
		-- restore its editable source instead of losing the document.
		renderer.preview.toggle()
		restore_render_window(preview.win)
	end
	if vim.api.nvim_tabpage_is_valid(preview.source_tab) then
		vim.api.nvim_set_current_tabpage(preview.source_tab)
		if
			vim.api.nvim_win_is_valid(preview.source_win)
			and vim.api.nvim_win_get_buf(preview.source_win) == preview.source_buf
		then
			vim.api.nvim_set_current_win(preview.source_win)
		end
	end
end

local function reflow_preview(preview)
	if not tracked_preview(preview.source_buf) then
		return
	end
	local session = renderer.preview._toggle_sessions[preview.source_buf]
	if not session then
		return
	end
	local page_width, margin, block_width = markdown_layout.measure(preview.win)
	local render_width = markdown_layout.render_width(page_width)
	local block_render_width = markdown_layout.render_width(block_width)
	if
		session.opts.max_width ~= render_width
		or session.opts.nvim_config_page_width ~= page_width
		or session.opts.nvim_config_page_margin ~= margin
		or session.opts.nvim_config_block_width ~= block_render_width
	then
		session.opts.max_width = render_width
		session.opts.nvim_config_page_width = page_width
		session.opts.nvim_config_page_margin = margin
		session.opts.nvim_config_block_width = block_render_width
		session:rebuild()
	end
	configure_render_window(preview.win, session)
	keep_cursor_on_page(preview.win, session)
end

-- The pager keeps md-render's own prose width, but tables and code blocks may
-- use the whole window.
local function pager_block_width(win)
	return markdown_layout.render_width(markdown_layout.text_width(win))
end

local function protected_session(win)
	local state = win_state(win)
	local session = state and renderer and renderer.preview._toggle_sessions[state.source_buf]
	if session and session.nvim_config_cursor_rebuild then
		return session
	end
	return nil
end

local function reflow_pager(win)
	local session = protected_session(win)
	if not session then
		return
	end
	local block_width = pager_block_width(win)
	if session.opts.nvim_config_block_width ~= block_width then
		session.opts.nvim_config_block_width = block_width
		session:rebuild()
	end
	configure_render_window(win, session)
end

local function reflow_all()
	if pager.active then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			reflow_pager(win)
		end
		return
	end
	for _, preview in pairs(previews) do
		reflow_preview(preview)
	end
end

-- OptionSet runs with the changed window current. Adopt a user's wrap change
-- as the session's mode and rerender: tables switch between the block width
-- and their natural width.
local function adopt_window_wrap()
	if rebuilding > 0 then
		return
	end
	local win = vim.api.nvim_get_current_win()
	local session = protected_session(win)
	if not session then
		return
	end
	local wrap = vim.api.nvim_get_option_value("wrap", { win = win })
	if wrap == wrap_mode(session) then
		return
	end
	session.opts.nvim_config_wrap = wrap
	local ok, err = pcall(session.rebuild, session)
	if not ok then
		notify("Could not apply the reading view wrap mode: " .. tostring(err), vim.log.levels.ERROR)
	end
end

local function keep_active_cursor_on_page()
	if not vim.b[vim.api.nvim_get_current_buf()].md_render then
		return
	end
	local win = vim.api.nvim_get_current_win()
	local state = win_state(win)
	local session = state and renderer and renderer.preview._toggle_sessions[state.source_buf]
	keep_cursor_on_page(win, session)
end

local function editor_toggle()
	local preview_api = ensure_renderer()
	if not preview_api then
		return
	end
	local current_win = vim.api.nvim_get_current_win()
	local source_buf, state = source_for_window(current_win)
	if state then
		local current_preview = tracked_preview(source_buf)
		if current_preview and current_preview.win == current_win then
			close_preview(current_preview)
		else
			preview_api.toggle()
			restore_render_window(current_win)
		end
		return
	end
	if vim.bo[source_buf].filetype ~= "markdown" then
		notify("MarkdownView requires a Markdown source buffer")
		return
	end
	local existing = tracked_preview(source_buf)
	if existing then
		vim.api.nvim_set_current_tabpage(existing.tab)
		vim.api.nvim_set_current_win(existing.win)
		reflow_preview(existing)
		return
	end
	local source_tab = vim.api.nvim_get_current_tabpage()
	local source_winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = current_win })
	local ok, err = pcall(vim.cmd, "tab split")
	if not ok then
		fail("Could not open Markdown reading view: " .. tostring(err))
		return
	end
	local render_tab = vim.api.nvim_get_current_tabpage()
	local render_win = vim.api.nvim_get_current_win()
	local page_width, margin, block_width = markdown_layout.measure(render_win)
	remember_source_window_options(render_win)
	local toggled, toggle_err = pcall(preview_api.toggle, {
		max_width = markdown_layout.render_width(page_width),
		nvim_config_page_width = page_width,
		nvim_config_page_margin = margin,
		nvim_config_block_width = markdown_layout.render_width(block_width),
		text_scale = false,
	})
	if not toggled or not win_state(render_win) then
		vim.cmd("tabclose")
		fail("Could not open Markdown reading view: " .. tostring(toggle_err or "renderer did not create a view"))
		return
	end
	protect_render_buffer(render_win, source_winhighlight)
	markdown_render_navigation.attach(renderer.preview._toggle_sessions[source_buf])
	vim.keymap.set("n", "<leader>mv", M.toggle, {
		buffer = vim.api.nvim_win_get_buf(render_win),
		desc = "Close Markdown reading view",
	})
	vim.keymap.set("n", "<leader>md", "<cmd>DiagramShow<cr>", {
		buffer = vim.api.nvim_win_get_buf(render_win),
		desc = "Show diagram (SVG/ASCII)",
	})
	vim.keymap.set("x", "<leader>md", ":<C-U>'<,'>DiagramShow<CR>", {
		buffer = vim.api.nvim_win_get_buf(render_win),
		desc = "Show selected diagram",
	})
	local preview = {
		tab = render_tab,
		win = render_win,
		source_buf = source_buf,
		source_tab = source_tab,
		source_win = current_win,
	}
	previews[source_buf] = preview
	reflow_preview(preview)
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
		if vim.api.nvim_win_get_buf(win) == source_buf then
			restore_render_window(win)
			pager_source_requested[source_buf] = true
		end
		return
	end
	if vim.bo[source_buf].filetype ~= "markdown" then
		notify("MarkdownView requires a Markdown source buffer")
		return
	end
	pager_source_requested[source_buf] = nil
	local source_winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = win })
	remember_source_window_options(win)
	preview_api.toggle({ text_scale = false, nvim_config_block_width = pager_block_width(win) })
	if protect_render_buffer(win, source_winhighlight) then
		reflow_pager(win)
	else
		restore_render_window(win)
	end
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
		if vim.api.nvim_win_get_buf(win) == source_buf then
			restore_render_window(win)
		end
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
				local source_winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = win })
				remember_source_window_options(win)
				vim.api.nvim_win_call(win, function()
					preview_api.toggle({ text_scale = false, nvim_config_block_width = pager_block_width(win) })
				end)
				if protect_render_buffer(win, source_winhighlight) then
					reflow_pager(win)
				else
					restore_render_window(win)
				end
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
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("MarkdownViewPalette", { clear = true }),
		callback = palette.apply_markdown,
	})
	vim.api.nvim_create_user_command("MarkdownView", M.toggle, { desc = "Toggle rendered Markdown reading view" })
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufEnter" }, {
		group = vim.api.nvim_create_augroup("MarkdownViewCursor", { clear = true }),
		callback = keep_active_cursor_on_page,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
		group = vim.api.nvim_create_augroup("MarkdownViewReflow", { clear = true }),
		callback = reflow_all,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		pattern = "wrap",
		group = vim.api.nvim_create_augroup("MarkdownViewWrap", { clear = true }),
		callback = adopt_window_wrap,
	})
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
