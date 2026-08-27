-- Small multiline editor used for review comments and replies.
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim_config_review_editor")
local MAX_HEIGHT = 6
local MAX_WIDTH = 88
local active

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function source_available(win, buf)
	return valid_win(win) and valid_buf(buf) and vim.api.nvim_win_get_buf(win) == buf
end

local function source_width(win)
	local info = vim.fn.getwininfo(win)[1] or {}
	local textoff = tonumber(info.textoff) or 0
	return math.max(1, math.min(MAX_WIDTH, vim.api.nvim_win_get_width(win) - textoff))
end

local function anchor_line(options, source_win)
	local anchor = options.anchor_range or options.anchor
	local line = tonumber(options.anchor_line)
	if not line and type(anchor) == "table" then
		line = tonumber(anchor.last or anchor.end_line or anchor[2] or anchor.first or anchor.start_line or anchor[1])
	end
	local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(source_win))
	if not line or line ~= math.floor(line) or line < 1 or line > count then
		return nil
	end
	return line
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

local function screen_rows(buf, width)
	local rows = 0
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width)))
		if rows >= MAX_HEIGHT then
			return MAX_HEIGHT
		end
	end
	return math.max(1, rows)
end

local function editor_hint(options, selected_type)
	local title = options.title or "Review comment"
	if selected_type then
		title = title .. " " .. selected_type
	end
	local type_hint = type(options.type_cycle) == "table" and #options.type_cycle > 0 and "  ·  <Tab> type" or ""
	return (" %s%s  ·  <C-s> save "):format(title, type_hint)
end

local function blank_virtual_lines(count)
	local lines = {}
	for _ = 1, count do
		lines[#lines + 1] = { { "", "NormalFloat" } }
	end
	return lines
end

---Open a focused Markdown scratch buffer anchored below reviewed source.
---@param options? { title?: string, body?: string, recover?: fun(body: string, selected_type?: string): boolean, type_cycle?: string[], selected_type?: string, source_win?: integer, source_window?: integer, anchor_line?: integer, anchor_range?: { first?: integer, last?: integer, start_line?: integer, end_line?: integer, [1]?: integer, [2]?: integer }, anchor?: table }
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
	local source_line = anchor_line(options, source_win)
	if not source_line then
		vim.notify("Review editor anchor is no longer available", vim.log.levels.ERROR, { title = "Review" })
		return false
	end
	local source_row = source_line - 1

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
	local finished = false
	local autocmds = {}
	local win
	local reservation
	local hint_mark

	local function clear_autocmds()
		for _, id in ipairs(autocmds) do
			pcall(vim.api.nvim_del_autocmd, id)
		end
		autocmds = {}
	end

	local function clear_reservation()
		if valid_buf(source_buf) then
			pcall(vim.api.nvim_buf_clear_namespace, source_buf, NAMESPACE, 0, -1)
		end
		reservation = nil
	end

	local function update_geometry()
		if finished or not valid_buf(buf) or not source_available(source_win, source_buf) then
			return
		end
		local width = source_width(source_win)
		local height = screen_rows(buf, width)
		clear_reservation()
		reservation = vim.api.nvim_buf_set_extmark(source_buf, NAMESPACE, source_row, 0, {
			virt_lines = blank_virtual_lines(height),
		})
		if valid_win(win) then
			vim.api.nvim_win_set_config(win, {
				relative = "win",
				win = source_win,
				bufpos = { source_row, 0 },
				row = 1,
				col = 0,
				width = width,
				height = height,
			})
		end
	end

	local initial_width = source_width(source_win)
	local initial_height = screen_rows(buf, initial_width)
	reservation = vim.api.nvim_buf_set_extmark(source_buf, NAMESPACE, source_row, 0, {
		virt_lines = blank_virtual_lines(initial_height),
	})
	win = vim.api.nvim_open_win(buf, true, {
		relative = "win",
		win = source_win,
		bufpos = { source_row, 0 },
		row = 1,
		col = 0,
		width = initial_width,
		height = initial_height,
		style = "minimal",
		border = "none",
		zindex = 60,
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = false
	vim.wo[win].breakindent = false
	vim.wo[win].cursorline = true
	vim.wo[win].scrolloff = 0
	local function update_hint()
		if hint_mark then
			pcall(vim.api.nvim_buf_del_extmark, buf, NAMESPACE, hint_mark)
		end
		hint_mark = vim.api.nvim_buf_set_extmark(buf, NAMESPACE, 0, 0, {
			virt_text = { { editor_hint(options, selected_type), "Comment" } },
			virt_text_pos = "right_align",
			priority = 90,
		})
	end
	update_hint()

	local function close_editor()
		if finished then
			return false
		end
		finished = true
		clear_autocmds()
		clear_reservation()
		active = nil
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
		source_buf = source_buf,
		source_win = source_win,
		reservation = function()
			return reservation
		end,
		persist = function()
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
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			finish(nil)
		end, { buffer = buf, silent = true, desc = "Cancel review text" })
	end
	if type(options.type_cycle) == "table" and #options.type_cycle > 0 then
		vim.keymap.set("n", "<Tab>", function()
			local index = vim.fn.index(options.type_cycle, selected_type)
			selected_type = options.type_cycle[(index + 1) % #options.type_cycle + 1]
			update_hint()
		end, { buffer = buf, silent = true, desc = "Cycle review comment type" })
	end

	vim.cmd("startinsert")
	return true
end

---Persist the active composer before Neovim tears down its windows.
---@return boolean
function M.persist_active()
	return not M.has_active() or active.persist()
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
		or not source_available(active.source_win, active.source_buf)
	then
		active.interrupt()
		return false
	end
	return true
end

M._trim_body = trim_body
M._namespace = NAMESPACE

return M
