local M = {}

local function current_target()
	local winid = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(winid)
	return {
		bufnr = vim.api.nvim_get_current_buf(),
		winid = winid,
		tabpage = vim.api.nvim_get_current_tabpage(),
		cursor = { line = cursor[1], col = cursor[2] },
	}
end

local function normalize_target(target)
	return target and vim.deepcopy(target) or current_target()
end

local function valid_buffer(target)
	return type(target.bufnr) == "number" and vim.api.nvim_buf_is_valid(target.bufnr)
end

local function valid_window(target)
	return type(target.winid) == "number"
		and vim.api.nvim_win_is_valid(target.winid)
		and vim.api.nvim_win_get_buf(target.winid) == target.bufnr
end

---Run an editor action against the buffer/window that opened the palette.
---@param target? table
---@param options? { window?: boolean, modifiable?: boolean }
---@param callback fun(target: table): any
---@return boolean, any
function M.with_target(target, options, callback)
	target = normalize_target(target)
	options = options or {}
	if not valid_buffer(target) then
		return false, "Origin buffer is no longer available"
	end
	if options.modifiable and not vim.bo[target.bufnr].modifiable then
		return false, "Origin buffer is not modifiable"
	end
	if options.window and not valid_window(target) then
		return false, "Origin window is no longer available"
	end

	local runner = valid_window(target) and vim.api.nvim_win_call or vim.api.nvim_buf_call
	local handle = valid_window(target) and target.winid or target.bufnr
	local ok, result = pcall(runner, handle, function()
		return callback(target)
	end)
	if not ok then
		return false, result
	end
	return true, result
end

---@param enabled boolean
---@param target? table
---@return boolean?, string?
function M.set_wrap(enabled, target)
	local ok, err = M.with_target(target, { window = true }, function()
		vim.wo.wrap = enabled
		vim.wo.linebreak = enabled
	end)
	if not ok then
		return nil, tostring(err)
	end
	return enabled
end

---@param target? table
---@return boolean?, string?
function M.toggle_wrap(target)
	local enabled
	local ok, err = M.with_target(target, { window = true }, function()
		enabled = not vim.wo.wrap
		vim.wo.wrap = enabled
		vim.wo.linebreak = enabled
	end)
	if not ok then
		return nil, tostring(err)
	end
	return enabled
end

---@param name string
---@param enabled boolean
---@param target? table
---@return boolean?, string?
function M.set_window_option(name, enabled, target)
	local ok, err = M.with_target(target, { window = true }, function()
		vim.api.nvim_set_option_value(name, enabled, { win = 0 })
	end)
	if not ok then
		return nil, tostring(err)
	end
	return enabled
end

---@param name string
---@param target? table
---@return boolean?, string?
function M.toggle_window_option(name, target)
	local enabled
	local ok, err = M.with_target(target, { window = true }, function()
		enabled = not vim.api.nvim_get_option_value(name, { win = 0 })
		vim.api.nvim_set_option_value(name, enabled, { win = 0 })
	end)
	if not ok then
		return nil, tostring(err)
	end
	return enabled
end

---@param target? table
---@return boolean, string?
function M.open_file_under_cursor(target)
	local ok, err = M.with_target(target, { window = true }, function()
		local file = vim.fn.expand("<cfile>")
		local line = 1
		local col = 1
		local parsed_file, parsed_line, parsed_col = file:match("^(.-):(%d+):(%d+)$")
		if parsed_file then
			file, line, col = parsed_file, parsed_line, parsed_col
		else
			parsed_file, parsed_line = file:match("^(.-):(%d+)$")
			if parsed_file then
				file, line = parsed_file, parsed_line
			end
		end
		require("config.editor").open_file_in_tab(file, {
			lnum = tonumber(line) or 1,
			col = tonumber(col) or 1,
		})
	end)
	if not ok then
		return false, tostring(err)
	end
	return true
end

return M
