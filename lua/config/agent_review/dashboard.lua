-- lua/config/agent_review/dashboard.lua
-- Orientation screen for the agent-review workflow (`<leader>vv`,
-- `:AgentReviewDashboard`).
--
-- This is what the human opens *first*, before reading a single diff. It answers
-- one question at a glance: of everything the agent touched, what is
-- load-bearing and what is noise I can skip? Hence:
--   * rows keep the risk order `git.changed_files()` returns -- never re-sorted
--     alphabetically, the ordering IS the feature;
--   * every row carries a classification summary of its hunks ("3 logic, 1
--     imports"), so a re-indent or a lockfile is visibly not worth opening;
--   * the summary line ("12 files, but only 4 carry logic") is the single most
--     valuable thing on the screen, so it is the picker title.
--
-- The row model is built by the pure function `M.build_rows(base)`; the picker
-- (and the quickfix fallback) are thin shells over it. That split is deliberate:
-- snacks.picker cannot be driven headlessly, so the model is where the logic
-- lives and where it can be tested.
--
-- Cost: hunks for every changed file are many git calls, so they are computed
-- exactly once per dashboard open and reused, and skipped entirely for
-- `generated` files (a lockfile's hunks are noise nobody will ever review).
--
-- Nothing throws: every entry point returns `nil, err` and announces failures
-- through the shared `git.notify`.

---@class ARDashboardRow
---@field path      string          -- repo-relative path
---@field file      ARChangedFile
---@field hunks     ARHunk[]        -- empty for generated files (skipped)
---@field skipped   boolean         -- hunks were not computed
---@field noise     boolean         -- whitespace_only or generated
---@field classes   table<string,integer>
---@field reviewed  integer
---@field total     integer
---@field lnum      integer         -- first unreviewed hunk, else 1
---@field text      string          -- rendered, aligned row
---@field cols      table[]         -- { text, highlight } chunks of `text`

---@class ARDashboardModel
---@field root    string
---@field base    string
---@field rows    ARDashboardRow[]
---@field summary string
---@field stats   table

local M = {}

local git = require("config.agent_review.git")
local state = require("config.agent_review.state")

-- Longest path still rendered in full; longer ones are shortened from the left.
local PATH_MAX = 60

-- Hunk classes that a human can safely skim past.
local NOISE_CLASSES = { whitespace = true, imports = true }

-- Deterministic tie-break for the per-file class summary (most alarming first).
local CLASS_ORDER = { logic = 1, comments = 2, imports = 3, whitespace = 4 }

local function pad_right(s, w)
	return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s)))
end

local function pad_left(s, w)
	return string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s))) .. s
end

