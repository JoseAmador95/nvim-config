-- lua/config/agent_review/init.lua
-- Entrypoint and orchestrator of the agent-review workflow: review exactly what
-- a coding agent changed, hunk by hunk, then hand it a prompt with the fixes.
--
-- The round is:
--   <leader>vs   arm it     -- snapshot the tree BEFORE letting the agent run
--   (run the agent)
--   <leader>vv   dashboard  -- risk-ranked view of what it touched  (dashboard.lua)
--   ]v / [v      walk the unreviewed hunks                          (review.lua)
--   <leader>va / <leader>vx / <leader>vc   accept / reject / comment
--   <leader>vf   machine pass -- linters/tests over the same diff   (checks.lua)
--   <leader>vy   build the prompt out of everything above           (prompt.lua)
--
-- This module owns only <leader>vs, <leader>vf and <leader>vy; the other maps
-- belong to the siblings and are registered by their own setup().
--
-- Two guards live here because they are the whole point of arming a round:
--
--   * MODIFIED BUFFERS. Both target agents edit files on disk from outside
--     Neovim. An unsaved buffer at snapshot time means the baseline does not
--     contain that work and the next :write will clobber (or E211/W11-warn
--     about) the agent's edit. So <leader>vs refuses to snapshot silently: it
--     lists the dirty buffers and asks to write them, snapshot anyway, or abort.
--
--   * PREVIOUS VERDICTS. Verdicts are keyed by hunk content hash, so carrying
--     them into a new round is meaningful (an untouched hunk keeps its verdict,
--     a rewritten one reverts to unreviewed). Keeping them is therefore offered
--     as a first-class choice instead of being silently wiped.
--
-- Both guards only ASK. Every irreversible step (writing buffers, dropping
-- verdicts) happens in snapshot(), after the last cancellable prompt and after
-- git.snapshot() succeeded -- otherwise Esc at the second prompt would leave the
-- buffers already written, and a snapshot that fails after state.reset() would
-- have destroyed the round for nothing.
--
-- Configuration comes from ~/.nvim-local.lua (see lua/config/local_config.lua):
--   agent_review = { clipboard = true, include_diff = false, ignore = {} }
--
-- Nothing throws and nothing fails silently: every failure is reported through
-- the shared git.notify.

local M = {}

local git = require("config.agent_review.git")
local state = require("config.agent_review.state")
local prompt = require("config.agent_review.prompt")
local review = require("config.agent_review.review")
local dashboard = require("config.agent_review.dashboard")

local notify = git.notify

--- Findings produced by the last machine pass (<leader>vf), appended to the
--- human ones when the prompt is built. Cleared whenever a new round is armed,
--- and whenever a pass fails: shipping the previous run's findings while telling
--- the user the pass failed is worse than shipping none.
---@type ARFinding[]|nil
M._machine = nil

--- What the last machine pass looked at: the base it ran against, when it ran,
--- and a per-file fingerprint of the diff at that moment. Check findings carry
--- absolute line numbers, so twenty minutes of editing makes them point at the
--- wrong lines; this is what lets build_prompt() notice instead of emitting them.
---@type { base: string, at: integer, files: table<string, string>|nil }|nil
M._machine_meta = nil

--- Per-file, order-independent fingerprint of a round's hunks (their content
--- hashes). Per file, not global, so editing one file does not invalidate the
--- findings of every other one.
---@param hunks ARHunk[]|nil
---@return table<string, string>|nil
local function file_signatures(hunks)
	if not hunks then
		return nil
	end
	local ids = {}
	for _, h in ipairs(hunks) do
		ids[h.file] = ids[h.file] or {}
		table.insert(ids[h.file], h.id)
	end
	local out = {}
	for file, list in pairs(ids) do
		table.sort(list)
		out[file] = vim.fn.sha256(table.concat(list, "\n"))
	end
	return out
end

local function ago(ts)
	local secs = math.max(os.time() - (ts or 0), 0)
	if secs < 60 then
		return ("%ds ago"):format(secs)
	end
	return ("%d min ago"):format(math.floor(secs / 60))
end

-- Config -------------------------------------------------------------------

