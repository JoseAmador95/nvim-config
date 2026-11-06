-- Observe the selected source, never the editor's later cursor position.
local source = require("diagram_view.source")
local M = {}
local namespace = vim.api.nvim_create_namespace("DiagramRexSource")

function M.watch(target, diagram, callback)
	local watcher = { active = true, target = vim.deepcopy(target), diagram = vim.deepcopy(diagram) }
	target, diagram = watcher.target, watcher.diagram
	local buf = target.bufnr
	local origin = diagram.origin
	local timer
	local mark

	function watcher:read()
		if target.frozen or not buf or diagram.kind == "image" then
			return vim.deepcopy(self.diagram)
		end
		if not vim.api.nvim_buf_is_loaded(buf) then
			return nil, "Source buffer is no longer available"
		end
		local options = { bufnr = buf, filetype = target.filetype, kind = diagram.kind }
		if mark then
			local position = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, mark, { details = true })
			if #position == 0 then
				return nil, "Source range is no longer available"
			end
			local first, last = position[1] + 1, position[3].end_row + 1
			if first > last or position[3].invalid then
				return nil, "Source diagram was removed"
			end
			if origin.type == "selection" then
				options.selection = { start_row = first, end_row = last }
			else
				options.row = first
				local extracted = source.extract(options)
				if
					not extracted
					or extracted.origin.type ~= "fence"
					or extracted.origin.start_row ~= first
					or extracted.origin.end_row ~= last
				then
					return nil, "Source diagram fence is incomplete or was removed"
				end
				return extracted
			end
		end
		return source.extract(options)
	end

	function watcher:matches(next_target, next_diagram)
		if diagram.kind == "image" or next_diagram.kind == "image" then
			return diagram.kind == next_diagram.kind
				and buf == next_target.bufnr
				and diagram.path == next_diagram.path
				and vim.deep_equal(diagram.origin, next_diagram.origin)
		end
		if target.frozen or next_target.frozen then
			return target.frozen == next_target.frozen
				and self.target.path == next_target.path
				and self.target.side == next_target.side
				and vim.deep_equal(self.target.lines, next_target.lines)
				and vim.deep_equal(self.diagram, next_diagram)
		end
		if buf ~= next_target.bufnr then
			return false
		end
		local current = self:read()
		return current ~= nil and vim.deep_equal(current.origin, next_diagram.origin)
	end

	function watcher:stop()
		self.active = false
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		if mark and vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_del_extmark(buf, namespace, mark)
		end
	end

	if diagram.kind ~= "image" and not target.frozen and buf and vim.api.nvim_buf_is_loaded(buf) then
		if origin.type ~= "buffer" then
			local last_line = vim.api.nvim_buf_get_lines(buf, origin.end_row - 1, origin.end_row, false)[1] or ""
			mark = vim.api.nvim_buf_set_extmark(buf, namespace, origin.start_row - 1, 0, {
				end_row = origin.end_row - 1,
				end_col = #last_line,
				right_gravity = true,
				end_right_gravity = false,
				undo_restore = true,
				invalidate = true,
			})
		end
		timer = assert(vim.uv.new_timer())
		vim.api.nvim_buf_attach(buf, false, {
			on_lines = function()
				if not watcher.active then
					return true
				end
				timer:start(
					200,
					0,
					vim.schedule_wrap(function()
						if watcher.active then
							callback(watcher:read())
						end
					end)
				)
			end,
			on_detach = function()
				if watcher.active then
					watcher:stop()
					vim.schedule(function()
						callback(nil, "Source buffer is no longer available")
					end)
				end
			end,
		})
	end
	return watcher
end

return M
