local redraw_profile = require("config.redraw_profile")

local M = {}

local CURRENT_LINE = "current-line"
local SETTLED_LINE = "settled-line"
local OFF = "off"
local MODES = { [CURRENT_LINE] = true, [SETTLED_LINE] = true, [OFF] = true }
local GROUP = "NvimConfigInlineDiagnostics"

local states = {}
local dirty = {}
local refresh_pending = false
local generation = 0
local configured = false
local preferred_mode
local current_mode
local last_enabled_mode = CURRENT_LINE

local function handler()
	local value = vim.diagnostic.handlers.virtual_lines
	return type(value) == "table" and value or nil
end

local function state(buf)
	local value = states[buf]
	if not value then
		value = {
			cursor_row = nil,
			diagnostic_generation = 0,
			render_generation = -1,
			settled_row = nil,
			shown_namespaces = {},
		}
		states[buf] = value
	end
	return value
end

local function current_row(buf)
	if vim.api.nvim_get_current_buf() ~= buf then
		return nil
	end
	return vim.api.nvim_win_get_cursor(0)[1] - 1
end

local function clear_rendered(buf, value)
	local virtual_lines = handler()
	if virtual_lines and type(virtual_lines.hide) == "function" then
		for namespace in pairs(value.shown_namespaces) do
			pcall(virtual_lines.hide, namespace, buf)
		end
	end
	value.shown_namespaces = {}
	value.render_generation = -1
end

