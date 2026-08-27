-- Small multiline editor used for review comments and replies.
local M = {}

local active

local function dimensions()
	local available_width = math.max(1, vim.o.columns - 4)
	local available_height = math.max(1, vim.o.lines - 4)
	local width = math.min(88, available_width)
	local height = math.min(18, available_height)
	return width, height
end

local function anchor_lines(options)
	local anchor = options.anchor_range or options.anchor
	if type(anchor) ~= "table" then
		return nil
	end
	local first = tonumber(anchor.first or anchor.start_line or anchor.start or anchor[1])
	local last = tonumber(anchor.last or anchor.end_line or anchor[2] or first)
	if not first or not last then
		return nil
	end
	first = math.max(1, math.floor(first))
	last = math.max(first, math.floor(last))
	return first, last
end

local function visible_anchor(options)
	local source_win = options.source_win or options.source_window
	local first, last = anchor_lines(options)
	if not first or not vim.api.nvim_win_is_valid(source_win or -1) then
		return nil
	end
	local first_pos = vim.fn.screenpos(source_win, first, 1)
	local last_pos = vim.fn.screenpos(source_win, last, 1)
	if not first_pos or not last_pos or first_pos.row < 1 or last_pos.row < 1 then
		return nil
	end
	local win_position = vim.fn.win_screenpos(source_win)
	return {
		top = math.min(first_pos.row, last_pos.row) - 1,
		bottom = math.max(first_pos.row, last_pos.row) - 1,
		left = win_position[2] - 1,
		right = win_position[2] - 2 + vim.api.nvim_win_get_width(source_win),
	}
end

local function intersects(candidate, anchor)
	return candidate.row <= anchor.bottom
		and candidate.row + candidate.height - 1 >= anchor.top
		and candidate.col <= anchor.right
		and candidate.col + candidate.width - 1 >= anchor.left
end

local function fits(candidate)
	return candidate.row >= 0
		and candidate.col >= 0
		and candidate.row + candidate.height <= math.max(1, vim.o.lines - 1)
		and candidate.col + candidate.width <= vim.o.columns
end

local function placement(options, width, height)
	local total_width = width + 2
	local total_height = height + 2
	local anchor = visible_anchor(options)
	if anchor then
		local centered_col = math.floor((vim.o.columns - total_width) / 2)
		local centered_row = math.floor((math.max(1, vim.o.lines - 1) - total_height) / 2)
		local candidates = {
			{ row = anchor.top - total_height, col = centered_col },
			{ row = anchor.bottom + 1, col = centered_col },
			{ row = centered_row, col = anchor.right + 1 },
			{ row = centered_row, col = anchor.left - total_width },
		}
		for _, candidate in ipairs(candidates) do
			candidate.width = total_width
			candidate.height = total_height
			if fits(candidate) and not intersects(candidate, anchor) then
				return candidate.row + 1, candidate.col + 1
			end
		end
	end
	return math.max(0, math.floor((vim.o.lines - height) / 2) - 1), math.max(0, math.floor((vim.o.columns - width) / 2))
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

---Open a focused Markdown scratch buffer and return its submitted body.
---@param options? { title?: string, body?: string, recover?: fun(body: string, selected_type?: string): boolean, type_cycle?: string[], selected_type?: string, source_win?: integer, source_window?: integer, anchor_range?: { first?: integer, last?: integer, start_line?: integer, end_line?: integer, [1]?: integer, [2]?: integer }, anchor?: table }
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
	local width, height = dimensions()
	local row, col = placement(options, width, height)
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
	local function editor_title()
		local title = options.title or "Review comment"
		if selected_type then
			title = title .. " " .. selected_type
		end
		local type_hint = type(options.type_cycle) == "table" and #options.type_cycle > 0 and "  ·  <Tab> type" or ""
		return " " .. title .. type_hint .. "  ·  <C-s> save "
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = editor_title(),
		title_pos = "center",
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].cursorline = true

	local finished = false
	active = { buf = buf, win = win }
	active.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
		callback = function()
			if not vim.api.nvim_win_is_valid(win) then
				return
			end
			local resized_width, resized_height = dimensions()
			local resized_row, resized_col = placement(options, resized_width, resized_height)
			vim.api.nvim_win_set_config(win, {
				relative = "editor",
				row = resized_row,
				col = resized_col,
				width = resized_width,
				height = resized_height,
			})
		end,
	})
	local function close_editor()
		if finished then
			return false
		end
		finished = true
		if active and active.resize_autocmd then
			pcall(vim.api.nvim_del_autocmd, active.resize_autocmd)
		end
		active = nil
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		return true
	end
	local function finish(body)
		if close_editor() then
			callback(body)
		end
	end
	local function submit(interrupted)
		local body = trim_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		if body == "" then
			vim.notify("Review comment cannot be empty", vim.log.levels.WARN, { title = "Review" })
			return
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
	active.persist = function()
		return submit(true)
	end

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
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_set_config(win, { title = editor_title() })
			end
		end, { buffer = buf, silent = true, desc = "Cycle review comment type" })
	end
	vim.api.nvim_create_autocmd("WinClosed", {
		once = true,
		pattern = tostring(win),
		callback = function()
			if not finished then
				local body
				if vim.api.nvim_buf_is_valid(buf) then
					body = trim_body(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
					if body == "" then
						body = nil
					end
				end
				finished = true
				if active and active.resize_autocmd then
					pcall(vim.api.nvim_del_autocmd, active.resize_autocmd)
				end
				active = nil
				local called, accepted = pcall(callback, body, true, selected_type)
				if (not called or accepted == false) and body and type(options.recover) == "function" then
					options.recover(body, selected_type)
				end
			end
		end,
	})
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
	if not vim.api.nvim_buf_is_valid(active.buf) or not vim.api.nvim_win_is_valid(active.win) then
		active = nil
		return false
	end
	return true
end

M._trim_body = trim_body
M._placement = placement

return M
