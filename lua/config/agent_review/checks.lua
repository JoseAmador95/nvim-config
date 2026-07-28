-- lua/config/agent_review/checks.lua
-- The machine pass of the agent-review workflow: cheap automated checks over
-- ONLY the files the agent touched, run *before* the human reads a single line.
-- The premise is that anything a machine can catch should never cost human
-- attention.
--
-- Three checks, all scoped to the diff against the review snapshot:
--   * "lsp"      -- diagnostics (ERROR/WARN) on every changed file. The cheapest
--                   hallucinated-API detector there is: an invented function or
--                   a misspelled field lights up here for free.
--   * "stub"     -- placeholders the agent left behind (TODO, NotImplementedError,
--                   `pass` as a whole body, ...) on ADDED lines only.
--   * "deletion" -- code the agent removed silently; in particular error handling
--                   that vanished while "simplifying".
--
-- The LSP check is the reason `M.run` is asynchronous: diagnostics only arrive
-- after `LspAttach` and the first `textDocument/publishDiagnostics`, so there is
-- no honest synchronous shape for it. It is driven by the `DiagnosticChanged`
-- autocmd with a bounded overall timeout, never by blocking the UI in
-- `vim.wait`. Two escape hatches keep it snappy:
--   * a buffer that has gained no LSP client by the end of a short attach grace
--     can never produce diagnostics, so it settles right away (a repo/filetype
--     with no server configured therefore costs the grace, not the timeout);
--   * buffers loaded solely to be inspected are wiped afterwards; buffers the
--     user already had open are left completely alone.
--
-- Findings feed the prompt renderer and the quickfix list. Nothing throws:
-- `M.run` calls back `nil, err`.

---@class ARFinding
---@field file     string        -- relative to repo root
---@field lnum     integer       -- 1-based, in the CURRENT file
---@field end_lnum integer|nil
---@field text     string
---@field kind     "check"
---@field source   "lsp"|"stub"|"deletion"
---@field severity integer|nil   -- vim.diagnostic.severity, for quickfix typing

local M = {}

local git = require("config.agent_review.git")
local state = require("config.agent_review.state")

-- Tunables ----------------------------------------------------------------

-- Overall budget for the LSP pass: after this we collect whatever arrived.
local LSP_TIMEOUT_MS = 4000
-- How long a freshly loaded buffer is given to gain an LSP client. Past this,
-- a client-less buffer is considered settled instead of burning the timeout.
local LSP_ATTACH_GRACE_MS = 750
-- Debounce after the last DiagnosticChanged, so a second client can still land.
local LSP_SETTLE_MS = 150
-- Upper bound on files handed to the LSP pass (they arrive score-sorted, so the
-- riskiest ones are the ones kept).
local MAX_LSP_FILES = 40
-- A `logic` hunk that removes at least this many lines and adds none is a
-- silent deletion.
local MIN_SILENT_DELETION_LINES = 4
-- Longest source snippet echoed into a finding's text.
local MAX_SNIPPET_LEN = 80

-- Placeholders an agent leaves when it gives up. Order decides which name is
-- reported when several match. Case-sensitive on purpose: prose containing the
-- word "todo" is not a stub, `TODO` is.
local STUB_PATTERNS = {
	{ name = "TODO", pattern = "%f[%w_]TODO%f[^%w_]" },
	{ name = "FIXME", pattern = "%f[%w_]FIXME%f[^%w_]" },
	{ name = "XXX", pattern = "%f[%w_]XXX%f[^%w_]" },
	{ name = "NotImplementedError", pattern = "NotImplementedError" },
	{ name = "raise NotImplemented", pattern = "raise%s+NotImplemented" },
	{ name = "unimplemented!", pattern = "unimplemented!" },
	{ name = "todo!", pattern = "todo!" },
	{ name = 'panic!("not', pattern = "panic!%(%s*[\"']not" },
	{ name = 'throw new Error("not implemented")', pattern = "throw new Error%(%s*[\"']not implemented" },
	{ name = "empty body (pass)", pattern = "^%s*pass%s*$" },
	{ name = "empty body (...)", pattern = "^%s*%.%.%.%s*$" },
}

