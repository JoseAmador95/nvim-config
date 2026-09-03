-- Small buffer-local editor used for review comments and replies.
local M = {}

local config = require("native_review.dependencies").get("config")
local comment_types = require("native_review.comment_types")

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_editor")
local FOOTER_NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_editor_footer")
local INLINE_MAX_HEIGHT = 6
local MODAL_MAX_HEIGHT = 18
local MAX_WIDTH = 88
local MIN_MODAL_WIDTH = 24
local active

local EDITOR_HIGHLIGHT_LINKS = {
	NvimReviewComposerBody = "NormalFloat",
	NvimReviewComposerBorder = "FloatBorder",
	NvimReviewComposerMuted = "Comment",
	NvimReviewComposerTitle = "FloatTitle",
}

local function apply_editor_highlights()
	for name, link in pairs(EDITOR_HIGHLIGHT_LINKS) do
		vim.api.nvim_set_hl(0, name, { default = true, link = link })
	end
end

apply_editor_highlights()
local highlight_group = vim.api.nvim_create_augroup("NvimReviewComposerHighlights", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
	group = highlight_group,
	callback = apply_editor_highlights,
})

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function scope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		return pcall(vim.api.nvim_win_add_ns, win, namespace)
	end
	if type(vim.api.nvim__ns_set) == "function" then
		return pcall(vim.api.nvim__ns_set, namespace, { wins = { win } })
	end
	return false, "window-scoped namespaces are unavailable"
end

local function unscope_namespace(win, namespace)
	if type(vim.api.nvim_win_add_ns) == "function" and type(vim.api.nvim_win_remove_ns) == "function" then
		if valid_win(win) then
			pcall(vim.api.nvim_win_remove_ns, win, namespace)
		end
	elseif type(vim.api.nvim__ns_set) == "function" then
		pcall(vim.api.nvim__ns_set, namespace, { wins = {} })
	end
end

local function source_available(win, buf)
	return valid_win(win) and valid_buf(buf) and vim.api.nvim_win_get_buf(win) == buf
end

local function source_width(win, chrome_width)
	local info = vim.fn.getwininfo(win)[1] or {}
	local textoff = tonumber(info.textoff) or 0
	chrome_width = chrome_width or 0
	return math.max(
		1,
		math.min(math.max(1, MAX_WIDTH - chrome_width), vim.api.nvim_win_get_width(win) - textoff - chrome_width)
	)
end

local function range_anchor_line(options, source_win)
	local line = tonumber(options.anchor_line)
	local function endpoint(anchor)
		if type(anchor) ~= "table" then
			return nil
		end
		return tonumber(anchor.last or anchor.end_line or anchor[2] or anchor.first or anchor.start_line or anchor[1])
	end
	if not line then
		line = endpoint(options.anchor_range)
	end
	if not line then
		line = endpoint(options.anchor)
	end
	local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(source_win))
	if not line or line ~= math.floor(line) or line < 1 or line > count then
		return nil
	end
	return line
end

local function composer_layout(options)
	local kind = type(options.anchor) == "table" and options.anchor.kind or nil
	if kind == "range" then
		return "inline"
	elseif kind == "file" or kind == "general" then
		return "modal"
	end
	if kind == nil then
		return nil, "Review editor anchor kind is missing"
	end
	return nil, "Review editor anchor kind is not supported: " .. tostring(kind)
end

local function trim_body(lines)
	while #lines > 0 and lines[1]:match("^%s*$") do
		table.remove(lines, 1)
	end
	while #lines > 0 and lines[#lines]:match("^%s*$") do
		table.remove(lines)
	end
	return table.concat(lines, "\n")
end

local function screen_rows(buf, width, maximum)
	local rows = 0
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width)))
		if rows >= maximum then
			return maximum
		end
	end
	return math.max(1, rows)
end

local function editor_title(options, selected_type)
	local title = options.title or "Review comment"
	if selected_type then
		local definition = comment_types.get(selected_type)
		local badge = definition and (definition.icon .. " " .. definition.id) or selected_type
		title = title .. " " .. badge
	end
	return title
