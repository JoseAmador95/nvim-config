local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Multicursor" })
end

local function require_or_notify(module, label)
	local ok, value = pcall(require, module)
	if ok then
		return value
	end
	notify(label .. " not available", vim.log.levels.WARN)
	return nil
end

local function add_cursor_at_match(multicursor, match, state, select_range)
	if not match or not match.pos then
		return
	end

	local line = match.pos[1]
	local col = match.pos[2] + 1
	local end_line = line
	local end_col = col
	if match.end_pos then
		end_line = match.end_pos[1]
		end_col = match.end_pos[2] + 1
	end

	multicursor.action(function(ctx)
		local main = ctx:mainCursor()
		local cursor = ctx:addCursor()
		cursor:setPos({ line, col })
		if select_range and match.end_pos then
			cursor:setVisual({ line, col }, { end_line, end_col })
		end
		main:select()
	end)

	if state and type(state.restore) == "function" then
		state:restore()
	end
end

local function flash_jump(select_range)
	local multicursor = require_or_notify("multicursor-nvim", "multicursor.nvim")
	local flash = require_or_notify("flash", "flash.nvim")
	if not multicursor or not flash then
		return
	end
	if type(multicursor.action) ~= "function" then
		notify("multicursor.nvim action API not available", vim.log.levels.WARN)
		return
	end
	if type(flash.jump) ~= "function" then
		notify("flash.nvim jump API not available", vim.log.levels.WARN)
		return
	end

	local options = {
		search = { multi_window = false },
		action = function(match, state)
			add_cursor_at_match(multicursor, match, state, select_range)
		end,
	}
	if select_range then
		options.pattern = [[\<\k\+\>]]
		options.search.mode = "search"
		options.jump = { pos = "range" }
	end
	flash.jump(options)
end

function M.flash_cursor()
	flash_jump(false)
end

function M.flash_word_selection()
	flash_jump(true)
end

return M
