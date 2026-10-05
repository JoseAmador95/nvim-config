-- Center the editor's rendered Markdown page without changing md-render's
-- source-line mapping or byte columns. The pinned renderer builds content
-- before it knows the display window, so the host supplies the page width and
-- left margin.
local M = {}

local MAX_PAGE_WIDTH = 120
local RENDER_INDENT_WIDTH = 2

local namespace = vim.api.nvim_create_namespace("nvim_config_markdown_page")

function M.text_width(win)
	local info = vim.fn.getwininfo(win)[1]
	local textoff = info and info.textoff or 0
	return math.max(1, vim.api.nvim_win_get_width(win) - textoff)
end

-- Prose stays in the centered page. Tables and code blocks start at the same
-- left margin but may extend to the window's right edge (the block width).
function M.measure(win)
	local available = M.text_width(win)
	local page_width = math.max(1, math.min(MAX_PAGE_WIDTH, math.floor(available * 0.9)))
	local margin = math.floor((available - page_width) / 2)
	return page_width, margin, available - margin
end

-- md-render's horizontal rules prepend its two-space base indent to a rule
-- whose own width is max_width. Reserve that indent inside the page budget.
function M.render_width(page_width)
	return math.max(1, page_width - RENDER_INDENT_WIDTH)
end

-- The page margin is drawn as inline virtual text (M.pad), never as buffer
-- text, so Visual selections and yanks contain only the rendered page and
-- md-render's byte columns stay valid. Two fields still need the margin:
-- Kitty images are placed at buffer column + textoff and do not see inline
-- virtual text, and a blank row keeps one real cell because Neovim draws the
-- cursor of an empty line before inline virtual text.
function M.center_content(content, opts)
	local margin = opts and opts.nvim_config_page_margin
	if type(margin) ~= "number" or margin <= 0 then
		return content
	end
	margin = math.floor(margin)
	for index, line in ipairs(content.lines) do
		if line == "" then
			content.lines[index] = " "
		end
	end
	for _, placement in ipairs(content.image_placements or {}) do
		placement.col = placement.col + margin
	end
	return content
end

-- Draw the left page margin on every rendered row. Safe to repeat after a
-- rebuild; a margin of zero (the pager) clears it.
function M.pad(buf, margin)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	margin = type(margin) == "number" and math.floor(margin) or 0
	if margin <= 0 then
		return
	end
	local chunks = { { string.rep(" ", margin) } }
	for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
		vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
			virt_text = chunks,
			virt_text_pos = "inline",
			right_gravity = false,
			priority = 10000,
		})
	end
end

M.namespace = namespace

return M