local function diagnostics_by_namespace(buf, row)
	local ok, diagnostics = pcall(vim.diagnostic.get, buf, { lnum = row })
	if not ok or type(diagnostics) ~= "table" then
		return nil
	end
	local grouped = {}
	for _, diagnostic in ipairs(diagnostics) do
		local namespace = diagnostic.namespace
		if type(namespace) == "number" then
			grouped[namespace] = grouped[namespace] or {}
			grouped[namespace][#grouped[namespace] + 1] = diagnostic
		end
	end
	return grouped
end

local function render_settled(buf, row)
	local value = state(buf)
	clear_rendered(buf, value)
	local virtual_lines = handler()
	local complete = virtual_lines and type(virtual_lines.show) == "function"
	if virtual_lines and type(virtual_lines.show) == "function" then
		local grouped = diagnostics_by_namespace(buf, row)
		if not grouped then
			value.cursor_row = row
			value.settled_row = row
			return false
		end
		local namespaces = vim.tbl_keys(grouped)
		table.sort(namespaces)
		for _, namespace in ipairs(namespaces) do
			local diagnostics = grouped[namespace]
			table.sort(diagnostics, function(left, right)
				if left.severity ~= right.severity then
					return (left.severity or vim.diagnostic.severity.ERROR)
						< (right.severity or vim.diagnostic.severity.ERROR)
				end
				return (left.col or 0) < (right.col or 0)
			end)
			local ok = pcall(virtual_lines.show, namespace, buf, diagnostics, {
				severity_sort = true,
				virtual_lines = { current_line = false },
			})
			if ok then
				value.shown_namespaces[namespace] = true
			else
				complete = false
			end
		end
	end
	value.cursor_row = row
	value.settled_row = row
	value.render_generation = complete and value.diagnostic_generation or -1
	return complete
end

local function flush_diagnostic_changes(ticket)
	if ticket ~= generation then
		return
	end
	refresh_pending = false
	local pending = dirty
	dirty = {}
	for buf in pairs(pending) do
		local value = states[buf]
		if value and vim.api.nvim_buf_is_valid(buf) then
			local row = current_row(buf)
			if value.settled_row ~= nil and row == value.settled_row then
				render_settled(buf, row)
			elseif value.settled_row ~= nil then
				clear_rendered(buf, value)
				value.settled_row = nil
			end
		end
	end
end

local function queue_diagnostic_change(buf)
	dirty[buf] = true
	if refresh_pending then
		return
	end
	refresh_pending = true
	local ticket = generation
	vim.schedule(function()
		flush_diagnostic_changes(ticket)
	end)
end

local function on_hold(event)
	if current_mode ~= SETTLED_LINE or not vim.api.nvim_buf_is_valid(event.buf) then
		return
	end
	local row = current_row(event.buf)
	if row == nil then
		return
	end
	local value = state(event.buf)
	if value.settled_row == row and value.render_generation == value.diagnostic_generation then
		return
	end
	render_settled(event.buf, row)
end

local function on_move(event)
	if current_mode ~= SETTLED_LINE or not vim.api.nvim_buf_is_valid(event.buf) then
		return
	end
	local row = current_row(event.buf)
	if row == nil then
		return
	end
	local value = state(event.buf)
	if value.cursor_row == nil then
		value.cursor_row = row
		return
	end
	if value.cursor_row == row then
		-- CursorMoved also fires for a column-only move. Keeping the rendered
		-- row intact avoids a full virtual-line erase/repaint over slow links.
		return
	end
	value.cursor_row = row
	value.settled_row = nil
	clear_rendered(event.buf, value)
end

local function on_diagnostic_changed(event)
	if current_mode ~= SETTLED_LINE then
		return
	end
	local value = states[event.buf]
	if not value then
		return
	end
	value.diagnostic_generation = value.diagnostic_generation + 1
	if value.settled_row ~= nil then
		queue_diagnostic_change(event.buf)
	end
end

local function on_leave(event)
	if current_mode ~= SETTLED_LINE then
		return
	end
	local value = states[event.buf]
	if value then
		clear_rendered(event.buf, value)
		value.settled_row = nil
	end
end

local function clear_all()
	for buf, value in pairs(states) do
		if vim.api.nvim_buf_is_valid(buf) then
			clear_rendered(buf, value)
		end
	end
	states = {}
	dirty = {}
	refresh_pending = false
end

local function apply(mode)
	clear_all()
	current_mode = mode
	if mode ~= OFF then
		last_enabled_mode = mode
	end
	vim.diagnostic.config({
		virtual_lines = mode == CURRENT_LINE and { current_line = true } or false,
	})
end

function M.setup()
	generation = generation + 1
	clear_all()
	configured = true
	preferred_mode = redraw_profile.inline_diagnostics()
	last_enabled_mode = preferred_mode ~= OFF and preferred_mode or CURRENT_LINE
	current_mode = preferred_mode
	local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
	vim.api.nvim_create_autocmd("CursorHold", { group = group, callback = on_hold })
	vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, {
		group = group,
		callback = on_move,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "TabLeave", "InsertEnter" }, {
		group = group,
		callback = on_leave,
	})
	vim.api.nvim_create_autocmd("DiagnosticChanged", { group = group, callback = on_diagnostic_changed })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			local value = states[event.buf]
			if value then
				clear_rendered(event.buf, value)
			end
			states[event.buf] = nil
			dirty[event.buf] = nil
		end,
	})
	apply(current_mode)
	return M
end

function M.set(mode)
	if not MODES[mode] then
		return nil, "inline diagnostic mode must be current-line, settled-line, or off"
	end
	if not configured then
		return nil, "inline diagnostics are not configured"
	end
	if current_mode ~= mode then
		generation = generation + 1
		apply(mode)
	end
	return mode
end

function M.toggle()
	local mode = current_mode == OFF and last_enabled_mode or OFF
	return M.set(mode)
end

function M.status()
	return {
		configured = configured,
		generation = generation,
		mode = current_mode,
		preferred = preferred_mode,
		pending = refresh_pending,
	}
end

function M.teardown()
	generation = generation + 1
	clear_all()
	configured = false
	preferred_mode = nil
	current_mode = nil
	pcall(vim.api.nvim_del_augroup_by_name, GROUP)
	vim.diagnostic.config({ virtual_lines = false })
	return true
end

return M
