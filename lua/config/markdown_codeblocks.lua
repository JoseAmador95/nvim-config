-- Add reading-view decoration around md-render's code lines without changing
-- its content, source-line map, or pinned checkout.
local M = {}

local namespace = vim.api.nvim_create_namespace("nvim_config_markdown_codeblocks")
local background_group = "MdRenderCodeBlockBackground"
local label_group = "MdRenderCodeBlockLabel"
local max_label_length = 32
local max_region_width = 160

local function nonnegative_integer(value, fallback)
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.max(0, math.floor(value))
end

local function page_region(session)
	local opts = session.opts or {}
	local margin = nonnegative_integer(opts.nvim_config_page_margin, 0)
	local width = opts.nvim_config_page_width
	if type(width) ~= "number" then
		width = nonnegative_integer(opts.max_width, 80) + vim.api.nvim_strwidth(opts.indent or "  ")
	end
	width = math.max(1, math.min(max_region_width, nonnegative_integer(width, 80)))
	return margin, margin + width
end

local function language_label(language)
	if type(language) ~= "string" then
		return nil
	end
	-- Fence info strings are untrusted document text. Show the language token,
	-- while excluding terminal controls and overly long virtual text.
	local label = language:match("^%s*([%w%._+#/%-%:]+)")
	if not label or label == "" then
		return nil
	end
	if #label > max_label_length then
		label = label:sub(1, max_label_length - 1) .. "…"
	end
	return label
end

local function shade_line(buf, row, line, from_col, right_col)
	local line_end = #line
	if line_end > from_col then
		vim.api.nvim_buf_set_extmark(buf, namespace, row, from_col, {
			end_col = line_end,
			hl_group = background_group,
			priority = 4100,
		})
	end
	local padding = right_col - vim.fn.strdisplaywidth(line)
	if padding > 0 then
		vim.api.nvim_buf_set_extmark(buf, namespace, row, line_end, {
			virt_text = { { string.rep(" ", padding), background_group } },
			virt_text_pos = "eol",
		})
	end
end

---Decorate the current render buffer. Safe to repeat after source or size changes.
---@param session table md-render v3.10.3 Session
function M.decorate(session)
	local buf = session and session.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local content = session.content or {}
	local lines = content.lines or {}
	local left, right = page_region(session)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

	for _, block in ipairs(content.code_blocks or {}) do
		local label = language_label(block.language)
		local row = block.start_line
		local last = block.end_line
		if type(row) == "number" and type(last) == "number" then
			local from_col = math.max(left, nonnegative_integer(block.prefix_len, left))
			for code_row = math.max(0, row), math.min(last, #lines - 1) do
				local line = lines[code_row + 1]
				if type(line) == "string" then
					shade_line(buf, code_row, line, from_col, right)
				end
			end
		end
		if label and type(row) == "number" and row >= 0 and row < #lines then
			local indent = nonnegative_integer(block.prefix_len, left)
			vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
				virt_lines = {
					{
						{ string.rep(" ", math.max(left, indent)), "Normal" },
						{ " " .. label .. " ", label_group },
					},
				},
				virt_lines_above = true,
			})
		end
	end
end

---Redecorate after the renderer replaces its lines and highlight extmarks.
---@param session table md-render v3.10.3 Session
function M.protect_rebuild(session)
	if session.nvim_config_codeblock_rebuild then
		return
	end
	local original_rebuild = session.rebuild
	session.rebuild = function(self, ...)
		local result = original_rebuild(self, ...)
		M.decorate(self)
		return result
	end
	session.nvim_config_codeblock_rebuild = true
end

return M
