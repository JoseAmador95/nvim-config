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
-- provider). Opening the window is itself guarded so a failure of either half
-- cannot cost both. OSC52 gives no acknowledgement, so a copy can never be
-- reported as confirmed -- the notification names the active provider instead
-- and points at the buffer for a manual yank; with no provider at all it says
-- exactly that, because "written to +" would be a plain lie over bare ssh.
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

-- Placeholder for a finding that carries no path: `string.format("%s", nil)`
-- throws under plain Lua 5.1 (where `render` is exercised) and an empty "## "
-- heading tells the agent nothing anyway.
local UNKNOWN_FILE = "(archivo desconocido)"

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

-- The one place a finding's path is normalised: grouping and the bullet's
-- location must agree, otherwise a heading and its bullets name different files.
local function file_of(finding)
	local file = finding.file
	if type(file) ~= "string" or file == "" then
		return UNKNOWN_FILE
	end
	return file
end

-- Line 1 is the floor: `path:0` (or a negative) is not a location a human or an
-- agent can open, and findings arrive from several producers.
local function lnum_of(value)
	local lnum = tonumber(value)
	if not lnum or lnum < 1 then
		return 1
	end
	return math.floor(lnum)
end

local function location(finding)
	local lnum = lnum_of(finding.lnum)
	local last = tonumber(finding.end_lnum)
	if last and math.floor(last) > lnum then
		return string.format("%s:%d-%d", file_of(finding), lnum, math.floor(last))
	end
	return string.format("%s:%d", file_of(finding), lnum)
end

-- `opts.header = ""` (or `false`) means "no header", which the older
-- `x ~= nil and x or default` idiom could never express: it fell back to the
-- default for every falsy value.
local function section(value, default)
	if value == nil then
		return default
	end
	if type(value) ~= "string" then
		return ""
	end
	return value
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

	local header = section(opts.header, DEFAULT_HEADER)
	local footer = section(opts.footer, DEFAULT_FOOTER)

	-- Group by file, keeping a sorted list of the file paths.
	local by_file, files = {}, {}
	for _, f in ipairs(findings) do
		local path = file_of(f)
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
			local al, bl = lnum_of(a.lnum), lnum_of(b.lnum)
			if al ~= bl then
				return al < bl
			end
			local ae, be = lnum_of(a.end_lnum or a.lnum), lnum_of(b.end_lnum or b.lnum)
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

-- Which provider `setreg("+", ...)` would actually go through, or nil when
-- there is none.
--
-- `vim.g.clipboard` is ONLY set by an explicit user override: Neovim's built-in
-- detection (pbcopy, xclip/xsel, wl-copy, win32yank, OSC52) leaves it nil, so
-- reading it alone cannot tell "a provider works" from "there is no provider at
-- all". Same probe as lua/agent_review/health.lua: provider#clipboard#Executable()
-- is the autoload function that resolves the built-in choice and returns "" when
-- nothing was found. `setreg` does not throw without a provider, so this is the
-- only thing standing between the user and a false "copied!" over bare ssh.
local function clipboard_provider()
	local cb = vim.g.clipboard
	if type(cb) == "table" and type(cb.name) == "string" and cb.name ~= "" then
		return cb.name
	end
	local ok, provider = pcall(vim.fn["provider#clipboard#Executable"])
	provider = ok and vim.trim(tostring(provider or "")) or ""
	if provider ~= "" then
		return provider
	end
	return nil
end

-- Report the outcome of a register write without ever claiming delivery.
---@param buf_open boolean whether the prompt buffer is on screen
local function report_copy(buf_open)
	local provider = clipboard_provider()
	if not provider then
		local msg = "No clipboard provider found: the + register never leaves Neovim, nothing was copied."
		if buf_open then
			msg = msg .. " The prompt is open in this buffer — copy it from the terminal."
		end
		notify(msg .. " Install pbcopy/xclip/wl-copy, or enable OSC52.", vim.log.levels.WARN)
		return
	end
	local msg = ("Prompt written to the + register via %s;"):format(provider)
		.. " delivery is never acknowledged, so paste once to check."
	if buf_open then
		msg = msg .. " Buffer open — <leader>y re-yanks it."
	end
	notify(msg)
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
	--    `:new` can still fail (E36 with a large winminheight, E11 from the
	--    cmdline window), and letting that propagate would take the clipboard
	--    half down with it and leave the user with nothing at all.
	local buf = nil
	local opened, werr = pcall(vim.cmd, "new")
	if opened then
		buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].buftype = "nofile"
		-- NOT "wipe": the buffer is modifiable on purpose (tweaking the prompt
		-- before pasting is part of the workflow) and "wipe" plus the forced
		-- `modified = false` below would throw those edits away on the next
		-- `:bnext`/`:e`, with no E37 and no warning.
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines((text:gsub("\n$", ""))))
		vim.bo[buf].filetype = "markdown"
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
			if not ok then
				notify("Could not write the + register: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			report_copy(true)
		end, { buffer = buf, desc = "Yank the whole review prompt to +" })
	else
		notify(
			"Could not open the prompt buffer: " .. tostring(werr) .. ". Trying the + register anyway.",
			vim.log.levels.ERROR
		)
	end

	if not want_clipboard then
		if not buf then
			notify("The prompt could not be shown anywhere; run it again from another window.", vim.log.levels.WARN)
		end
		return
	end

	-- 2. Clipboard second, and never claimed as confirmed: OSC52 does not
	-- acknowledge, so Lua cannot know whether the text reached the system
	-- clipboard. Report the provider (or its absence) and the manual fallback.
	local ok, err = pcall(vim.fn.setreg, "+", text)
	if not ok then
		local tail = buf and " The prompt is open, yank it with <leader>y." or ""
		notify("Could not write the + register: " .. tostring(err) .. "." .. tail, vim.log.levels.ERROR)
		return
	end
	report_copy(buf ~= nil)
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
