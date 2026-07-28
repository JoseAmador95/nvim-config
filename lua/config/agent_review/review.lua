-- lua/config/agent_review/review.lua
-- The human pass of the agent-review workflow: walk the hunks an agent produced
-- (in risk order, worst first) and record a verdict on each one.
--
--   ]v / [v        next / previous UNREVIEWED hunk, across *all* changed files
--   <leader>va     accept the hunk under the cursor
--   <leader>vx     reject it   -- a MARK ONLY: the buffer is never modified
--   <leader>vc     comment on it (vim.ui.input -> "comment" verdict)
--
-- Two deliberate design points:
--   * Rejecting never reverts anything. Reverting an agent's hunk is a separate
--     concern (git/undo already do it well) and doing it here would make a review
--     pass destructive; a review pass must be safe to run on a dirty tree.
--   * Navigation walks git.changed_files() order, not the current buffer, because
--     that order is the risk ranking -- reviewing the riskiest file first is the
--     entire point. Hunks that already carry a verdict are skipped, so ]v drains
--     a queue instead of cycling.
--
-- State (verdicts, base ref) is resolved lazily on first use: setup() only
-- registers maps/commands so startup stays cheap.
--
-- Nothing throws and nothing fails silently: every entry point returns
-- `nil, err` and the interactive wrappers surface `err` through git.notify.

local M = {}

local git = require("config.agent_review.git")
local state = require("config.agent_review.state")

local notify = git.notify

local NS = vim.api.nvim_create_namespace("agent_review_verdicts")
local AUGROUP = "AgentReviewSigns"

-- Sign column marks. `unreviewed` is the queue; `whitespace` is deliberately
-- dimmed (NonText) because whitespace-class hunks are noise by construction.
local SIGNS = {
	accept = { text = "✓", hl = "DiagnosticSignOk", priority = 20 },
	reject = { text = "✗", hl = "DiagnosticSignError", priority = 20 },
	comment = { text = "≡", hl = "DiagnosticSignWarn", priority = 20 },
	unreviewed = { text = "▎", hl = "DiagnosticSignInfo", priority = 15 },
	whitespace = { text = "┊", hl = "NonText", priority = 5 },
}

local LABEL = { accept = "Accepted", reject = "Rejected (mark only)", comment = "Commented on" }