-- Error handling that must not disappear without a replacement.
local ERROR_HANDLING = {
	{ name = "try", pattern = "%f[%w_]try%f[^%w_]" },
	{ name = "catch", pattern = "%f[%w_]catch%f[^%w_]" },
	{ name = "except", pattern = "%f[%w_]except%f[^%w_]" },
	{ name = "rescue", pattern = "%f[%w_]rescue%f[^%w_]" },
	{ name = "pcall", pattern = "%f[%w_]x?pcall%f[^%w_]" },
	{ name = "if err", pattern = "%f[%w_]if%s+err" },
	{ name = "raise", pattern = "%f[%w_]raise%f[^%w_]" },
	{ name = "throw", pattern = "%f[%w_]throw%f[^%w_]" },
}

-- Helpers -----------------------------------------------------------------

local function snippet(line)
	local t = vim.trim(line or "")
	if #t > MAX_SNIPPET_LEN then
		t = t:sub(1, MAX_SNIPPET_LEN - 1) .. "..."
	end
	return t
end

---Collapse a diagnostic message to a single quickfix-friendly line.
local function one_line(s)
	return vim.trim((tostring(s or ""):gsub("%s*\n%s*", " ")))
end

---Split a hunk body into its added and removed lines (prefixes stripped).
local function split_hunk(hunk)
	local added, removed = {}, {}
	for _, line in ipairs(hunk.lines or {}) do
		local c = line:sub(1, 1)
		if c == "+" then
			added[#added + 1] = line:sub(2)
		elseif c == "-" then
			removed[#removed + 1] = line:sub(2)
		end
	end
	return added, removed
end

local function matches(text, entries)
	for _, entry in ipairs(entries) do
		if text:match(entry.pattern) then
			return entry.name
		end
	end
	return nil
end

local function sort_findings(findings)
	table.sort(findings, function(a, b)
		if a.file ~= b.file then
			return a.file < b.file
		end
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		end
		if a.source ~= b.source then
			return a.source < b.source
		end
		return a.text < b.text
	end)
	return findings
end

-- Check 2: stubs ----------------------------------------------------------

---Line numbers are the classic bug here. In a hunk body the CURRENT file's
---numbering starts at `new_start` and advances on "+" and " " lines only;
---"-" lines exist in the old file only and must not move the cursor. Walking
---the body in order and incrementing on exactly those two prefixes is the only
---formulation that survives a hunk with "-" lines before the flagged "+" line.
---@param hunk ARHunk
---@param out ARFinding[]
local function scan_stubs(hunk, out)
	if hunk.class ~= "logic" and hunk.class ~= "comments" then
		return
	end
	local lnum = math.max(hunk.new_start or 1, 1)
	for _, line in ipairs(hunk.lines or {}) do
		local c = line:sub(1, 1)
		if c == "+" then
			local text = line:sub(2)
			local name = matches(text, STUB_PATTERNS)
			if name then
				out[#out + 1] = {
					file = hunk.file,
					lnum = lnum,
					end_lnum = nil,
					text = ("Placeholder left behind (%s): %s"):format(name, snippet(text)),
					kind = "check",
					source = "stub",
					severity = vim.diagnostic.severity.WARN,
				}
			end
			lnum = lnum + 1
		elseif c == " " then
			lnum = lnum + 1
		end
	end
end

-- Check 3: silent deletions -----------------------------------------------

---@param hunk ARHunk
---@param out ARFinding[]
local function scan_deletions(hunk, out)
	if hunk.class ~= "logic" then
		return
	end
	local added, removed = split_hunk(hunk)
	if #removed == 0 then
		return
	end

	local reasons = {}
	if #removed >= MIN_SILENT_DELETION_LINES and #added == 0 then
		reasons[#reasons + 1] = ("%d lines removed with no replacement"):format(#removed)
	end

	local removed_text = table.concat(removed, "\n")
	local added_text = table.concat(added, "\n")
	local lost = {}
	for _, entry in ipairs(ERROR_HANDLING) do
		if removed_text:match(entry.pattern) and not added_text:match(entry.pattern) then
			lost[#lost + 1] = entry.name
		end
	end
	if #lost > 0 then
		reasons[#reasons + 1] = "error handling removed: " .. table.concat(lost, ", ")
	end
	if #reasons == 0 then
		return
	end

	-- Pure deletions report new_count == 0 and sometimes new_start == 0; clamp
	-- so a finding never lands on line 0.
	local lnum = math.max(hunk.new_start or 1, 1)
	local end_lnum = nil
	if (hunk.new_count or 0) > 1 then
		end_lnum = lnum + hunk.new_count - 1
	end
	out[#out + 1] = {
		file = hunk.file,
		lnum = lnum,
		end_lnum = end_lnum,
		text = "Silent deletion: " .. table.concat(reasons, "; "),
		kind = "check",
		source = "deletion",
		severity = vim.diagnostic.severity.WARN,
	}
end

---Both hunk-based checks for one review round. Synchronous: git plumbing only.
---@param base string
---@param files ARChangedFile[]
---@return ARFinding[] findings, string|nil err
local function static_checks(base, files)
	local out = {}
	local errs = {}
	for _, f in ipairs(files) do
		if not f.generated and not f.whitespace_only then
			local hunks, err = git.hunks(base, f.path)
			if not hunks then
				errs[#errs + 1] = ("%s: %s"):format(f.path, err or "unknown error")
			else
				for _, hunk in ipairs(hunks) do
					scan_stubs(hunk, out)
					scan_deletions(hunk, out)
				end
			end
		end
	end
	return out, (#errs > 0 and table.concat(errs, "; ") or nil)
end

-- Check 1: LSP diagnostics ------------------------------------------------

local function diagnostic_text(d)
	local sev = d.severity == vim.diagnostic.severity.ERROR and "error" or "warning"
	local origin = d.source or ""
	if d.code and d.code ~= "" then
		origin = origin ~= "" and (origin .. " " .. tostring(d.code)) or tostring(d.code)
	end
	local msg = one_line(d.message)
	if origin ~= "" then
		return ("LSP %s: %s [%s]"):format(sev, msg, origin)
	end
	return ("LSP %s: %s"):format(sev, msg)
end

local function collect_diagnostics(entry, out)
	local ok, diags = pcall(vim.diagnostic.get, entry.buf, {
		severity = { vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN },
	})
	if not ok or not diags then
		return
	end
	for _, d in ipairs(diags) do
		local lnum = (d.lnum or 0) + 1
		local end_lnum = d.end_lnum and (d.end_lnum + 1) or nil
		if end_lnum == lnum then
			end_lnum = nil
		end
		out[#out + 1] = {
			file = entry.path,
			lnum = lnum,
			end_lnum = end_lnum,
			text = diagnostic_text(d),
			kind = "check",
			source = "lsp",
			severity = d.severity,
		}
	end
end

---Load every candidate file, wait (asynchronously, bounded) for diagnostics,
---then hand back findings. `cb` is always called exactly once.
---@param root string
---@param files ARChangedFile[]
---@param cb fun(findings: ARFinding[])
local function lsp_checks(root, files, cb)
	local entries = {}
	for _, f in ipairs(files) do
		if (f.status == "A" or f.status == "M") and not f.generated and #entries < MAX_LSP_FILES then
			local abs = root .. "/" .. f.path
			if vim.fn.filereadable(abs) == 1 then
				local existed = vim.fn.bufexists(abs) == 1
				local buf = vim.fn.bufadd(abs)
				local ok = pcall(vim.fn.bufload, buf)
				if ok and vim.api.nvim_buf_is_valid(buf) then
					entries[#entries + 1] = { buf = buf, path = f.path, temp = not existed }
				elseif not existed and vim.api.nvim_buf_is_valid(buf) then
					pcall(vim.api.nvim_buf_delete, buf, { force = true })
				end
			end
		end
	end

	if #entries == 0 then
		vim.schedule(function()
			cb({})
		end)
		return
	end

	local group = vim.api.nvim_create_augroup("AgentReviewChecks", { clear = true })
	local pending, by_buf = {}, {}
	local n_pending = 0
	local done = false

	for _, entry in ipairs(entries) do
		by_buf[entry.buf] = entry
		pending[entry.buf] = true
		n_pending = n_pending + 1
	end

	local finish, finish_scheduled

	local function schedule_finish()
		if finish_scheduled then
			return
		end
		finish_scheduled = true
		vim.defer_fn(function()
			finish()
		end, LSP_SETTLE_MS)
	end

	local function settle(buf)
		if pending[buf] then
			pending[buf] = nil
			n_pending = n_pending - 1
			if n_pending == 0 then
				schedule_finish()
			end
		end
	end

	finish = function()
		if done then
			return
		end
		done = true
		pcall(vim.api.nvim_del_augroup_by_id, group)

		local out = {}
		for _, entry in ipairs(entries) do
			if vim.api.nvim_buf_is_valid(entry.buf) then
				collect_diagnostics(entry, out)
			end
		end
		-- Clean up only what we created; a buffer the user already had stays.
		for _, entry in ipairs(entries) do
			if entry.temp and vim.api.nvim_buf_is_valid(entry.buf) then
				pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
			end
		end
		cb(out)
	end

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(ev)
			if by_buf[ev.buf] then
				settle(ev.buf)
			end
		end,
	})

	-- A late attach (server still starting) must extend the wait past the grace.
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(ev)
			local entry = by_buf[ev.buf]
			if entry then
				entry.attached = true
			end
		end,
	})

	-- Buffers that already carry diagnostics (the user had them open) are done.
	for _, entry in ipairs(entries) do
		if #vim.diagnostic.get(entry.buf) > 0 then
			settle(entry.buf)
		end
	end

	-- After the grace, anything without a client can never publish diagnostics.
	-- This is what keeps a repo with no LSP at all from waiting the full budget.
	vim.defer_fn(function()
		if done then
			return
		end
		for _, entry in ipairs(entries) do
			if pending[entry.buf] and not entry.attached and #vim.lsp.get_clients({ bufnr = entry.buf }) == 0 then
				settle(entry.buf)
			end
		end
	end, LSP_ATTACH_GRACE_MS)

	vim.defer_fn(function()
		finish()
	end, LSP_TIMEOUT_MS)
end

-- Public API --------------------------------------------------------------

---Run the whole machine pass against a snapshot ref.
---Asynchronous by necessity (LSP diagnostics); `cb` is called exactly once with
---either the findings or `nil, err`.
---@param base string|nil snapshot ref; defaults to the most recent one
---@param cb fun(findings: ARFinding[]|nil, err: string|nil)
function M.run(base, cb)
	if type(cb) ~= "function" then
		git.notify("checks.run() needs a callback", vim.log.levels.ERROR)
		return
	end

	if not base or base == "" then
		-- Shared resolver, so the machine pass cannot quietly check against a
		-- different baseline than the one the human is reviewing.
		local root = git.root()
		if root then
			state.load(root)
		end
		local berr
		base, berr = git.resolve_base(root and state.base() or nil)
		if not base then
			cb(nil, berr or "no snapshot to check against")
			return
		end
	end

	local root = git.root()
	if not root then
		cb(nil, "not inside a git repository")
		return
	end

	local files, err = git.changed_files(base)
	if not files then
		cb(nil, err or "could not list changed files")
		return
	end
	if #files == 0 then
		vim.schedule(function()
			cb({}, nil)
		end)
		return
	end

	local findings, static_err = static_checks(base, files)
	if static_err then
		git.notify("Some hunks could not be read: " .. static_err, vim.log.levels.WARN)
	end

	lsp_checks(root, files, function(lsp_findings)
		vim.list_extend(findings, lsp_findings)
		cb(sort_findings(findings), nil)
	end)
end

---Send findings to the quickfix list and open it. Quickfix is the shared result
---surface in this config (grug-far's `<leader>qf`, trouble's `<leader>xq`), so
---no bespoke list UI is invented here.
---@param findings ARFinding[]|nil
---@return integer count
function M.to_quickfix(findings)
	findings = findings or {}
	local root = git.root()
	local items = {}
	for _, f in ipairs(findings) do
		items[#items + 1] = {
			filename = root and (root .. "/" .. f.file) or f.file,
			lnum = f.lnum,
			end_lnum = f.end_lnum,
			col = 1,
			text = ("[%s] %s"):format(f.source or "check", f.text),
			type = f.severity == vim.diagnostic.severity.ERROR and "E" or "W",
		}
	end
	vim.fn.setqflist({}, " ", { title = "AgentReview checks", items = items })
	vim.cmd("copen")
	return #items
end

---Counts per source, for the summary notification.
local function summarize(findings)
	local counts, order = {}, { "lsp", "stub", "deletion" }
	for _, source in ipairs(order) do
		counts[source] = 0
	end
	for _, f in ipairs(findings) do
		counts[f.source] = (counts[f.source] or 0) + 1
	end
	local parts = {}
	for _, source in ipairs(order) do
		parts[#parts + 1] = ("%s %d"):format(source, counts[source])
	end
	return table.concat(parts, ", ")
end

function M.setup()
	if vim.g.vscode or require("config.pager").active then
		return
	end

	vim.api.nvim_create_user_command("AgentReviewCheck", function()
		M.run(nil, function(findings, err)
			if not findings then
				git.notify("Checks failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
				return
			end
			if #findings == 0 then
				git.notify("Automated checks found nothing")
				return
			end
			M.to_quickfix(findings)
			git.notify(("Automated checks: %d findings (%s)"):format(#findings, summarize(findings)))
		end)
	end, {
		desc = "Run automated checks over the agent's changes and fill the quickfix list",
	})
end

return M