local function shorten(path)
	if #path <= PATH_MAX then
		return path
	end
	return "…" .. path:sub(#path - PATH_MAX + 2)
end

-- "3 logic, 1 imports" -- only non-empty classes, worst class first.
local function class_summary(classes)
	local keys = {}
	for class in pairs(classes) do
		keys[#keys + 1] = class
	end
	table.sort(keys, function(a, b)
		if classes[a] ~= classes[b] then
			return classes[a] > classes[b]
		end
		return (CLASS_ORDER[a] or 9) < (CLASS_ORDER[b] or 9)
	end)
	local parts = {}
	for _, class in ipairs(keys) do
		parts[#parts + 1] = ("%d %s"):format(classes[class], class)
	end
	return table.concat(parts, ", ")
end

local function score_hl(score)
	if score >= 5 then
		return "DiagnosticError"
	elseif score >= 2 then
		return "DiagnosticWarn"
	elseif score < 0 then
		return "Comment"
	end
	return "Normal"
end

local STATUS_HL = { A = "Added", M = "Changed", D = "Removed" }

-- Render the aligned columns of every row. Widths are measured across the whole
-- set so the screen reads as a table; each column is emitted as its own
-- { text, highlight } chunk for the picker formatter, and `text` is their
-- concatenation (used by the quickfix fallback and by tests).
local function render(rows)
	local w = { score = 0, path = 0, churn = 0, class = 0, prog = 0 }
	for _, row in ipairs(rows) do
		w.score = math.max(w.score, #row._score)
		w.path = math.max(w.path, vim.fn.strdisplaywidth(row._path))
		w.churn = math.max(w.churn, #row._churn)
		w.class = math.max(w.class, vim.fn.strdisplaywidth(row._class))
		w.prog = math.max(w.prog, #row._prog)
	end
	for _, row in ipairs(rows) do
		local cols = {
			{ pad_left(row._score, w.score), score_hl(row.file.score) },
			{ " ", "Normal" },
			{ row.file.status, STATUS_HL[row.file.status] or "Normal" },
			{ " ", "Normal" },
			{ pad_right(row._path, w.path), row.noise and "Comment" or "SnacksPickerFile" },
			{ "  " .. string.rep(" ", math.max(0, w.churn - #row._churn)) .. row._added, "Added" },
			{ "/", "Normal" },
			{ row._removed, "Removed" },
			{ "  ", "Normal" },
			{ pad_right(row._class, w.class), row.noise and "Comment" or "Normal" },
			{ "  ", "Normal" },
			{
				pad_left(row._prog, w.prog),
				row.total > 0 and row.reviewed == row.total and "DiagnosticOk" or "Comment",
			},
		}
		if row._noise ~= "" then
			cols[#cols + 1] = { "  " .. row._noise, "Comment" }
		end
		local text = {}
		for _, col in ipairs(cols) do
			text[#text + 1] = col[1]
		end
		row.cols = cols
		row.text = table.concat(text)
	end
	return rows
end

--- Build the dashboard model: one row per changed file, in the risk order
--- `git.changed_files()` produced, plus the headline summary.
--- Pure with respect to the UI -- no window is touched -- so it is directly
--- callable (and testable) without a picker.
---@param base? string snapshot ref; defaults to the stored base, then git.latest()
---@return ARDashboardModel|nil model, string|nil err
function M.build_rows(base)
	local root = git.root()
	if not root then
		return nil, "not inside a git repository"
	end
	state.load(root)
	base = base or state.base() or git.latest()
	if not base or base == "" then
		return nil, "no agent-review snapshot yet"
	end

	local files, err = git.changed_files(base)
	if not files then
		return nil, err
	end

	local stats = {
		files = #files,
		hunks = 0,
		reviewed = 0,
		logic = 0,
		noise = 0,
		comments = 0,
		skipped = 0,
		noise_files = 0,
	}

	local rows = {}
	for _, file in ipairs(files) do
		-- A lockfile's hunks are noise you will never review: don't pay the git
		-- calls for them.
		local skipped = file.generated
		local hunks = {}
		if not skipped then
			hunks = git.hunks(base, file.path) or {}
		end

		local classes = {}
		for _, hunk in ipairs(hunks) do
			classes[hunk.class] = (classes[hunk.class] or 0) + 1
			if hunk.class == "logic" then
				stats.logic = stats.logic + 1
			elseif hunk.class == "comments" then
				stats.comments = stats.comments + 1
			end
			if NOISE_CLASSES[hunk.class] then
				stats.noise = stats.noise + 1
			end
		end

		local reviewed, total = state.progress(hunks)
		-- Where confirm lands: the first thing still worth looking at.
		local lnum = 1
		for _, hunk in ipairs(hunks) do
			if not state.get_verdict(hunk.id) then
				lnum = math.max(hunk.new_start or 1, 1)
				break
			end
		end

		local noise = file.whitespace_only or file.generated
		local csum = class_summary(classes)
		local row = {
			path = file.path,
			file = file,
			hunks = hunks,
			skipped = skipped,
			noise = noise,
			classes = classes,
			reviewed = reviewed,
			total = total,
			lnum = lnum,
			_score = tostring(file.score),
			_path = shorten(file.path),
			_added = "+" .. tostring(file.added),
			_removed = "-" .. tostring(file.removed),
			_class = skipped and "generated (skipped)" or (csum ~= "" and csum or "-"),
			_prog = total > 0 and ("%d/%d"):format(reviewed, total) or "-",
			_noise = file.generated and "[noise: generated]" or (file.whitespace_only and "[noise: whitespace]" or ""),
		}
		row._churn = row._added .. "/" .. row._removed
		rows[#rows + 1] = row

		stats.hunks = stats.hunks + total
		stats.reviewed = stats.reviewed + reviewed
		if skipped then
			stats.skipped = stats.skipped + 1
		end
		if noise then
			stats.noise_files = stats.noise_files + 1
		end
	end

	render(rows)

	local parts = {
		("%d file%s"):format(stats.files, stats.files == 1 and "" or "s"),
		("%d hunk%s"):format(stats.hunks, stats.hunks == 1 and "" or "s"),
		("%d/%d reviewed"):format(stats.reviewed, stats.hunks),
	}
	local breakdown = {
		("%d logic"):format(stats.logic),
		("%d noise (whitespace/imports)"):format(stats.noise),
	}
	if stats.comments > 0 then
		breakdown[#breakdown + 1] = ("%d comments"):format(stats.comments)
	end
	if stats.skipped > 0 then
		breakdown[#breakdown + 1] = ("%d generated skipped"):format(stats.skipped)
	end
	local summary = ("Agent review: %s — %s"):format(table.concat(parts, ", "), table.concat(breakdown, ", "))

	return { root = root, base = base, rows = rows, summary = summary, stats = stats }, nil
end

-- snacks.picker, or nil when the plugin isn't loaded (VS Code, a stripped pager
-- profile, a broken install). Never throws.
local function snacks_picker()
	local ok, snacks = pcall(require, "snacks")
	if not ok or type(snacks) ~= "table" then
		return nil
	end
	local got, picker = pcall(function()
		return snacks.picker
	end)
	if not got or type(picker) ~= "table" or type(picker.pick) ~= "function" then
		return nil
	end
	return picker
end

-- Same routing as the repo-wide `open_in_tab` confirm action in
-- lua/plugins/snacks.lua: file navigation always goes through
-- config.editor.open_file_in_tab so the tab-reuse behaviour holds. The one
-- addition is deleted files: opening a tab on a path the agent removed would
-- just show an empty buffer, so say so instead.
local function open_row(picker, item)
	picker:close()
	if not item then
		return
	end
	if item.status == "D" then
		git.notify(item.path .. " was deleted by the agent — nothing to open", vim.log.levels.WARN)
		return
	end
	require("config.editor").open_file_in_tab(item.file, { lnum = item.pos and item.pos[1] or 1, col = 1 })
end

-- Fallback list UI when snacks.picker is unavailable: the quickfix list, which
-- is how the rest of the config surfaces sets of locations.
local function to_quickfix(model)
	local items = {}
	for _, row in ipairs(model.rows) do
		items[#items + 1] = {
			filename = model.root .. "/" .. row.path,
			lnum = row.lnum,
			col = 1,
			text = row.text,
			valid = row.file.status ~= "D" and 1 or 0,
		}
	end
	vim.fn.setqflist({}, " ", { title = model.summary, items = items })
	vim.cmd("copen")
	git.notify(model.summary)
end

--- Open the dashboard.
---@param opts? { base?: string }
---@return boolean ok, string|nil err
function M.open(opts)
	opts = opts or {}
	local model, err = M.build_rows(opts.base)
	if not model then
		git.notify("Dashboard unavailable: " .. (err or "unknown error"), vim.log.levels.WARN)
		return false, err
	end
	if #model.rows == 0 then
		-- A normal, friendly outcome: the agent changed nothing worth reviewing.
		git.notify("No changes since the snapshot (" .. model.base .. ")")
		return true, nil
	end

	local picker = snacks_picker()
	if not picker then
		to_quickfix(model)
		return true, nil
	end

	local items = {}
	for i, row in ipairs(model.rows) do
		items[#items + 1] = {
			idx = i, -- rows are risk-ranked; `sort` below keeps that order
			path = row.path,
			status = row.file.status,
			file = model.root .. "/" .. row.path,
			pos = { row.lnum, 0 },
			text = row.path .. " " .. row._class,
			cols = row.cols,
		}
	end

	local ok, perr = pcall(picker.pick, {
		source = "agent_review_dashboard",
		title = model.summary,
		items = items,
		sort = function(a, b)
			return a.idx < b.idx
		end,
		format = function(item)
			return item.cols
		end,
		confirm = open_row,
	})
	if not ok then
		git.notify(
			"snacks.picker failed (" .. tostring(perr) .. "); falling back to the quickfix list",
			vim.log.levels.WARN
		)
		to_quickfix(model)
	end
	return true, nil
end

function M.setup()
	if vim.g.vscode or require("config.pager").active then
		return
	end

	vim.api.nvim_create_user_command("AgentReviewDashboard", function(o)
		local base = vim.trim(o.args or "")
		M.open({ base = base ~= "" and base or nil })
	end, {
		nargs = "?",
		desc = "Agent review: risk-ranked dashboard of what the agent changed",
	})

	vim.keymap.set("n", "<leader>vv", function()
		M.open()
	end, { desc = "Agent review: dashboard" })
end

return M
