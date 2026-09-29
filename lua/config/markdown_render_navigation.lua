-- Follow rendered Markdown links through the source navigation policy. The
-- renderer's link metadata uses byte columns and is updated on every rebuild.
local M = {}

local markdown_navigation = require("config.markdown_navigation")
local pager = require("config.pager")

local function valid_session(session, win)
	return type(session) == "table"
		and vim.api.nvim_win_is_valid(win)
		and type(session.buf) == "number"
		and vim.api.nvim_buf_is_valid(session.buf)
		and vim.api.nvim_win_get_buf(win) == session.buf
		and vim.b[session.buf].md_render == true
		and type(session.source_bufnr) == "number"
		and vim.api.nvim_buf_is_valid(session.source_bufnr)
		and type(session.content) == "table"
end

local function link_at(content, row, col)
	for _, link in ipairs(content.link_metadata or {}) do
		if link.line == row and col >= link.col_start and col < link.col_end then
			return link
		end
	end
end

local function source_column(source_buf, source_row, link, rendered_line)
	local line = vim.api.nvim_buf_get_lines(source_buf, source_row - 1, source_row, false)[1] or ""
	local url = link.url
	local at = line:find(url, 1, true)
	if at then
		return at - 1
	end
	-- Reference links carry a resolved destination in renderer metadata, but
	-- their source line contains only the label. Find that visible label.
	local label = rendered_line:sub(link.col_start + 1, link.col_end)
	if label ~= "" then
		at = line:find(label, 1, true)
		if at then
			return at - 1
		end
	end
end

local function jump_to_anchor(session, win, url)
	local anchor = url:match("^#(.+)$")
	if not anchor then
		return nil
	end
	local content = session.content
	local target = (content.heading_anchors or {})[anchor] or (content.footnote_anchors or {})[anchor]
	if type(target) ~= "number" or target < 0 or target >= vim.api.nvim_buf_line_count(session.buf) then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(session.buf, target, target + 1, false)[1] or ""
	local col = (line:find("%S") or 1) - 1
	vim.api.nvim_win_set_cursor(win, { target + 1, col })
	return true
end

---Follow the rendered link under the cursor in this session's window.
---@param session table md-render v3.10.3 Session
---@param win? integer
---@return boolean
function M.follow(session, win)
	win = win or vim.api.nvim_get_current_win()
	if pager.active or vim.g.vscode or not valid_session(session, win) then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row, col = cursor[1] - 1, cursor[2]
	local content = session.content
	local link = link_at(content, row, col)
	if not link or type(link.url) ~= "string" then
		return false
	end
	if not markdown_navigation.rendered_allowed(session.source_bufnr) then
		return false
	end
	local jumped = jump_to_anchor(session, win, link.url)
	if jumped then
		return true
	end
	local source_row = (content.source_line_map or {})[row + 1]
	if type(source_row) ~= "number" or source_row < 1 then
		return false
	end
	local line = vim.api.nvim_buf_get_lines(session.buf, row, row + 1, false)[1] or ""
	return markdown_navigation.follow_rendered_link(
		session.source_bufnr,
		source_row - 1,
		source_column(session.source_bufnr, source_row, link, line),
		link.url
	)
end

---Install the editor-only mapping on one renderer-owned buffer.
---@param session table md-render v3.10.3 Session
---@return boolean
function M.attach(session)
	if
		pager.active
		or vim.g.vscode
		or type(session) ~= "table"
		or type(session.buf) ~= "number"
		or not vim.api.nvim_buf_is_valid(session.buf)
		or vim.b[session.buf].md_render ~= true
	then
		return false
	end
	vim.keymap.set("n", "gd", function()
		M.follow(session)
	end, { buffer = session.buf, silent = true, desc = "Open rendered Markdown link" })
	return true
end

return M
