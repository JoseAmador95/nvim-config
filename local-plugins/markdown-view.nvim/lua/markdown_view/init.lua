-- Read-only live Markdown views over a stock, pinned md-render engine.
local M = {}
local compat = require("markdown_view.compat")
local layout = require("markdown_view.layout")
local decorations = require("markdown_view.decorations")
local media = require("markdown_view.media")

M.PIN = compat.PIN
local ready = false
local options = {
	pager = function()
		return false
	end,
}
local previews = {}
local pager_source_requested = {}
local pager_filetype_pending = {}
local render_window_options_var = "nvim_config_md_render_window_options"
local win_state = compat.window_state

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "Markdown" })
end

local function fail(message)
	notify(message, vim.log.levels.ERROR)
	return nil, message
end

local function ensure_renderer()
	if ready then
		return compat
	end
	return fail("Markdown reading view is not configured")
end

local function rebuild_document(source_buf)
	local session = compat.session(source_buf)
	if not session or not vim.api.nvim_buf_is_valid(session.buf) then
		return
	end
	if session:is_visible() then
		session:rebuild()
		session:refresh_images()
	else
		session.dirty = true
	end
end

function M.build_snapshot(lines, opts)
	if not ensure_renderer() then
		return nil, "Markdown reading view is not configured"
	end
	return compat.snapshot(lines, opts)
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

local function remember_source_window_options(win)
	local ok, saved = pcall(vim.api.nvim_win_get_var, win, render_window_options_var)
	if not ok then
		saved = {}
		for _, name in ipairs({ "wrap", "linebreak", "breakindent", "breakindentopt", "winhighlight" }) do
			saved[name] = vim.api.nvim_get_option_value(name, { win = win })
		end
		vim.api.nvim_win_set_var(win, render_window_options_var, saved)
	end
	return saved
end

local function restore_render_window(win)
	local ok, saved = pcall(vim.api.nvim_win_get_var, win, render_window_options_var)
	if ok then
		for name, value in pairs(saved) do
			vim.api.nvim_set_option_value(name, value, { win = win })
		end
		vim.api.nvim_win_del_var(win, render_window_options_var)
	end
end

-- The reading view's wrap mode belongs to its session, so it survives live
-- updates, resizes and pager source/render toggles. Editor actions and explicit
-- changes to the window's 'wrap' option switch it.
local function wrap_mode(session)
	return not (session and session.opts and session.opts.nvim_config_wrap == false)
end

local function set_window_option(win, name, value)
	if vim.api.nvim_get_option_value(name, { win = win }) ~= value then
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
end

-- Wrapped rows start after the virtual page margin, like the row they continue.
local function page_breakindentopt(win, session)
	local margin = session and session.opts and session.opts.nvim_config_page_margin
	if type(margin) == "number" and margin >= 1 then
		return "shift:" .. math.floor(margin)
	end
	return vim.api.nvim_win_get_var(win, render_window_options_var).breakindentopt
end

local function configure_render_window(win, session)
	remember_source_window_options(win)
	local wrap = wrap_mode(session)
	set_window_option(win, "wrap", wrap)
	set_window_option(win, "linebreak", wrap)
	set_window_option(win, "breakindent", true)
	set_window_option(win, "breakindentopt", page_breakindentopt(win, session))
	if wrap then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview({ leftcol = 0 })
		end)
	end
end

local function finish_rebuild(session)
	decorations.decorate(session)
	layout.pad(session.buf, session.opts.nvim_config_page_margin)
	for _, win in ipairs(vim.fn.win_findbuf(session.buf)) do
		configure_render_window(win, session)
	end
end

local function protect_render_buffer(win)
	local state = win_state(win)
	if not state then
		return nil
	end
	local session = compat.session(state.source_buf)
	compat.protect(session, finish_rebuild)
	vim.bo[state.render_buf].modifiable = false
	vim.bo[state.render_buf].readonly = true
	local saved = remember_source_window_options(win)
	set_window_option(win, "winhighlight", render_winhighlight(saved.winhighlight))
	options.theme()
	finish_rebuild(session)
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
		compat.toggle()
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

local function page_options(win)
	if options.pager() then
		return { nvim_config_block_width = layout.render_width(layout.text_width(win)) }
	end
	local width, margin, block_width = layout.measure(win)
	return {
		max_width = layout.render_width(width),
		nvim_config_page_width = width,
		nvim_config_page_margin = margin,
		nvim_config_block_width = layout.render_width(block_width),
	}
end

local function protected_session(win)
	local state = win_state(win)
	local session = state and compat.session(state.source_buf)
	if session and session.markdown_view_protected then
		return session
	end
	return nil
end

---Apply a wrap action directly: OptionSet does not run inside non-nested
---callbacks or when the caller has ignored that event.
---@param enabled boolean
---@param win? integer
---@return boolean handled Whether the window is a protected reading view
function M.set_wrap(enabled, win)
	win = win or vim.api.nvim_get_current_win()
	local session = protected_session(win)
	if not session then
		return false
	end
	if enabled ~= wrap_mode(session) then
		session.opts.nvim_config_wrap = enabled
		session:rebuild()
		session:refresh_images()
	else
		configure_render_window(win, session)
	end
	return true
