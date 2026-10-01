-- Source-coordinate relations are decorations, never synthetic source rows.
local M = {}
local GROUPS = { old = "NvimReviewRelationOld", new = "NvimReviewRelationNew" }
local UPDATE = "NvimReviewIdentifierUpdate"

function M.highlights()
	for side, group in pairs(GROUPS) do
		local theme =
			vim.api.nvim_get_hl(0, { name = side == "old" and "DiagnosticInfo" or "DiagnosticHint", link = false })
		vim.api.nvim_set_hl(0, group, { fg = theme.fg, underline = true, default = false })
	end
	vim.api.nvim_set_hl(0, UPDATE, { underline = true })
end

local function coordinates(range)
	return ("%d:%d–%d:%d"):format(range.start_line, range.start_col + 1, range.end_line, math.max(1, range.end_col))
end

function M.decorate(relations, item, side, projection)
	local sources = projection and { "old", "new" } or { side }
	for index, relation in ipairs(relations) do
		local prefix = relation.kind == "move" and "M" or "U"
		for _, source in ipairs(sources) do
			local range = relation[source]
			local counterpart = source == "old" and "new" or "old"
			local group = relation.kind == "move" and GROUPS[source] or UPDATE
			for line = range.start_line, range.end_line do
				local row = projection and projection.by_source[source][line] or not projection and line
				if row and (line < range.end_line or range.end_col > 0) then
					local text = vim.api.nvim_buf_get_lines(item.buf, row - 1, row, false)[1] or ""
					local first = line == range.start_line and range.start_col or 0
					-- Frozen CRLF ranges may include the CR hidden by the buffer.
					local last = math.min(line == range.end_line and range.end_col or #text, #text)
					if last > first then
						vim.api.nvim_buf_set_extmark(item.buf, item.namespace, row - 1, first, {
							end_col = last,
							hl_group = group,
							priority = 120,
						})
					end
				end
			end
			local row = projection and projection.by_source[source][range.start_line]
				or not projection and range.start_line
			if row then
				local label = (" %s%d %s → %s %s "):format(
					prefix,
					index,
					relation.kind == "move" and "move" or "identifier",
					counterpart:upper(),
					coordinates(relation[counterpart])
				)
				vim.api.nvim_buf_set_extmark(item.buf, item.namespace, row - 1, 0, {
					virt_text = { { label, GROUPS[source] } },
					virt_text_pos = "eol",
					priority = 160,
				})
			end
		end
	end
end

return M
