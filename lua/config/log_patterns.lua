local M = {}

local colors = {
	{ name = "red", bg = "#3b1f1f", ctermbg = 52 },
	{ name = "orange", bg = "#3b2a1a", ctermbg = 94 },
	{ name = "yellow", bg = "#3a341b", ctermbg = 100 },
	{ name = "green", bg = "#243228", ctermbg = 22 },
	{ name = "cyan", bg = "#1c2f33", ctermbg = 23 },
	{ name = "blue", bg = "#1f2a3b", ctermbg = 17 },
	{ name = "purple", bg = "#2d2137", ctermbg = 53 },
	{ name = "gray", bg = "#2b2f35", ctermbg = 236 },
}

local color_index = {}
for i, entry in ipairs(colors) do
	color_index[entry.name] = i
end

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "LogHighlight" })
end

local function apply_highlights()
	for i, entry in ipairs(colors) do
		vim.api.nvim_set_hl(0, "LogHl" .. i, { bg = entry.bg, ctermbg = entry.ctermbg })
	end
end

local function get_state(buf)
	local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "log_pattern_state")
	if ok and type(state) == "table" then
		return state
	end
	state = { patterns = {}, window_matches = {}, next_id = 1 }
	vim.api.nvim_buf_set_var(buf, "log_pattern_state", state)
	return state
end

