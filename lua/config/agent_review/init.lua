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
--- human ones when the prompt is built. Cleared whenever a new round is armed.
---@type ARFinding[]|nil
M._machine = nil

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
--- `cb(proceed)`. Asynchronous: vim.ui.select may be a picker.
---@param cb fun(proceed: boolean)
function M.guard_modified(cb)
	local dirty = modified_buffers()
	if #dirty == 0 then
		cb(true)
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
			cb(false)
			return
		end
		if choice == WRITE then
			for _, b in ipairs(dirty) do
				local ok, err = pcall(vim.api.nvim_buf_call, b.buf, function()
					vim.cmd("silent keepalt write")
				end)
				if not ok then
					notify(
						("Could not write %s: %s — snapshot aborted"):format(
							vim.fn.fnamemodify(b.name, ":~:."),
							tostring(err)
						),
						vim.log.levels.ERROR
					)
					cb(false)
					return
				end
			end
			notify(("Wrote %d buffer(s) into the baseline"):format(#dirty))
		else
			notify(("Snapshotting with %d unsaved buffer(s)"):format(#dirty), vim.log.levels.WARN)
		end
		cb(true)
	end)
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
--- then call `cb(proceed)`.
---@param cb fun(proceed: boolean)
function M.guard_verdicts(cb)
	local round = round_in_progress()
	if not round then
		cb(true)
		return
	end

	local KEEP = "Keep them (hunks the agent did not touch stay reviewed)"
	local DROP = "Discard them and start from scratch"
	local ABORT = "Abort"

	vim.ui.select({ KEEP, DROP, ABORT }, {
		prompt = ("%d verdict(s) recorded against %s"):format(round.reviewed, round.base),
	}, function(choice)
		if choice == nil or choice == ABORT then
			notify("Snapshot aborted: the current round is untouched", vim.log.levels.WARN)
			cb(false)
			return
		end
		if choice == DROP then
			local ok, err = state.reset()
			if not ok then
				notify("Could not clear the previous verdicts: " .. tostring(err), vim.log.levels.ERROR)
				cb(false)
				return
			end
			notify(("Discarded %d verdict(s)"):format(round.reviewed))
		else
			notify(("Keeping %d verdict(s) for the new round"):format(round.reviewed))
		end
		cb(true)
	end)
end

-- Actions ------------------------------------------------------------------

--- Arm a review round: snapshot the working tree, persist it as the base and
--- point gitsigns at it. Run this BEFORE the agent.
function M.snapshot()
	if not git.root() then
		notify("Not inside a git repository: nothing to snapshot", vim.log.levels.WARN)
		return
	end
	M.guard_modified(function(proceed)
		if not proceed then
			return
		end
		M.guard_verdicts(function(go)
			if not go then
				return
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
			local ok, serr = state.set_base(ref)
			if not ok then
				notify("Snapshot " .. ref .. " taken but not persisted: " .. tostring(serr), vim.log.levels.ERROR)
			end
			M._machine = nil
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
		notify("Machine checks unavailable (config.agent_review.checks did not load)", vim.log.levels.WARN)
		return
	end

	notify("Running machine checks against " .. ctx.base .. " …")
	local ran, rerr = pcall(checks.run, ctx.base, function(findings, cerr)
		if cerr then
			notify("Machine checks failed: " .. tostring(cerr), vim.log.levels.ERROR)
			return
		end
		findings = findings or {}
		local kept, dropped = filter_ignored(findings, config().ignore)
		M._machine = kept
		if #kept == 0 then
			notify("Machine pass: no findings" .. (dropped > 0 and (" (%d ignored)"):format(dropped) or ""))
			return
		end
		local qok, qerr = pcall(checks.to_quickfix, kept)
		if not qok then
			notify("Could not build the quickfix list: " .. tostring(qerr), vim.log.levels.WARN)
		end
		notify(
			("Machine pass: %d finding(s)%s — in the quickfix list, and in the next prompt"):format(
				#kept,
				dropped > 0 and (", %d ignored"):format(dropped) or ""
			)
		)
	end)
	if not ran then
		notify("Machine checks failed to start: " .. tostring(rerr), vim.log.levels.ERROR)
	end
end

--- Build the prompt out of the human verdicts plus the last machine pass.
function M.build_prompt()
	local hunks, err = review.all_hunks()
	if not hunks then
		notify(err, vim.log.levels.WARN)
		return
	end

	local cfg = config()
	local findings = state.findings(hunks)
	for _, f in ipairs(M._machine or {}) do
		findings[#findings + 1] = f
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
	review.reset_base()
	notify("Agent review reset: verdicts cleared, no base ref")
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
	-- setup() is reachable both from init.lua and from the lazy spec; the maps
	-- and commands below must be installed exactly once.
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