--- Whitespace-class hunks are skipped by ]v / [v. Flip to false to review them.
M.skip_whitespace = true

local NO_SNAPSHOT = "no agent-review snapshot yet: take one first (<leader>vs)"

local function norm(path)
	return (path:gsub("\\", "/"):gsub("/+$", ""))
end

-- Context ------------------------------------------------------------------

--- Repo root + base ref for this round, loading the verdict store on the way.
--- Falls back to the newest snapshot when no base was recorded yet.
---@return { root: string, base: string }|nil ctx, string|nil err
function M.context()
	local root = git.root()
	if not root then
		return nil, "not inside a git repository"
	end
	local loaded, err = state.load(root)
	if not loaded then
		return nil, err or "could not load review state"
	end
	-- Shared resolver: warns once when it adopts a snapshot nobody armed, and
	-- does not persist it. Persisting here used to make :AgentReviewReset undo
	-- itself on the very next BufEnter.
	local base, berr = git.resolve_base(state.base())
	if not base then
		return nil, berr or NO_SNAPSHOT
	end
	return { root = root, base = base }, nil
end

--- Path of `buf` relative to the repo root (forward slashes).
---@return string|nil rel, string|nil err
local function rel_path(root, buf)
	local name = vim.api.nvim_buf_get_name(buf or 0)
	if name == "" then
		return nil, "current buffer is not a file on disk"
	end
	local abs = norm(vim.fn.fnamemodify(name, ":p"))
	-- Symlinked roots (/tmp -> /private/tmp, ~/dev -> ...) make the plain prefix
	-- test fail, so both spellings are tried on both sides.
	local paths = { abs, norm(vim.fn.resolve(abs)) }
	local roots = { norm(root), norm(vim.fn.resolve(root)) }
	for _, r in ipairs(roots) do
		for _, a in ipairs(paths) do
			if a:sub(1, #r + 1) == r .. "/" then
				return a:sub(#r + 2), nil
			end
		end
	end
	return nil, vim.fn.fnamemodify(name, ":~") .. " is outside " .. root
end

-- Hunks --------------------------------------------------------------------

--- Hunks of the current buffer's file against the review base.
---@param buf? integer
---@return ARHunk[]|nil hunks, string|nil err
function M.hunks_for_current(buf)
	local ctx, err = M.context()
	if not ctx then
		return nil, err
	end
	local rel
	rel, err = rel_path(ctx.root, buf or 0)
	if not rel then
		return nil, err
	end
	return git.hunks(ctx.base, rel)
end

--- Every hunk of every changed file, flattened in git.changed_files() order
--- (risk-ranked): the traversal order of ]v / [v.
---@return ARHunk[]|nil hunks, string|nil err
function M.all_hunks()
	local ctx, err = M.context()
	if not ctx then
		return nil, err
	end
	local files
	files, err = git.changed_files(ctx.base)
	if not files then
		return nil, err
	end
	local out = {}
	for _, f in ipairs(files) do
		local hunks = git.hunks(ctx.base, f.path)
		for _, hunk in ipairs(hunks or {}) do
			out[#out + 1] = hunk
		end
	end
	return out, nil
end

--- reviewed / total across every changed file.
---@return integer reviewed, integer total
function M.progress()
	local hunks = M.all_hunks()
	return state.progress(hunks or {})
end

--- The hunk whose new-side range contains `lnum`. Never a neighbour: when no
--- hunk covers the line the caller must say so instead of guessing.
---@param hunks ARHunk[]
---@param lnum integer
---@return ARHunk|nil
local function hunk_at(hunks, lnum)
	for _, hunk in ipairs(hunks or {}) do
		local first = math.max(hunk.new_start or 1, 1)
		local last = first + math.max(hunk.new_count or 1, 1) - 1
		if lnum >= first and lnum <= last then
			return hunk
		end
	end
	return nil
end

--- The hunk under the cursor of the current window.
---@return ARHunk|nil hunk, string|nil err
function M.hunk_under_cursor()
	local hunks, err = M.hunks_for_current()
	if not hunks then
		return nil, err
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local hunk = hunk_at(hunks, lnum)
	if not hunk then
		return nil, ("no agent hunk on line %d of this file (%d hunk(s) here)"):format(lnum, #hunks)
	end
	return hunk, nil
end

-- Signs --------------------------------------------------------------------

local function sign_for(hunk)
	local v = state.get_verdict(hunk.id)
	if v then
		return SIGNS[v.verdict]
	end
	if hunk.class == "whitespace" then
		return SIGNS.whitespace
	end
	return SIGNS.unreviewed
end

--- Redraw the verdict marks of one buffer. Quiet by design: this runs on
--- BufEnter, where a notification for "not a git repo" would be noise.
---@param buf? integer
---@return integer marks, string|nil err
function M.refresh_signs(buf)
	buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
	if not vim.api.nvim_buf_is_valid(buf) then
		return 0, "invalid buffer"
	end
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	if vim.bo[buf].buftype ~= "" then
		return 0, nil
	end
	local hunks, err = M.hunks_for_current(buf)
	if not hunks then
		return 0, err
	end
	local total = vim.api.nvim_buf_line_count(buf)
	local placed = 0
	for _, hunk in ipairs(hunks) do
		local sign = sign_for(hunk)
		local first = math.max(hunk.new_start or 1, 1)
		-- new_count == 0 is a pure deletion: mark the surviving line next to it.
		local last = first + math.max(hunk.new_count or 1, 1) - 1
		for lnum = first, math.min(last, total) do
			pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum - 1, 0, {
				sign_text = sign.text,
				sign_hl_group = sign.hl,
				priority = sign.priority,
			})
			placed = placed + 1
		end
	end
	return placed, nil
end

--- Drop every mark this module placed in `buf`.
function M.clear_signs(buf)
	buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	end
end

-- Verdicts -----------------------------------------------------------------

---@param hunk ARHunk
---@param verdict "accept"|"reject"|"comment"
---@param text string|nil
---@return boolean ok, string|nil err
local function record(hunk, verdict, text)
	local ok, err = state.set_verdict(hunk.id, verdict, text)
	if not ok then
		return false, err
	end
	M.refresh_signs(0)
	local reviewed, total = M.progress()
	notify(
		("%s %s:%d  [%d/%d reviewed]"):format(LABEL[verdict], hunk.file, math.max(hunk.new_start, 1), reviewed, total)
	)
	return true, nil
end

--- Record `verdict` on the hunk under the cursor. `<leader>vx` (reject) marks
--- only: the buffer contents are never touched.
---@param verdict "accept"|"reject"|"comment"
---@param text string|nil
---@return boolean ok, string|nil err
function M.set_verdict_at_cursor(verdict, text)
	local hunk, err = M.hunk_under_cursor()
	if not hunk then
		notify(err, vim.log.levels.WARN)
		return false, err
	end
	local ok
	ok, err = record(hunk, verdict, text)
	if not ok then
		notify("Could not record verdict: " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok, err
end

function M.accept()
	return M.set_verdict_at_cursor("accept")
end

function M.reject()
	return M.set_verdict_at_cursor("reject")
end

--- Prompt for a note and store it as a `comment` verdict. The hunk is resolved
--- *before* the prompt so an invalid position fails immediately.
function M.comment()
	local hunk, err = M.hunk_under_cursor()
	if not hunk then
		notify(err, vim.log.levels.WARN)
		return false, err
	end
	vim.ui.input({ prompt = ("Comment on %s:%d: "):format(hunk.file, math.max(hunk.new_start, 1)) }, function(input)
		if input == nil then
			notify("Comment cancelled")
			return
		end
		input = vim.trim(input)
		if input == "" then
			notify("Empty comment: nothing recorded", vim.log.levels.WARN)
			return
		end
		local ok, rerr = record(hunk, "comment", input)
		if not ok then
			notify("Could not record comment: " .. tostring(rerr), vim.log.levels.ERROR)
		end
	end)
	return true, nil
end

-- Navigation ---------------------------------------------------------------

local function is_pending(hunk)
	if state.get_verdict(hunk.id) then
		return false
	end
	if M.skip_whitespace and hunk.class == "whitespace" then
		return false
	end
	return true
end

--- Index in `hunks` of the hunk at (or last before) the cursor, 0 when the
--- current buffer is not part of the change set.
local function cursor_index(ctx, hunks)
	local rel = rel_path(ctx.root, 0)
	if not rel then
		return 0
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local idx = 0
	for i, hunk in ipairs(hunks) do
		if hunk.file == rel and math.max(hunk.new_start or 1, 1) <= lnum then
			idx = i
		end
	end
	return idx
end

--- Jump to the next (or previous) unreviewed hunk across all changed files.
---@param backwards? boolean
---@return ARHunk|nil hunk, string|nil err
function M.goto_next(backwards)
	local ctx, err = M.context()
	if not ctx then
		notify(err, vim.log.levels.WARN)
		return nil, err
	end
	local hunks
	hunks, err = M.all_hunks()
	if not hunks then
		notify(err, vim.log.levels.ERROR)
		return nil, err
	end
	if #hunks == 0 then
		notify("No changes since the snapshot: nothing to review")
		return nil, nil
	end

	local start = cursor_index(ctx, hunks)
	local target, missing
	for offset = 1, #hunks do
		local i = backwards and ((start - offset - 1) % #hunks) + 1 or ((start + offset - 1) % #hunks) + 1
		local hunk = hunks[i]
		if is_pending(hunk) then
			if vim.fn.filereadable(ctx.root .. "/" .. hunk.file) == 1 then
				target = hunk
				break
			end
			missing = (missing or 0) + 1
		end
	end

	local reviewed, total = state.progress(hunks)
	if not target then
		local msg = ("No unreviewed hunks left [%d/%d reviewed]"):format(reviewed, total)
		if M.skip_whitespace then
			local ws = 0
			for _, hunk in ipairs(hunks) do
				if hunk.class == "whitespace" and not state.get_verdict(hunk.id) then
					ws = ws + 1
				end
			end
			if ws > 0 then
				msg = msg .. (", %d whitespace hunk(s) skipped"):format(ws)
			end
		end
		if missing then
			msg = msg .. (", %d in deleted files"):format(missing)
		end
		notify(msg)
		return nil, nil
	end

	local lnum = math.max(target.new_start or 1, 1)
	require("config.editor").open_file_in_tab(ctx.root .. "/" .. target.file, { lnum = lnum })
	M.refresh_signs(0)
	notify(("%s:%d  [%s]  [%d/%d reviewed]"):format(target.file, lnum, target.class, reviewed, total))
	return target, nil
end

function M.goto_prev()
	return M.goto_next(true)
end

-- gitsigns base ------------------------------------------------------------

local function change_base(ref)
	local ok, err = pcall(function()
		require("gitsigns").change_base(ref, true)
	end)
	if not ok then
		-- A missing module raises a multi-line search path; only the first line
		-- is worth showing.
		local first = vim.split(tostring(err), "\n", { plain = true })[1]
		return false, "gitsigns unavailable, base unchanged: " .. first
	end
	return true, nil
end

--- Point gitsigns at the snapshot, so every ordinary buffer shows the agent's
--- changes (and only those) in its sign column.
---@param ref? string defaults to the current review base
---@return boolean ok, string|nil err
function M.set_base_to_snapshot(ref)
	if not ref then
		local ctx, err = M.context()
		if not ctx then
			notify(err, vim.log.levels.WARN)
			return false, err
		end
		ref = ctx.base
	end
	local ok, err = change_base(ref)
	if not ok then
		notify(err, vim.log.levels.WARN)
		return false, err
	end
	notify("gitsigns base -> " .. ref)
	return true, nil
end

--- Undo set_base_to_snapshot(): back to the index.
---@return boolean ok, string|nil err
function M.reset_base()
	local ok, err = change_base(nil)
	if not ok then
		notify(err, vim.log.levels.WARN)
		return false, err
	end
	notify("gitsigns base -> index")
	return true, nil
end

-- Setup --------------------------------------------------------------------

function M.setup()
	if vim.g.vscode or require("config.pager").active then
		return
	end

	local commands = {
		AgentReviewNext = { M.goto_next, "Agent review: next unreviewed hunk" },
		AgentReviewPrev = { M.goto_prev, "Agent review: previous unreviewed hunk" },
		AgentReviewAccept = { M.accept, "Agent review: accept hunk under cursor" },
		AgentReviewReject = { M.reject, "Agent review: reject hunk under cursor (mark only)" },
		AgentReviewComment = { M.comment, "Agent review: comment on hunk under cursor" },
	}
	for name, spec in pairs(commands) do
		vim.api.nvim_create_user_command(name, function()
			spec[1]()
		end, { desc = spec[2] })
	end

	local maps = {
		{ "]v", M.goto_next, "Next unreviewed agent hunk" },
		{ "[v", M.goto_prev, "Previous unreviewed agent hunk" },
		{ "<leader>va", M.accept, "Accept agent hunk under cursor" },
		{ "<leader>vx", M.reject, "Reject agent hunk (mark only)" },
		{ "<leader>vc", M.comment, "Comment on agent hunk under cursor" },
	}
	for _, m in ipairs(maps) do
		vim.keymap.set("n", m[1], function()
			m[2]()
		end, { desc = m[3] })
	end

	-- Marks are per buffer and cheap to rebuild, so they are refreshed when a
	-- buffer is entered (and after every verdict, from record()).
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
		callback = function(a)
			-- Deferred: BufEnter fires on every tab jump and each refresh shells
			-- out to git; keep the jump itself snappy.
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(a.buf) then
					M.refresh_signs(a.buf)
				end
			end)
		end,
		desc = "Refresh agent-review verdict marks",
	})
end

return M