end

local function reflow(win)
	local session = protected_session(win)
	if not session then
		return
	end
	local changed = false
	for key, value in pairs(page_options(win)) do
		changed = changed or session.opts[key] ~= value
		session.opts[key] = value
	end
	if changed then
		session:rebuild()
		session:refresh_images()
	end
	configure_render_window(win, session)
end

local function reflow_all()
	if options.pager() then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			reflow(win)
		end
	else
		for source_buf, preview in pairs(previews) do
			if tracked_preview(source_buf) then
				reflow(preview.win)
			end
		end
	end
end

-- OptionSet runs with the changed window current. Adopt a user's wrap change
-- as the session's mode and rerender: tables switch between the block width
-- and their natural width.
local function adopt_window_wrap()
	if compat.rebuilding() then
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
	local ok, err = pcall(M.set_wrap, wrap, win)
	if not ok then
		notify("Could not apply the reading view wrap mode: " .. tostring(err), vim.log.levels.ERROR)
	end
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
		reflow(existing.win)
		return
	end
	local source_tab = vim.api.nvim_get_current_tabpage()
	local ok, err = pcall(vim.cmd, "tab split")
	if not ok then
		fail("Could not open Markdown reading view: " .. tostring(err))
		return
	end
	local render_tab = vim.api.nvim_get_current_tabpage()
	local render_win = vim.api.nvim_get_current_win()
	remember_source_window_options(render_win)
	local toggled, toggle_err = pcall(
		preview_api.toggle,
		vim.tbl_extend("force", page_options(render_win), { nvim_config_image_doc = source_buf, text_scale = false })
	)
	if not toggled or not win_state(render_win) then
		vim.cmd("tabclose")
		fail("Could not open Markdown reading view: " .. tostring(toggle_err or "renderer did not create a view"))
		return
	end
	protect_render_buffer(render_win)
	options.attach(compat.session(source_buf))
	local preview = {
		tab = render_tab,
		win = render_win,
		source_buf = source_buf,
		source_tab = source_tab,
		source_win = current_win,
	}
	previews[source_buf] = preview
	reflow(preview.win)
end

local function show_pager(win, source_buf)
	remember_source_window_options(win)
	vim.api.nvim_win_call(win, function()
		compat.toggle({
			text_scale = false,
			nvim_config_block_width = page_options(win).nvim_config_block_width,
			nvim_config_image_doc = source_buf,
		})
	end)
	if protect_render_buffer(win) then
		reflow(win)
	else
		restore_render_window(win)
	end
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
	show_pager(win, source_buf)
end

function M.toggle()
	if options.pager() then
		pager_toggle()
	else
		editor_toggle()
	end
end

-- Choose whether the current document loads remote images.
function M.images()
	if not ensure_renderer() then
		return
	end
	local source_buf = source_for_window(vim.api.nvim_get_current_win())
	if vim.bo[source_buf].filetype ~= "markdown" then
		notify("MarkdownImages requires a Markdown buffer")
		return
	end
	media.choose(source_buf)
end

function M.pager_show_source(win)
	if not vim.api.nvim_win_is_valid(win) then
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
	if not options.pager() or not vim.api.nvim_buf_is_valid(buf) then
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
				show_pager(win, buf)
			end
		end
	end)
end

function M.pager_initial_render()
	if options.pager() then
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
	local session = compat.session(source_buf)
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

---Configure with the stock engine and host policy. Unknown keys are rejected
---before any state, option, command, mapping or engine mutation.
function M.setup(opts)
	local keys = {
		engine = "table",
		wrap = "table",
		image = "table",
		preferences = "table",
		pager = "function",
		theme = "function",
		attach = "function",
	}
	if type(opts) ~= "table" then
		return nil, "Markdown view options must be a table"
	end
	for key, value in pairs(opts) do
		if not keys[key] or type(value) ~= keys[key] then
			return nil, "invalid Markdown view option: " .. tostring(key)
		end
	end
	if opts.preferences and (type(opts.preferences.get) ~= "function" or type(opts.preferences.set) ~= "function") then
		return nil, "image preferences require get and set callbacks"
	end
	local ok, err = compat.configure(opts.engine, opts.wrap, opts.image, opts.preferences, rebuild_document)
	if not ok then
		ready = false
		return nil, err
	end
	options = {
		pager = opts.pager or function()
			return false
		end,
		theme = opts.theme or function() end,
		attach = opts.attach or function() end,
	}
	ready = true
	options.theme()
	local group = vim.api.nvim_create_augroup("MarkdownViewLayout", { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, { group = group, callback = reflow_all })
	vim.api.nvim_create_autocmd("OptionSet", { pattern = "wrap", group = group, callback = adopt_window_wrap })
	return true
end

function M.status()
	return { configured = ready, previews = vim.tbl_count(previews) }
end

function M.effective_config()
	return { configured = ready, engine = "md-render.nvim", commit = M.PIN, page_ratio = 0.9, max_page_width = 120 }
end

return M