end

local function has_type_cycle(options)
	return options.type_cycle == true
end

local function editor_hint(options, selected_type)
	local title = editor_title(options, selected_type)
	local type_hint = has_type_cycle(options) and "  ·  <Tab>/<S-Tab> type" or ""
	return (" %s%s  ·  <C-s> / <CR><CR> save "):format(title, type_hint)
end

local function fit_display(value, width)
	width = math.max(0, width)
	if vim.fn.strdisplaywidth(value) <= width then
		return value
	elseif width == 0 then
		return ""
	elseif width == 1 then
		return "…"
	end
	local result = ""
	for index = 0, vim.fn.strchars(value) - 1 do
		local character = vim.fn.strcharpart(value, index, 1)
		if vim.fn.strdisplaywidth(result .. character .. "…") > width then
			break
		end
		result = result .. character
	end
	return result .. "…"
end

local function fit_editor_title(options, selected_type, width)
	local title = options.title or "Review comment"
	if not selected_type then
		return fit_display(title, width)
	end
	local definition = comment_types.get(selected_type)
	local badge = definition and (definition.icon .. " " .. definition.id) or selected_type
	local suffix = " " .. badge
	local suffix_width = vim.fn.strdisplaywidth(suffix)
	if suffix_width >= width then
		return fit_display(badge, width)
	end
	return fit_display(title, width - suffix_width) .. suffix
end

local function composer_style(options)
	return options.style or config.composer.style
end

local function type_definition(selected_type)
	return comment_types.get(selected_type)
end

local function type_badge(selected_type)
	local definition = type_definition(selected_type)
	if not definition then
		return nil, nil
	end
	return definition.icon .. " " .. definition.id, definition.highlight
end

