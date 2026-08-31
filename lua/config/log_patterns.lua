-- Host UI for log-workbench.nvim matches. Colors, visual selection parsing,
-- commands, and notifications remain configuration policy.
local matches = require("log_workbench.matches")

local M = {}

local colors = {
	{ name = "red", dark = { bg = "#3b1f1f", ctermbg = 52 }, light = { bg = "#f5c6c6", ctermbg = 217 } },
	{ name = "orange", dark = { bg = "#3b2a1a", ctermbg = 94 }, light = { bg = "#f6d9b8", ctermbg = 223 } },
	{ name = "yellow", dark = { bg = "#3a341b", ctermbg = 100 }, light = { bg = "#f0e9a8", ctermbg = 229 } },
	{ name = "green", dark = { bg = "#243228", ctermbg = 22 }, light = { bg = "#c6e6c6", ctermbg = 194 } },
	{ name = "cyan", dark = { bg = "#1c2f33", ctermbg = 23 }, light = { bg = "#bfe3e8", ctermbg = 195 } },
	{ name = "blue", dark = { bg = "#1f2a3b", ctermbg = 17 }, light = { bg = "#c6d4f0", ctermbg = 189 } },
	{ name = "purple", dark = { bg = "#2d2137", ctermbg = 53 }, light = { bg = "#ddc9ee", ctermbg = 183 } },
	{ name = "gray", dark = { bg = "#2b2f35", ctermbg = 236 }, light = { bg = "#d9dde2", ctermbg = 253 } },
}

local color_index = {}
for index, entry in ipairs(colors) do
	color_index[entry.name] = index
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LogHighlight" })
end

local function apply_highlights()
	local variant = vim.o.background == "light" and "light" or "dark"
	for index, entry in ipairs(colors) do
		local shade = entry[variant]
		vim.api.nvim_set_hl(0, "LogHl" .. index, { bg = shade.bg, ctermbg = shade.ctermbg })
	end
end

local function split_cmdline(cmdline)
	local raw_args = cmdline:gsub("^%s*%S+%s*", "")
	local parts = {}
	for part in raw_args:gmatch("%S+") do
		parts[#parts + 1] = part
	end
	return parts, raw_args:match("%s$") ~= nil
end

local function complete_color(arglead, cmdline)
	local parts, trailing = split_cmdline(cmdline)
	if #parts > 1 or (#parts == 1 and trailing) then
		return {}
	end
	local items = {}
	for index, entry in ipairs(colors) do
		items[#items + 1] = entry.name
		items[#items + 1] = tostring(index)
	end
	if arglead == "" then
		return items
	end
	return vim.tbl_filter(function(item)
		return vim.startswith(item, arglead)
	end, items)
end

local function parse_color(input)
	local key = vim.trim((input or ""):lower())
	if key == "" then
		return nil, "Color is required"
	end
	local index = tonumber(key)
	if index and colors[index] then
		return colors[index].name, index
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
	local start_row, start_col = start_pos[2], start_pos[3]
	local end_row, end_col = end_pos[2], end_pos[3]
	if start_row > end_row or (start_row == end_row and start_col > end_col) then
		start_row, end_row = end_row, start_row
		start_col, end_col = end_col, start_col
	end
	local lines = vim.api.nvim_buf_get_lines(buf, start_row - 1, end_row, false)
	if #lines == 0 then
		return nil
	end
	lines[1] = lines[1]:sub(start_col)
	lines[#lines] = lines[#lines]:sub(1, end_col)
	return table.concat(lines, "\n")
end

local function legacy_pattern(entry)
	local text = entry.text:gsub("\n", "\\n")
	if entry.kind == "exact" then
		text = "\\V" .. text:gsub("\\", "\\\\")
	end
	return text
end

local function sync_buffer_state(buf)
	local patterns = {}
	local next_id = 1
	for _, entry in ipairs(matches.list(buf)) do
		patterns[#patterns + 1] = {
			id = entry.id,
			group = entry.hl_group,
			color_key = entry.metadata.color_key,
			pattern = legacy_pattern(entry),
			kind = entry.kind,
		}
		if type(entry.id) == "number" then
			next_id = math.max(next_id, entry.id + 1)
		end
	end
	vim.b[buf].log_pattern_state = { patterns = patterns, window_matches = {}, next_id = next_id }
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
	local color_key, color_index_or_err = parse_color(color_arg)
	if not color_key then
		notify(color_index_or_err, vim.log.levels.ERROR)
		return
	end
	local pattern_text = get_visual_selection(buf)
	if (not pattern_text or pattern_text == "") and vim.trim(pattern_arg or "") ~= "" then
		pattern_text = pattern_arg
	end
	if not pattern_text or vim.trim(pattern_text) == "" then
		notify("Pattern is required", vim.log.levels.ERROR)
		return
	end
	local entry, err = matches.add(buf, {
		kind = kind,
		text = pattern_text,
		hl_group = "LogHl" .. color_index_or_err,
		priority = 110,
		metadata = { color_key = color_key },
	})
	if not entry then
		notify("Could not add log pattern: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	sync_buffer_state(buf)
	return entry
end

function M.clear(opts)
	local buf = vim.api.nvim_get_current_buf()
	local arg = vim.trim(opts.args or "")
	if arg == "" then
		matches.clear(buf)
		sync_buffer_state(buf)
		return
	end
	local color_key, color_err = parse_color(arg)
	if not color_key then
		notify(color_err, vim.log.levels.ERROR)
		return
	end
	local ids = {}
	for _, entry in ipairs(matches.list(buf)) do
		if entry.metadata.color_key == color_key then
			ids[#ids + 1] = entry.id
		end
	end
	matches.clear(buf, ids)
	sync_buffer_state(buf)
end

function M.next(buf, opts)
	return matches.next(buf or vim.api.nvim_get_current_buf(), opts)
end

function M.previous(buf, opts)
	return matches.previous(buf or vim.api.nvim_get_current_buf(), opts)
end

function M.setup()
	assert(matches.setup())
	apply_highlights()
	local group = vim.api.nvim_create_augroup("LogHighlightColors", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply_highlights })
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "background",
		callback = apply_highlights,
	})
end

return M
