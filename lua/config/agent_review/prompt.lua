-- lua/config/agent_review/prompt.lua
-- Turns accumulated review findings into a markdown prompt to paste back into
-- the agent's chat.
--
-- Two clearly separated responsibilities:
--   M.render(findings, opts) -> string|nil   pure: findings -> markdown text
--   M.present(text, opts)                    effects: scratch buffer + clipboard
--
-- `render` has no vim/API/global dependency at all (it is snapshot-tested and
-- must be fully deterministic: findings are sorted by file, then line, then
-- end line, then text).
--
-- `present` ALWAYS opens the buffer first and only then tries the clipboard, so
-- the prompt is on screen even when the clipboard is unconfigured (ssh, no
-- provider). OSC52 gives no acknowledgement, so a copy can never be reported as
-- confirmed — the notification names the active provider instead and points at
-- the buffer for a manual yank.
local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "AgentReview" })
end

-- Render ------------------------------------------------------------------

local DEFAULT_HEADER = "Revisé los cambios que hiciste en esta rama. Corrige los puntos siguientes.\n"
	.. "Cada entrada es `ruta:línea` seguida del comentario."

local DEFAULT_FOOTER = "No toques nada fuera de estos puntos."

-- Fallback bullet text when a finding carries no comment of its own.
local KIND_TEXT = {
	reject = "hunk rechazado",
	comment = "comentario",
	check = "revisar",
}

-- Collapse any run of whitespace/newlines into a single space, then trim.
local function one_line(s)
	if type(s) ~= "string" then
		return ""
	end
	s = s:gsub("%s+", " ")
	return (s:gsub("^ +", ""):gsub(" +$", ""))
end

local function split_lines(s)
	local out = {}
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		out[#out + 1] = line
	end
	return out
end

local function bullet_text(finding)
	local text = one_line(finding.text)
	if text ~= "" then
		return text
	end
	return KIND_TEXT[finding.kind] or "revisar"
end

local function location(finding)
	local lnum = finding.lnum or 1
	local last = finding.end_lnum
	if type(last) == "number" and last > lnum then
		return string.format("%s:%d-%d", finding.file, lnum, last)
	end
	return string.format("%s:%d", finding.file, lnum)
end

---Render findings as a markdown prompt. Pure.
---@param findings ARFinding[]|nil
---@param opts { include_diff: boolean?, header: string?, footer: string? }|nil
---@return string|nil
function M.render(findings, opts)
	if type(findings) ~= "table" or #findings == 0 then
		return nil
	end
	opts = opts or {}

	local header = opts.header ~= nil and opts.header or DEFAULT_HEADER
	local footer = opts.footer ~= nil and opts.footer or DEFAULT_FOOTER

	-- Group by file, keeping a sorted list of the file paths.
	local by_file, files = {}, {}
	for _, f in ipairs(findings) do
		local path = f.file or ""
		if not by_file[path] then
			by_file[path] = {}
			files[#files + 1] = path
		end
		local bucket = by_file[path]
		bucket[#bucket + 1] = f
	end
	table.sort(files)

	local lines = {}
	if header ~= "" then
		for _, l in ipairs(split_lines(header)) do
			lines[#lines + 1] = l
		end
		lines[#lines + 1] = ""
	end

	for _, path in ipairs(files) do
		local bucket = by_file[path]
		-- Deterministic order: line, then end line, then the (collapsed) text.
		table.sort(bucket, function(a, b)
			local al, bl = a.lnum or 0, b.lnum or 0
			if al ~= bl then
				return al < bl
			end
			local ae, be = a.end_lnum or a.lnum or 0, b.end_lnum or b.lnum or 0
			if ae ~= be then
				return ae < be
			end
			return one_line(a.text) < one_line(b.text)
		end)

		lines[#lines + 1] = "## " .. path
		lines[#lines + 1] = ""
		for _, f in ipairs(bucket) do
			lines[#lines + 1] = string.format("- `%s` — %s", location(f), bullet_text(f))
			if opts.include_diff and type(f.diff) == "string" and f.diff ~= "" then
				lines[#lines + 1] = "```diff"
				for _, l in ipairs(split_lines((f.diff:gsub("\n$", "")))) do
					lines[#lines + 1] = l
				end
				lines[#lines + 1] = "```"
			end
		end
		lines[#lines + 1] = ""
	end

	if footer ~= "" then
		for _, l in ipairs(split_lines(footer)) do
			lines[#lines + 1] = l
		end
	end

	-- No trailing blank lines beyond the single terminating newline.
	while #lines > 0 and lines[#lines] == "" do
		lines[#lines] = nil
	end

	return table.concat(lines, "\n") .. "\n"
end

-- Present -----------------------------------------------------------------

local function clipboard_provider()
	local cb = vim.g.clipboard
	if type(cb) == "table" and type(cb.name) == "string" and cb.name ~= "" then
		return cb.name
	end
	return nil
end

---Show the prompt in a scratch buffer and then try to copy it.
---The buffer comes first on purpose: it is the reliable half.
---@param text string
---@param opts { clipboard: boolean? }|nil
function M.present(text, opts)
	if type(text) ~= "string" or text == "" then
		notify("Nothing to present: the prompt is empty", vim.log.levels.WARN)
		return
	end
	opts = opts or {}
	local want_clipboard = opts.clipboard ~= false

	-- 1. Buffer first: whatever happens with the clipboard, the prompt is visible.
	vim.cmd("new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines((text:gsub("\n$", ""))))
	vim.bo[buf].filetype = "markdown"
	-- Left modifiable on purpose: the prompt is a draft, tweaking it before
	-- pasting is part of the workflow.
	vim.bo[buf].modifiable = true
	vim.bo[buf].modified = false
	pcall(vim.api.nvim_buf_set_name, buf, "agent-review://prompt")

	vim.keymap.set("n", "q", function()
		if not pcall(vim.api.nvim_win_close, 0, true) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end, { buffer = buf, desc = "Close the review prompt" })

	vim.keymap.set("n", "<leader>y", function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local ok, err = pcall(vim.fn.setreg, "+", table.concat(lines, "\n") .. "\n")
		if ok then
			notify("Prompt written to the + register")
		else
			notify("Could not write the + register: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, { buffer = buf, desc = "Yank the whole review prompt to +" })

	if not want_clipboard then
		return
	end

	-- 2. Clipboard second, and never claimed as confirmed: OSC52 does not
	-- acknowledge, so Lua cannot know whether the text reached the system
	-- clipboard. Report the provider and the manual fallback instead.
	local ok, err = pcall(vim.fn.setreg, "+", text)
	if not ok then
		notify(
			"Could not write the + register: " .. tostring(err) .. ". The prompt is open, yank it with <leader>y.",
			vim.log.levels.ERROR
		)
		return
	end
	local provider = clipboard_provider()
	local who = provider and ("clipboard provider: " .. provider) or "built-in clipboard provider in use"
	notify("Prompt written to the + register (" .. who .. "). Buffer open — <leader>y re-yanks it.")
end

-- Setup -------------------------------------------------------------------

---Findings staged by another module: the findings store belongs to a sibling.
---@type ARFinding[]|nil
M._pending = nil

function M.setup()
	if vim.g.vscode or require("config.pager").active then
		return
	end

	vim.api.nvim_create_user_command("AgentReviewPrompt", function()
		local text = M.render(M._pending, { include_diff = false })
		if not text then
			notify("No findings to turn into a prompt")
			return
		end
		M.present(text)
	end, { desc = "Build the agent review prompt from the current findings" })
end

return M