local function split_cmdline(cmdline)
	local raw_args = cmdline:gsub("^%s*%S+%s*", "")
	local parts = {}
	for part in raw_args:gmatch("%S+") do
		parts[#parts + 1] = part
	end
	return parts, vim.trim(raw_args), raw_args:match("%s$") ~= nil
end

local function complete_color(arglead, cmdline)
	local parts, _, has_trailing_space = split_cmdline(cmdline)
	if #parts > 1 or (#parts == 1 and has_trailing_space) then
		return {}
	end

	local items = {}
	for i, entry in ipairs(colors) do
		items[#items + 1] = entry.name
		items[#items + 1] = tostring(i)
	end

	if arglead == "" then
		return items
	end

	local matches = {}
	for _, item in ipairs(items) do
		if vim.startswith(item, arglead) then
			matches[#matches + 1] = item
		end
	end
	return matches
end

local function parse_color(input)
	local key = vim.trim((input or ""):lower())
	if key == "" then
		return nil, "Color is required"
	end

	local idx = tonumber(key)
	if idx and colors[idx] then
		return colors[idx].name, idx
	end

	if color_index[key] then
		return key, color_index[key]
	end

	return nil, "Unknown color: " .. key
end

local function get_visual_selection(buf)
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	if start_pos[2] == 0 or end_pos[2] == 0 then
		return nil
	end

	local s_row, s_col = start_pos[2], start_pos[3]
	local e_row, e_col = end_pos[2], end_pos[3]
	if s_row > e_row or (s_row == e_row and s_col > e_col) then
		s_row, e_row = e_row, s_row
		s_col, e_col = e_col, s_col
	end

	local lines = vim.api.nvim_buf_get_lines(buf, s_row - 1, e_row, false)
	if #lines == 0 then
		return nil
	end

	lines[1] = string.sub(lines[1], s_col)
	lines[#lines] = string.sub(lines[#lines], 1, e_col)
	return table.concat(lines, "\n")
end

local function normalize_pattern(text)
	return text:gsub("\n", "\\n")
end

local function exact_pattern(text)
	local escaped = text:gsub("\\", "\\\\")
	escaped = normalize_pattern(escaped)
	return "\\V" .. escaped
end

local function add_match_to_window(winid, pattern_entry, state)
	state.window_matches[winid] = state.window_matches[winid] or {}
	if state.window_matches[winid][pattern_entry.id] then
		return
	end
	local match_id = vim.fn.matchadd(pattern_entry.group, pattern_entry.pattern, 10, -1, { window = winid })
	state.window_matches[winid][pattern_entry.id] = match_id
end

local function apply_pattern_to_windows(buf, pattern_entry, state)
	local info = vim.fn.getbufinfo(buf)[1]
	if not info or not info.windows then
		return
	end
	for _, winid in ipairs(info.windows) do
		if vim.api.nvim_win_is_valid(winid) then
			add_match_to_window(winid, pattern_entry, state)
		end
	end
end

local function apply_all_to_window(buf, winid, state)
	if not vim.api.nvim_win_is_valid(winid) then
		return
	end
	for _, entry in ipairs(state.patterns) do
		add_match_to_window(winid, entry, state)
	end
end

local function delete_match(winid, match_id)
	pcall(vim.fn.matchdelete, match_id, winid)
end

local function clear_patterns_by_ids(buf, ids)
	local state = get_state(buf)
	local id_set = {}
	for _, id in ipairs(ids) do
		id_set[id] = true
	end

	for winid, matches in pairs(state.window_matches) do
		if vim.api.nvim_win_is_valid(winid) then
			for pattern_id, match_id in pairs(matches) do
				if id_set[pattern_id] then
					delete_match(winid, match_id)
					matches[pattern_id] = nil
				end
			end
		end
	end

	local remaining = {}
	for _, entry in ipairs(state.patterns) do
		if not id_set[entry.id] then
			remaining[#remaining + 1] = entry
		end
	end
	state.patterns = remaining
	vim.api.nvim_buf_set_var(buf, "log_pattern_state", state)
end

local function build_pattern(kind, text)
	if kind == "exact" then
		return exact_pattern(text)
	end
	return normalize_pattern(text)
end

function M.complete_colors(arglead, cmdline)
	return complete_color(arglead, cmdline)
end

function M.add(kind, opts)
	local buf = vim.api.nvim_get_current_buf()
	local args = vim.trim(opts.args or "")
	if args == "" then
		notify("Color is required", vim.log.levels.ERROR)
		return
	end

	local color_arg, pattern_arg = args:match("^(%S+)%s*(.*)$")
	local color_key, color_idx_or_err = parse_color(color_arg)
	if not color_key then
		notify(color_idx_or_err, vim.log.levels.ERROR)
		return
	end
	local color_idx = color_idx_or_err

	local pattern_text = get_visual_selection(buf)
	if (not pattern_text or pattern_text == "") and vim.trim(pattern_arg or "") ~= "" then
		pattern_text = pattern_arg
	end

	if not pattern_text or vim.trim(pattern_text) == "" then
		notify("Pattern is required", vim.log.levels.ERROR)
		return
	end

	local state = get_state(buf)
	local pattern = build_pattern(kind, pattern_text)
	local entry = {
		id = state.next_id,
		group = "LogHl" .. color_idx,
		color_key = color_key,
		pattern = pattern,
		kind = kind,
	}
	state.next_id = state.next_id + 1
	state.patterns[#state.patterns + 1] = entry
	apply_pattern_to_windows(buf, entry, state)
	vim.api.nvim_buf_set_var(buf, "log_pattern_state", state)
end

function M.clear(opts)
	local buf = vim.api.nvim_get_current_buf()
	local state = get_state(buf)
	local arg = vim.trim(opts.args or "")

	if arg == "" then
		local ids = {}
		for _, entry in ipairs(state.patterns) do
			ids[#ids + 1] = entry.id
		end
		clear_patterns_by_ids(buf, ids)
		return
	end

	local color_key, color_idx_or_err = parse_color(arg)
	if not color_key then
		notify(color_idx_or_err, vim.log.levels.ERROR)
		return
	end

	local ids = {}
	for _, entry in ipairs(state.patterns) do
		if entry.color_key == color_key then
			ids[#ids + 1] = entry.id
		end
	end
	clear_patterns_by_ids(buf, ids)
end

function M.setup()
	apply_highlights()
	local group = vim.api.nvim_create_augroup("LogHighlightColors", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = apply_highlights,
	})
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = function(args)
			local buf = args.buf
		local ok, state = pcall(vim.api.nvim_buf_get_var, buf, "log_pattern_state")
		if not ok or type(state) ~= "table" then
			return
		end
		apply_all_to_window(buf, vim.api.nvim_get_current_win(), state)
		vim.api.nvim_buf_set_var(buf, "log_pattern_state", state)
	end,
	})
end

return M
