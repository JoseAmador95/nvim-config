-- lua/config/diagram_blocks.lua
-- Generic scanner for fenced diagram blocks (```mermaid, ```plantuml, ...) in a
-- markdown buffer. Shared by config.diagram (unified viewer) and
-- config.mermaid_preview (browser preview). The caller decides which languages
-- to look for and handles non-markdown / whole-buffer cases.
local M = {}

-- Fenced blocks whose info-string language is a key in `langs` (a set, keys
-- lowercased). Returns a list of { s0, e0, lang, src } where s0/e0 are 0-indexed
-- fence rows (inclusive) and src is the block's inner text.
function M.find(buf, langs)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local out = {}
	local open = nil
	for i = 1, #lines do
		local ticks, rest = lines[i]:match("^%s*([`~][`~][`~]+)(.*)$")
		if ticks then
			if not open then
				local lang = (vim.trim(rest):match("^(%S*)") or ""):lower()
				open = { char = ticks:sub(1, 1), len = #ticks, lang = lang, s = i }
			elseif ticks:sub(1, 1) == open.char and #ticks >= open.len and vim.trim(rest) == "" then
				if langs[open.lang] then
					out[#out + 1] = {
						s0 = open.s - 1,
						e0 = i - 1,
						lang = open.lang,
						src = table.concat(vim.list_slice(lines, open.s + 1, i - 1), "\n"),
					}
				end
				open = nil
			end
		end
	end
	return out
end

-- The block under the cursor among `langs`. Returns { s0, e0, lang, src } or nil.
function M.under_cursor(buf, langs)
	local row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed
	for _, b in ipairs(M.find(buf, langs)) do
		if row >= b.s0 + 1 and row <= b.e0 + 1 then
			return b
		end
	end
	return nil
end

return M
