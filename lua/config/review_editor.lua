-- Small multiline editor used for review comments and replies.
local M = {}

local active

local function dimensions()
	local width = math.max(40, math.min(88, vim.o.columns - 8))
	local height = math.max(8, math.min(18, vim.o.lines - 8))
	return width, height
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
---@param options? { title?: string, body?: string, recover?: fun(body: string, selected_type?: string): boolean, type_cycle?: string[], selected_type?: string }
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
		row = math.floor((vim.o.lines - height) / 2) - 1,
		col = math.floor((vim.o.columns - width) / 2),
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
	local function close_editor()
		if finished then
			return false
		end
		finished = true
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

return M
