local M = {}

local MAX_ENTRIES = 200

local state = {
	entries = {},
	index = 0,
}

local function normalized_path(path)
	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

local function same_document(left, right)
	return left and right and left.path == right.path
end

local function same_location(left, right)
	return same_document(left, right) and left.lnum == right.lnum and left.col == right.col
end

local function trim_forward()
	for index = #state.entries, state.index + 1, -1 do
		table.remove(state.entries, index)
	end
end

local function append(entry)
	state.entries[#state.entries + 1] = entry
	state.index = #state.entries
	while #state.entries > MAX_ENTRIES do
		table.remove(state.entries, 1)
		state.index = state.index - 1
	end
end

local function window_has_path(win, path)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local config = vim.api.nvim_win_get_config(win)
	if config.relative and config.relative ~= "" then
		return false
	end
	local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
	return name ~= "" and normalized_path(name) == path
end

local function window_for_path(path, preferred_tab, preferred_win)
	if window_has_path(preferred_win, path) then
		return vim.api.nvim_win_get_tabpage(preferred_win), preferred_win
	end
	local function find_in_tab(tabpage)
		if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
			return nil
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
			if window_has_path(win, path) then
				return win
			end
		end
		return nil
	end

	local preferred = find_in_tab(preferred_tab)
	if preferred then
		return preferred_tab, preferred
	end
	for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
		if tabpage ~= preferred_tab then
			local win = find_in_tab(tabpage)
			if win then
				return tabpage, win
			end
		end
	end
	return nil, nil
end

local function set_cursor(win, lnum, col)
	local buf = vim.api.nvim_win_get_buf(win)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(lnum, line_count))
	local line = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)[1] or ""
	local target_col = math.max(0, math.min(col - 1, #line))
	vim.api.nvim_win_set_cursor(win, { target_line, target_col })
end

local function restore(entry)
	local tabpage, win = window_for_path(entry.path, entry.tabpage, entry.winid)
	if win then
		vim.api.nvim_set_current_tabpage(tabpage)
		vim.api.nvim_set_current_win(win)
		set_cursor(win, entry.lnum, entry.col)
		return true
	end

	local buffer_available = entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr)
	if not buffer_available and vim.fn.filereadable(entry.path) ~= 1 then
		return false
	end

	local ok = pcall(require("config.editor").open_file_in_tab, entry.path, {
		lnum = entry.lnum,
		col = entry.col,
		record_history = false,
	})
	return ok
end

local function prepare_traversal()
	local current = M.capture()
	if not current or state.index == 0 then
		return
	end
	if same_document(state.entries[state.index], current) then
		state.entries[state.index] = current
		return
	end
	trim_forward()
	append(current)
end

local function native_fallback(direction)
	if direction < 0 then
		vim.cmd([[execute "normal! \<C-o>"]])
	else
		vim.cmd([[execute "normal! \<C-i>"]])
	end
end

local function traverse(direction, opts)
	opts = opts or {}
	if #state.entries == 0 then
		if opts.fallback ~= false then
			native_fallback(direction)
		end
		return false
	end
	prepare_traversal()
	local candidate = state.index + direction
	while candidate >= 1 and candidate <= #state.entries do
		if restore(state.entries[candidate]) then
			state.index = candidate
			return true
		end
		candidate = candidate + direction
	end
	return false
end

---Capture the current file-backed editor location.
---@return table?
function M.capture()
	local win = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)
	if vim.bo[buf].buftype ~= "" then
		return nil
	end
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	return {
		path = normalized_path(path),
		bufnr = buf,
		winid = win,
		tabpage = vim.api.nvim_get_current_tabpage(),
		lnum = cursor[1],
		col = cursor[2] + 1,
	}
end

---Record a completed semantic navigation without tracking picker or UI buffers.
---@param origin table?
---@param destination table?
---@return boolean
function M.record_transition(origin, destination)
	if not origin or not destination or same_location(origin, destination) then
		return false
	end
	trim_forward()
	if state.index > 0 and same_document(state.entries[state.index], origin) then
		state.entries[state.index] = origin
	else
		append(origin)
	end
	if same_location(state.entries[state.index], destination) then
		state.entries[state.index] = destination
	else
		append(destination)
	end
	return true
end

---@param opts? { fallback?: boolean }
---@return boolean
function M.back(opts)
	return traverse(-1, opts)
end

---@param opts? { fallback?: boolean }
---@return boolean
function M.forward(opts)
	return traverse(1, opts)
end

---Open a picker over the semantic history and restore the selected location.
function M.select()
	prepare_traversal()
	if #state.entries == 0 then
		vim.notify("Navigation history is empty", vim.log.levels.INFO, { title = "Navigation" })
		return
	end
	local choices = {}
	for index = #state.entries, 1, -1 do
		local entry = state.entries[index]
		choices[#choices + 1] = {
			index = index,
			entry = entry,
			label = string.format(
				"%s%s:%d:%d",
				index == state.index and "● " or "  ",
				vim.fn.fnamemodify(entry.path, ":~:."),
				entry.lnum,
				entry.col
			),
		}
	end
	vim.ui.select(choices, {
		prompt = "Navigation history",
		format_item = function(choice)
			return choice.label
		end,
	}, function(choice)
		if choice and restore(choice.entry) then
			state.index = choice.index
		end
	end)
end

---Return a copy suitable for diagnostics and tests.
---@return { entries: table[], index: integer }
function M.snapshot()
	return vim.deepcopy(state)
end

function M.reset()
	state.entries = {}
	state.index = 0
end

function M.setup()
	vim.api.nvim_create_user_command("NavigationBack", function()
		M.back()
	end, { desc = "Go back in semantic navigation history", force = true })
	vim.api.nvim_create_user_command("NavigationForward", function()
		M.forward()
	end, { desc = "Go forward in semantic navigation history", force = true })
	vim.api.nvim_create_user_command("NavigationHistory", M.select, {
		desc = "Show semantic navigation history",
		force = true,
	})
	vim.keymap.set("n", "<C-o>", M.back, { silent = true, desc = "Navigation back" })
	vim.keymap.set("n", "<C-i>", M.forward, { silent = true, desc = "Navigation forward" })
end

return M
