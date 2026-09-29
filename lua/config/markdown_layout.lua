-- Center the editor's rendered Markdown page without changing md-render's
-- source-line mapping. The pinned renderer builds content before it knows the
-- display window, so the host supplies the page width and left margin.
local M = {}

local MAX_PAGE_WIDTH = 120
local RENDER_INDENT_WIDTH = 2

function M.measure(win)
	local info = vim.fn.getwininfo(win)[1]
	local textoff = info and info.textoff or 0
	local available = math.max(1, vim.api.nvim_win_get_width(win) - textoff)
	local page_width = math.max(1, math.min(MAX_PAGE_WIDTH, math.floor(available * 0.9)))
	local margin = math.floor((available - page_width) / 2)
	return page_width, margin
end

-- md-render's horizontal rules prepend its two-space base indent to a rule
-- whose own width is max_width. Reserve that indent inside the page budget.
function M.render_width(page_width)
	return math.max(1, page_width - RENDER_INDENT_WIDTH)
end

-- Every field here is a byte column in md-render v3.10.3. ASCII padding makes
-- its byte length equal the screen-cell shift. Row-only maps stay untouched.
function M.center_content(content, opts)
	local margin = opts and opts.nvim_config_page_margin
	if type(margin) ~= "number" or margin <= 0 then
		return content
	end
	margin = math.floor(margin)
	local padding = string.rep(" ", margin)
	for index, line in ipairs(content.lines) do
		content.lines[index] = padding .. line
	end
	for _, entry in ipairs(content.highlights or {}) do
		for _, group in ipairs(entry.groups) do
			group.col = group.col + margin
			if group.end_col >= 0 then
				group.end_col = group.end_col + margin
			end
		end
	end
	for _, link in ipairs(content.link_metadata or {}) do
		link.col_start = link.col_start + margin
		link.col_end = link.col_end + margin
	end
	for _, block in ipairs(content.code_blocks or {}) do
		block.prefix_len = (block.prefix_len or 0) + margin
	end
	for _, placement in ipairs(content.image_placements or {}) do
		placement.col = placement.col + margin
	end
	for _, placement in ipairs(content.text_placements or {}) do
		placement.col = placement.col + margin
		if placement.icon_col then
			placement.icon_col = placement.icon_col + margin
		end
	end
	return content
end

return M