local function highlighted_chunks(first, first_highlight, rest, rest_highlight, width)
	width = math.max(0, width)
	if width == 0 then
		return {}
	end
	first = tostring(first or "")
	rest = tostring(rest or "")
	local first_width = vim.fn.strdisplaywidth(first)
	if first_width >= width then
		return { { fit_display(first, width), first_highlight } }
	end
	local chunks = {}
	if first ~= "" then
		chunks[#chunks + 1] = { first, first_highlight }
	end
	local remaining = width - first_width
	if rest ~= "" and remaining > 0 then
		chunks[#chunks + 1] = { fit_display(rest, remaining), rest_highlight }
	end
	return chunks
end

local function chunks_width(chunks)
	local width = 0
	for _, chunk in ipairs(chunks or {}) do
		width = width + vim.fn.strdisplaywidth(chunk[1] or "")
	end
	return width
end

local function card_title(options, selected_type, width)
	local badge, badge_highlight = type_badge(selected_type)
	local title = " " .. tostring(options.title or "Review comment") .. " "
	if not badge then
		return { { fit_display(title, width), "NvimReviewComposerTitle" } }
	end
	return highlighted_chunks(" " .. badge .. " ", badge_highlight, "· " .. title, "NvimReviewComposerTitle", width)
end

local function card_footer(options, selected_type, width)
	local badge, badge_highlight = type_badge(selected_type)
	local controls = has_type_cycle(options) and " · <Tab>/<S-Tab> type · <C-s>/↵↵ save · q/Esc cancel "
		or " · <C-s>/↵↵ save · q/Esc cancel "
	if not badge then
		return { { fit_display(" " .. controls, width), "NvimReviewComposerMuted" } }
	end
	return highlighted_chunks(" " .. badge .. " ", badge_highlight, controls, "NvimReviewComposerMuted", width)
end

local function card_border(selected_type)
	local definition = type_definition(selected_type)
	local accent = definition and definition.highlight or "NvimReviewComposerBorder"
	return {
		{ "╭", accent },
		{ "─", "NvimReviewComposerBorder" },
		{ "╮", "NvimReviewComposerBorder" },
		{ "│", "NvimReviewComposerBorder" },
		{ "╯", "NvimReviewComposerBorder" },
		{ "─", "NvimReviewComposerBorder" },
		{ "╰", accent },
		{ "│", accent },
	}
end

local function editor_controls(options, spacious)
	local type_hint = has_type_cycle(options) and "<Tab>/<S-Tab> type" or nil
	local save_hint = spacious and "<C-s> / <CR><CR> save" or "<C-s>/<CR><CR> save"
	return type_hint and (type_hint .. " · " .. save_hint) or save_hint
end

local function inline_footer_text(options, selected_type, width)
	local full = editor_hint(options, selected_type)
	if vim.fn.strdisplaywidth(full) <= width then
		return full
	end
	local controls = editor_controls(options, false)
	local title = editor_title(options, selected_type)
	local compact = title .. " · " .. controls
	if vim.fn.strdisplaywidth(compact) <= width then
		return compact
	end
	local separator = " · "
	local title_width = width - vim.fn.strdisplaywidth(separator .. controls)
	if title_width > 0 then
		return fit_editor_title(options, selected_type, title_width) .. separator .. controls
	end
	local compact_controls = has_type_cycle(options) and "Tab/S-Tab:type · <C-s>/↵↵:save" or "<C-s>/↵↵:save"
	local compact_title_width = width - vim.fn.strdisplaywidth(separator .. compact_controls)
	if compact_title_width > 0 then
		return fit_editor_title(options, selected_type, compact_title_width) .. separator .. compact_controls
	end
	local essential = "<C-s>:save"
	if selected_type then
		local definition = comment_types.get(selected_type)
		local badge = definition and (definition.icon .. " " .. definition.id) or selected_type
		essential = badge .. " · " .. essential
	end
	if has_type_cycle(options) then
		essential = essential .. " · Tab:type"
	end
	return fit_display(essential, width)
end

local function content_width(buf)
	local width = 1
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	return width
end

local function blank_virtual_lines(count)
	local lines = {}
	for _ = 1, count do
		lines[#lines + 1] = { { "", "NormalFloat" } }
	end
	return lines
end

---Open a focused Markdown scratch buffer for a canonical review anchor.
---@param options? { title?: string, body?: string, recover?: fun(body: string, selected_type?: string): boolean, type_cycle?: boolean, selected_type?: string, style?: "card"|"minimal", source_win?: integer, source_window?: integer, anchor_line?: integer, anchor_range?: { first?: integer, last?: integer, start_line?: integer, end_line?: integer, [1]?: integer, [2]?: integer }, anchor?: { kind?: string, [string]: any } }
---@param callback fun(body: string?, interrupted?: boolean, selected_type?: string): boolean?
function M.compose(options, callback)
	options = options or {}
	if M.has_active() then
		vim.notify(
			"Finish the current review comment before opening another",
			vim.log.levels.WARN,
			{ title = "Review" }
		)
		return false
	end
	local layout, layout_err = composer_layout(options)
	if not layout then
		vim.notify(layout_err, vim.log.levels.ERROR, { title = "Review" })
		return false
	end
	local style = composer_style(options)
	if style ~= "card" and style ~= "minimal" then
		vim.notify("Review editor style must be card or minimal", vim.log.levels.ERROR, { title = "Review" })
		return false
	end

	local source_win = options.source_win or options.source_window
	if not valid_win(source_win) then
		vim.notify("Reviewed code window is no longer available", vim.log.levels.ERROR, { title = "Review" })
		return false
	end
	local source_buf = vim.api.nvim_win_get_buf(source_win)
	if not valid_buf(source_buf) then
		vim.notify("Reviewed code buffer is no longer available", vim.log.levels.ERROR, { title = "Review" })
		return false
	end
	local source_line
	local source_row
	if layout == "inline" then
		source_line = range_anchor_line(options, source_win)
		if not source_line then
			vim.notify("Review editor anchor is no longer available", vim.log.levels.ERROR, { title = "Review" })
			return false
		end
		source_row = source_line - 1
		local scoped, scope_err = scope_namespace(source_win, NAMESPACE)
		if not scoped then
			unscope_namespace(source_win, NAMESPACE)
			vim.notify(
				"Could not isolate review editor reservation: " .. tostring(scope_err),
				vim.log.levels.ERROR,
				{ title = "Review" }
			)
			return false
		end
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false
	local lines = vim.split(options.body or "", "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local selected_type = options.selected_type
	if has_type_cycle(options) and not comment_types.contains(selected_type) then
		selected_type = comment_types.ids()[1]
	end
	local finished = false
	local autocmds = {}
	local win
	local footer_buf
	local footer_win
	local reservation
	local namespace_scoped = layout == "inline"

	local function clear_autocmds()
		for _, id in ipairs(autocmds) do
			pcall(vim.api.nvim_del_autocmd, id)
		end
		autocmds = {}
	end

	local function clear_reservation()
		if layout == "inline" and reservation and valid_buf(source_buf) then
			pcall(vim.api.nvim_buf_del_extmark, source_buf, NAMESPACE, reservation)
		end
		reservation = nil
		if namespace_scoped then
			unscope_namespace(source_win, NAMESPACE)
			namespace_scoped = false
		end
	end

	local function set_reservation(height)
		local extmark_options = { virt_lines = blank_virtual_lines(height) }
		if reservation then
			extmark_options.id = reservation
		end
		reservation = vim.api.nvim_buf_set_extmark(source_buf, NAMESPACE, source_row, 0, extmark_options)
	end

	local function set_footer_line(width)
		if not valid_buf(footer_buf) then
			return
		end
		local footer = inline_footer_text(options, selected_type, width)
		vim.bo[footer_buf].modifiable = true
		vim.api.nvim_buf_set_lines(footer_buf, 0, -1, false, { footer })
		vim.bo[footer_buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(footer_buf, FOOTER_NAMESPACE, 0, -1)
		local definition = type_definition(selected_type)
		local badge = definition and (definition.icon .. " " .. definition.id) or selected_type
		local first = badge and footer:find(badge, 1, true) or nil
		if definition and first then
			vim.api.nvim_buf_set_extmark(footer_buf, FOOTER_NAMESPACE, 0, first - 1, {
				end_col = first + #badge - 1,
				hl_group = definition.highlight,
			})
		end
	end

	local function maintain_inline_eof_view(reserved_rows)
		if source_line ~= vim.api.nvim_buf_line_count(source_buf) then
			return
		end
		vim.api.nvim_win_call(source_win, function()
			local height = vim.api.nvim_win_get_height(source_win)
			local effective_below = math.min(reserved_rows, math.max(height - 1, 0))
			local view = vim.fn.winsaveview()
			local min_topline = math.min(source_line, math.max(1, source_line - (height - 1 - effective_below)))
			if view.topline < min_topline then
				view.topline = min_topline
				vim.fn.winrestview(view)
			end
		end)
	end

	local function inline_geometry()
		local card = style == "card"
		local chrome_rows = card and 2 or 1
		local width = source_width(source_win, card and 2 or 0)
		local available_height = math.max(1, vim.api.nvim_win_get_height(source_win) - chrome_rows - 1)
		local height = screen_rows(buf, width, math.min(INLINE_MAX_HEIGHT, available_height))
		maintain_inline_eof_view(height + chrome_rows)
		return width, height
	end

	local function inline_window_config(width, height)
		local window_config = {
			relative = "win",
			win = source_win,
			bufpos = { source_row, 0 },
			row = 1,
			col = 0,
			width = width,
			height = height,
			style = "minimal",
			zindex = 60,
		}
		if style == "card" then
			window_config.border = card_border(selected_type)
			window_config.title = card_title(options, selected_type, width)
			window_config.title_pos = "left"
			window_config.footer = card_footer(options, selected_type, width)
			window_config.footer_pos = "left"
		else
			window_config.border = "none"
		end
		return window_config
	end

	local function modal_geometry()
		local columns = math.max(3, tonumber(vim.o.columns) or MAX_WIDTH + 2)
		local screen_height = math.max(4, tonumber(vim.o.lines) or MODAL_MAX_HEIGHT + 4)
		local width_limit = math.max(1, math.min(MAX_WIDTH, columns - 2))
		local desired_width = math.max(
			MIN_MODAL_WIDTH,
			content_width(buf),
			vim.fn.strdisplaywidth(editor_title(options, selected_type)) + 2,
			vim.fn.strdisplaywidth(editor_controls(options, true)) + 2,
			chunks_width(card_title(options, selected_type, MAX_WIDTH)),
			chunks_width(card_footer(options, selected_type, MAX_WIDTH))
		)
		local width = math.min(width_limit, desired_width)
		local height_limit = math.max(1, math.min(MODAL_MAX_HEIGHT, screen_height - 4))
		local height = screen_rows(buf, width, height_limit)
		local window_config = {
			relative = "editor",
			row = math.max(0, math.floor((screen_height - height - 2) / 2)),
			col = math.max(0, math.floor((columns - width - 2) / 2)),
			width = width,
			height = height,
			style = "minimal",
			title_pos = "center",
			footer_pos = "center",
			zindex = 60,
		}
		if style == "card" then
			window_config.border = card_border(selected_type)
			window_config.title = card_title(options, selected_type, width)
			window_config.footer = card_footer(options, selected_type, width)
		else
			window_config.border = "rounded"
			window_config.title = card_title(options, selected_type, width)
			window_config.footer = card_footer(options, selected_type, width)
		end
		return window_config
	end

	local function update_geometry()
		if finished or not valid_buf(buf) or not source_available(source_win, source_buf) then
			return
		end
		if layout == "inline" then
			local width, height = inline_geometry()
			if valid_win(win) then
				vim.api.nvim_win_set_config(win, inline_window_config(width, height))
				height = math.max(1, math.min(height, vim.api.nvim_win_get_height(win)))
			end
			set_reservation(height + (style == "card" and 2 or 1))
			if style == "minimal" then
				set_footer_line(width)
			end
			if style == "minimal" and valid_win(footer_win) then
				vim.api.nvim_win_set_config(footer_win, {
					relative = "win",
					win = source_win,
					bufpos = { source_row, 0 },
					row = height + 1,
					col = 0,
					width = width,
					height = 1,
				})
			end
		elseif valid_win(win) then
			vim.api.nvim_win_set_config(win, modal_geometry())
		end
	end

	if layout == "inline" then
		local initial_width, initial_height = inline_geometry()
		set_reservation(initial_height + (style == "card" and 2 or 1))
		win = vim.api.nvim_open_win(buf, true, inline_window_config(initial_width, initial_height))
		initial_height = math.max(1, math.min(initial_height, vim.api.nvim_win_get_height(win)))
		set_reservation(initial_height + (style == "card" and 2 or 1))
		if style == "minimal" then
			footer_buf = vim.api.nvim_create_buf(false, true)
			vim.bo[footer_buf].bufhidden = "wipe"
			vim.bo[footer_buf].swapfile = false
			set_footer_line(initial_width)
			footer_win = vim.api.nvim_open_win(footer_buf, false, {
				relative = "win",
				win = source_win,
				bufpos = { source_row, 0 },
				row = initial_height + 1,
				col = 0,
				width = initial_width,
				height = 1,
				style = "minimal",
				border = "none",
				focusable = false,
				zindex = 60,
			})
			vim.wo[footer_win].wrap = false
			vim.wo[footer_win].winhighlight = "NormalFloat:NvimReviewComposerMuted"
		end
	else
		win = vim.api.nvim_open_win(buf, true, modal_geometry())
	end
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = false
	vim.wo[win].breakindent = false
	vim.wo[win].cursorline = true
	vim.wo[win].scrolloff = 0
	vim.wo[win].winhighlight = table.concat({
		"NormalFloat:NvimReviewComposerBody",
		"FloatBorder:NvimReviewComposerBorder",
		"FloatTitle:NvimReviewComposerTitle",
		"FloatFooter:NvimReviewComposerMuted",
	}, ",")

	local function close_editor()
		if finished then
			return false
		end
		finished = true
		clear_autocmds()
		clear_reservation()
		active = nil
		if valid_win(footer_win) then
			vim.api.nvim_win_close(footer_win, true)
		end
		if valid_win(win) then
			vim.api.nvim_win_close(win, true)
		end
		return true
	end

	local function body_value()
		if not valid_buf(buf) then
			return nil
		end
		local body = trim_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		return body ~= "" and body or nil
	end

	local function finish(body)
		if close_editor() then
			callback(body)
		end
	end

	local function submit(interrupted)
		local body = body_value()
		if not body then
			vim.notify("Review comment cannot be empty", vim.log.levels.WARN, { title = "Review" })
			return false
		end
		local accepted = callback(body, interrupted == true, selected_type)
		if accepted == false and interrupted and type(options.recover) == "function" then
			accepted = options.recover(body, selected_type)
		end
		if accepted ~= false then
			close_editor()
			return true
		end
		return false
	end

	local function interrupt()
		if finished then
			return
		end
		local body = body_value()
		close_editor()
		local called, accepted = pcall(callback, body, true, selected_type)
		if (not called or accepted == false) and body and type(options.recover) == "function" then
			options.recover(body, selected_type)
		end
	end

	active = {
		buf = buf,
		win = win,
		footer_win = footer_win,
		layout = layout,
		style = style,
		source_buf = source_buf,
		source_win = source_win,
		reservation = function()
			return reservation
		end,
		persist = function()
			return submit(true)
		end,
		prepare_close = function()
			if not body_value() then
				finish(nil)
				return true
			end
			return submit(true)
		end,
		interrupt = interrupt,
	}

	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = update_geometry,
	})
	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		callback = update_geometry,
	})
	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		callback = interrupt,
	})
	if footer_win then
		autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(footer_win),
			callback = interrupt,
		})
	end
	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(source_win),
		callback = interrupt,
	})
	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = source_buf,
		callback = interrupt,
	})
	autocmds[#autocmds + 1] = vim.api.nvim_create_autocmd("BufWinLeave", {
		buffer = source_buf,
		callback = function()
			vim.schedule(function()
				if not finished and not source_available(source_win, source_buf) then
					interrupt()
				end
			end)
		end,
	})

	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		submit(false)
	end, { buffer = buf, silent = true, desc = "Save review text" })
	vim.keymap.set("n", "<CR><CR>", function()
		submit(false)
	end, { buffer = buf, silent = true, desc = "Save review text" })
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			finish(nil)
		end, { buffer = buf, silent = true, desc = "Cancel review text" })
	end
	if has_type_cycle(options) then
		for lhs, direction in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
			local delta = direction
			vim.keymap.set({ "n", "i" }, lhs, function()
				selected_type = comment_types.cycle(selected_type, delta)
				update_geometry()
				vim.schedule(function()
					if not finished and valid_win(win) and vim.api.nvim_get_current_win() == win then
						vim.cmd("startinsert")
					end
				end)
			end, {
				buffer = buf,
				silent = true,
				desc = delta > 0 and "Next review comment type" or "Previous review comment type",
			})
		end
	end

	vim.cmd("startinsert")
	return true
end

---Persist the active composer before Neovim tears down its windows.
---@return boolean
function M.persist_active()
	return not M.has_active() or active.persist()
end

---Prepare the active composer for synchronous owner-controlled UI teardown.
---An empty draft is cancellation; a non-empty draft must be accepted or
---verified by the caller-provided recovery callback before teardown may proceed.
---@return boolean
function M.prepare_close()
	return not M.has_active() or active.prepare_close()
end

---Whether a review composer still contains unsent text.
---@return boolean
function M.has_active()
	if not active then
		return false
	end
	if
		not valid_buf(active.buf)
		or not valid_win(active.win)
		or (active.layout == "inline" and active.style == "minimal" and not valid_win(active.footer_win))
		or not source_available(active.source_win, active.source_buf)
	then
		active.interrupt()
		return false
	end
	return true
end

M._trim_body = trim_body
M._namespace = NAMESPACE
M._footer_namespace = FOOTER_NAMESPACE

return M