---@return { clipboard: boolean, include_diff: boolean, ignore: string[] }
local function config()
	local cfg = require("config.local_config").get("agent_review", {}) or {}
	return {
		clipboard = cfg.clipboard ~= false,
		include_diff = cfg.include_diff == true,
		ignore = cfg.ignore or {},
	}
end

-- `ignore` entries are Lua patterns matched against the repo-relative path, the
-- same flavour git.lua already uses for its generated-file list. A malformed
-- pattern must not break the prompt, hence the pcall.
local function ignored(path, patterns)
	for _, pat in ipairs(patterns or {}) do
		local ok, hit = pcall(string.match, path or "", pat)
		if ok and hit then
			return true
		end
	end
	return false
end

---@param findings ARFinding[]
---@param patterns string[]
---@return ARFinding[] kept, integer dropped
local function filter_ignored(findings, patterns)
	if not patterns or #patterns == 0 then
		return findings, 0
	end
	local kept, dropped = {}, 0
	for _, f in ipairs(findings) do
		if ignored(f.file, patterns) then
			dropped = dropped + 1
		else
			kept[#kept + 1] = f
		end
	end
	return kept, dropped
end

-- Snapshot guards ----------------------------------------------------------

--- Loaded, file-backed buffers with unsaved changes.
---@return { buf: integer, name: string }[]
local function modified_buffers()
	local out = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].modified then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" then
				out[#out + 1] = { buf = buf, name = name }
			end
		end
	end
	return out
end

--- Ask what to do about unsaved buffers before snapshotting, then call
--- `cb(plan)` with `nil` when the user aborted. Asynchronous: vim.ui.select may
--- be a picker.
---
--- It only ASKS. Writing the buffers is irreversible and there is another
--- abortable prompt after this one, so the writing itself happens in snapshot(),
--- once every question has been answered.
---@param cb fun(plan: { write: boolean, buffers: { buf: integer, name: string }[] }|nil)
function M.guard_modified(cb)
	local dirty = modified_buffers()
	if #dirty == 0 then
		cb({ write = false, buffers = {} })
		return
	end

	local names = {}
	for _, b in ipairs(dirty) do
		names[#names + 1] = vim.fn.fnamemodify(b.name, ":~:.")
	end

	local WRITE = "Write them, then snapshot"
	local ANYWAY = "Snapshot anyway (their unsaved changes stay out of the baseline)"
	local ABORT = "Abort"

	vim.ui.select({ WRITE, ANYWAY, ABORT }, {
		prompt = ("%d unsaved buffer(s): %s"):format(#dirty, table.concat(names, ", ")),
	}, function(choice)
		if choice == nil or choice == ABORT then
			notify("Snapshot aborted: " .. #dirty .. " buffer(s) still unsaved", vim.log.levels.WARN)
			cb(nil)
			return
		end
		cb({ write = choice == WRITE, buffers = dirty })
	end)
end

--- Write the buffers the user agreed to write. Reports how many were already on
--- disk when one fails: "could not write buffer 3" without that is a lie by
--- omission, buffers 1 and 2 are already changed.
---@param buffers { buf: integer, name: string }[]
---@return integer written, string|nil err
local function write_buffers(buffers)
	local written = 0
	for _, b in ipairs(buffers) do
		local ok, err = pcall(vim.api.nvim_buf_call, b.buf, function()
			vim.cmd("silent keepalt write")
		end)
		if not ok then
			return written, ("could not write %s: %s"):format(vim.fn.fnamemodify(b.name, ":~:."), tostring(err))
		end
		written = written + 1
	end
	return written, nil
end

--- Verdicts already recorded for the round now in progress, or nil when there
--- is nothing to lose.
---@return { base: string, reviewed: integer }|nil
local function round_in_progress()
	local root = git.root()
	if not root then
		return nil
	end
	state.load(root)
	local base = state.base()
	if not base or base == "" then
		return nil
	end
	local reviewed = state.progress(review.all_hunks() or {})
	if reviewed == 0 then
		return nil
	end
	return { base = base, reviewed = reviewed }
end

--- Ask whether the current round's verdicts should survive the new snapshot,
--- then call `cb(plan)` with `nil` when the user aborted.
---
--- Like guard_modified, it only ASKS: state.reset() runs in snapshot(), after
--- git.snapshot() succeeded. Wiping the verdicts first and then failing to take
--- the snapshot (unborn HEAD, disk full) destroyed the round for nothing.
---@param cb fun(plan: { drop: boolean, reviewed: integer }|nil)
function M.guard_verdicts(cb)
	local round = round_in_progress()
	if not round then
		cb({ drop = false, reviewed = 0 })
		return
	end

	local KEEP = "Keep them (hunks the agent did not touch stay reviewed)"
	local DROP = "Discard them and start from scratch"
	local ABORT = "Abort"

	vim.ui.select({ KEEP, DROP, ABORT }, {
		prompt = ("%d verdict(s) recorded against %s"):format(round.reviewed, round.base),
	}, function(choice)
		if choice == nil or choice == ABORT then
			notify("Snapshot aborted: nothing was written and no verdict was touched", vim.log.levels.WARN)
			cb(nil)
			return
		end
		cb({ drop = choice == DROP, reviewed = round.reviewed })
	end)
end

-- Actions ------------------------------------------------------------------

--- Arm a review round: snapshot the working tree, persist it as the base and
--- point gitsigns at it. Run this BEFORE the agent.
---
--- Ordering rule: every abortable question first, THEN the irreversible work,
--- and each destructive step only once the operation can still succeed. Esc at
--- any prompt therefore really does leave the tree and the round untouched.
function M.snapshot()
	if not git.root() then
		notify("Not inside a git repository: nothing to snapshot", vim.log.levels.WARN)
		return
	end
	M.guard_modified(function(dirty)
		if not dirty then
			return
		end
		M.guard_verdicts(function(verdicts)
			if not verdicts then
				return
			end
			-- ---- no more questions; from here things actually change ----

			if dirty.write then
				local written, werr = write_buffers(dirty.buffers)
				if werr then
					notify(
						("%s — snapshot aborted (%d of %d buffer(s) were already written to disk)"):format(
							werr,
							written,
							#dirty.buffers
						),
						vim.log.levels.ERROR
					)
					return
				end
				notify(("Wrote %d buffer(s) to disk"):format(written))
			elseif #dirty.buffers > 0 then
				notify(("Snapshotting with %d unsaved buffer(s)"):format(#dirty.buffers), vim.log.levels.WARN)
			end

			local ref, err = git.snapshot()
			if not ref then
				notify("Snapshot failed: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			local root = git.root()
			if root then
				state.load(root)
			end

			-- The snapshot exists: now the destructive half is safe to run.
			if verdicts.drop then
				local ok, rerr = state.reset()
				if not ok then
					notify(
						"Snapshot taken, but the previous verdicts could not be cleared: " .. tostring(rerr),
						vim.log.levels.ERROR
					)
				else
					notify(("Discarded %d verdict(s)"):format(verdicts.reviewed))
				end
			elseif verdicts.reviewed > 0 then
				-- Still diffing against the OLD base here, so this drops verdicts
				-- whose hunk vanished from the round that is ending, and keeps the
				-- ones that carry over by content hash.
				local hunks = review.all_hunks()
				local removed = hunks and state.prune(hunks) or 0
				-- Counted after the prune: `reviewed` only ever counted the verdicts
				-- with a live hunk, so subtracting the orphans from it would lie.
				local kept = hunks and select(1, state.progress(hunks)) or verdicts.reviewed
				notify(
					("Keeping %d verdict(s) for the new round%s"):format(
						kept,
						removed > 0 and (", %d orphaned one(s) dropped"):format(removed) or ""
					)
				)
			end

			local ok, serr = state.set_base(ref)
			if not ok then
				notify("Snapshot " .. ref .. " taken but not persisted: " .. tostring(serr), vim.log.levels.ERROR)
			end
			M._machine = nil
			M._machine_meta = nil
			review.set_base_to_snapshot(ref)
			notify("Review armed against " .. ref .. " — run the agent, then <leader>vv")
		end)
	end)
end

--- Machine pass: run the automated checks over the same diff and drop their
--- findings in the quickfix list (and in the prompt).
function M.machine_pass()
	local ctx, err = review.context()
	if not ctx then
		notify(err, vim.log.levels.WARN)
		return
	end
	-- Lazily loaded and pcall'd: an absent (or broken) checks module must degrade
	-- to "machine pass unavailable", never to a broken workflow.
	local ok, checks = pcall(require, "config.agent_review.checks")
	if not ok or type(checks) ~= "table" or type(checks.run) ~= "function" then
		M._machine, M._machine_meta = nil, nil
		notify("Machine checks unavailable (config.agent_review.checks did not load)", vim.log.levels.WARN)
		return
	end

	notify("Running machine checks against " .. ctx.base .. " …")
	local ran, rerr = pcall(checks.run, ctx.base, function(findings, cerr, stats)
		-- A pass that silently inspected a fraction of the change set must not read
		-- like a clean bill of health, so whatever the caps cut is appended to every
		-- outcome below -- especially "no findings", which is the dangerous one.
		local partial = ""
		if type(checks.describe_stats) == "function" then
			local dok, desc = pcall(checks.describe_stats, stats)
			if dok and desc and desc ~= "" then
				partial = " — " .. desc
			end
		end
		local level = partial ~= "" and vim.log.levels.WARN or nil
		if cerr then
			-- Do NOT keep the previous run's findings: they would ship in the next
			-- prompt while the user was told this pass failed.
			M._machine, M._machine_meta = nil, nil
			notify("Machine checks failed: " .. tostring(cerr), vim.log.levels.ERROR)
			return
		end
		findings = findings or {}
		local kept, dropped = filter_ignored(findings, config().ignore)
		M._machine = kept
		-- Record what the pass looked at, so a later prompt can tell whether these
		-- line numbers still describe the file.
		M._machine_meta = {
			base = ctx.base,
			at = os.time(),
			files = file_signatures(review.all_hunks()),
		}
		if #kept == 0 then
			notify(
				"Machine pass: no findings" .. (dropped > 0 and (" (%d ignored)"):format(dropped) or "") .. partial,
				level
			)
			return
		end
		local qok, qerr = pcall(checks.to_quickfix, kept)
		if not qok then
			notify("Could not build the quickfix list: " .. tostring(qerr), vim.log.levels.WARN)
		end
		notify(
			("Machine pass: %d finding(s)%s — in the quickfix list, and in the next prompt%s"):format(
				#kept,
				dropped > 0 and (", %d ignored"):format(dropped) or "",
				partial
			),
			level
		)
	end)
	if not ran then
		M._machine, M._machine_meta = nil, nil
		notify("Machine checks failed to start: " .. tostring(rerr), vim.log.levels.ERROR)
	end
end

--- Keep only the machine findings that still describe the current tree.
--- Check findings carry absolute line numbers, so once a file's diff moved they
--- point at the wrong lines and must not be shipped as if they were fresh.
---@param machine ARFinding[]
---@param base string the base this prompt is being built against
---@param hunks ARHunk[] the current round's hunks
---@return ARFinding[] kept, integer stale, string|nil why
local function fresh_machine(machine, base, hunks)
	local meta = M._machine_meta
	if not meta then
		return {}, #machine, "the pass did not record what it looked at"
	end
	if meta.base ~= base then
		return {}, #machine, ("they were computed against %s, this prompt is against %s"):format(meta.base, base)
	end
	if not meta.files then
		return {}, #machine, ("the diff at the time of the pass (%s) could not be fingerprinted"):format(ago(meta.at))
	end
	local now = file_signatures(hunks) or {}
	local kept, stale = {}, 0
	for _, f in ipairs(machine) do
		if now[f.file] == meta.files[f.file] then
			kept[#kept + 1] = f
		else
			stale = stale + 1
		end
	end
	if stale == 0 then
		return kept, 0, nil
	end
	return kept,
		stale,
		("those files changed since the pass ran %s, so their line numbers are stale"):format(ago(meta.at))
end

--- Build the prompt out of the human verdicts plus the last machine pass.
function M.build_prompt()
	local ctx, cerr = review.context()
	if not ctx then
		notify(cerr, vim.log.levels.WARN)
		return
	end
	local hunks, err = review.all_hunks()
	if not hunks then
		notify(err, vim.log.levels.WARN)
		return
	end

	local cfg = config()
	local findings = state.findings(hunks)
	local machine = M._machine or {}
	if #machine > 0 then
		local kept, stale, why = fresh_machine(machine, ctx.base, hunks)
		for _, f in ipairs(kept) do
			findings[#findings + 1] = f
		end
		if stale > 0 then
			notify(
				("Leaving %d of %d machine finding(s) out of the prompt: %s — re-run <leader>vf"):format(
					stale,
					#machine,
					why
				),
				vim.log.levels.WARN
			)
		end
	end
	local dropped
	findings, dropped = filter_ignored(findings, cfg.ignore)

	if #findings == 0 then
		-- Never open an empty buffer: say why there is nothing to send.
		local why = dropped > 0 and (" (%d finding(s) ignored by config)"):format(dropped)
			or ": reject or comment some hunks (<leader>vx / <leader>vc), or run the machine pass (<leader>vf)"
		notify("No findings to turn into a prompt" .. why)
		return
	end

	local text = prompt.render(findings, { include_diff = cfg.include_diff })
	if not text then
		notify("The prompt renderer produced nothing", vim.log.levels.ERROR)
		return
	end
	-- Keep :AgentReviewPrompt able to re-render the same set.
	prompt._pending = findings
	prompt.present(text, { clipboard = cfg.clipboard })
end

--- Drop every verdict and the base ref, and put gitsigns back on the index.
function M.reset()
	local root = git.root()
	if not root then
		notify("Not inside a git repository: nothing to reset", vim.log.levels.WARN)
		return
	end
	state.load(root)
	local ok, err = state.reset()
	if not ok then
		notify("Could not reset the review state: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	M._machine = nil
	M._machine_meta = nil
	-- Every open buffer is still painted with the verdicts that were just
	-- cleared, not only the current one. Clearing them is what makes the message
	-- below true.
	local buffers = review.clear_all_signs()
	review.reset_base()
	notify(("Agent review reset: verdicts cleared, no base ref, marks removed from %d buffer(s)"):format(buffers))
end

-- Thin delegates, so a single module is enough for menus and mappings.
function M.dashboard()
	return dashboard.open()
end

function M.next_hunk()
	return review.goto_next()
end

function M.prev_hunk()
	return review.goto_prev()
end

function M.accept()
	return review.accept()
end

function M.reject()
	return review.reject()
end

function M.comment()
	return review.comment()
end

-- Setup --------------------------------------------------------------------

local did_setup = false

function M.setup()
	if vim.g.vscode or require("config.pager").active then
		return
	end
	-- Guard against a double require: the maps and commands below must be
	-- installed exactly once.
	if did_setup then
		return
	end
	did_setup = true

	review.setup()
	prompt.setup()
	dashboard.setup()
	-- The machine-pass module is optional (it may simply not be installed);
	-- when it is there, let it register :AgentReviewCheck.
	local ok, checks = pcall(require, "config.agent_review.checks")
	if ok and type(checks) == "table" and type(checks.setup) == "function" then
		pcall(checks.setup)
	end

	vim.api.nvim_create_user_command("AgentReviewSnapshot", function()
		M.snapshot()
	end, { desc = "Agent review: snapshot the tree as the review baseline" })

	vim.api.nvim_create_user_command("AgentReviewReset", function()
		M.reset()
	end, { desc = "Agent review: clear every verdict and the base ref" })

	-- prompt.setup() above registered an :AgentReviewPrompt that only re-renders
	-- the last finding set. Override it so the command and <leader>vy do the same
	-- thing: an asymmetry here reads as "no findings" on a round that has plenty.
	vim.api.nvim_create_user_command("AgentReviewPrompt", function()
		M.build_prompt()
	end, { desc = "Agent review: build the prompt for the agent" })

	local maps = {
		{ "<leader>vs", M.snapshot, "Agent review: snapshot (arm the review)" },
		{ "<leader>vf", M.machine_pass, "Agent review: machine pass (checks -> quickfix)" },
		{ "<leader>vy", M.build_prompt, "Agent review: build the prompt for the agent" },
	}
	for _, m in ipairs(maps) do
		vim.keymap.set("n", m[1], function()
			m[2]()
		end, { desc = m[3] })
	end
end

return M
