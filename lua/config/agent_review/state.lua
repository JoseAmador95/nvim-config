-- lua/config/agent_review/state.lua
-- Persistent verdict store for the agent-review workflow.
--
-- The human walks an agent's changes hunk by hunk and marks each one
-- accept / reject / comment. Verdicts live here and survive restarts.
--
-- The central property: a verdict is keyed by the hunk's CONTENT HASH
-- (`ARHunk.id`), never by file+line. Therefore, on the next round:
--   * a hunk the agent rewrote hashes differently -> it silently reverts to
--     unreviewed and the human sees it again;
--   * a hunk the agent left alone keeps its hash -> it keeps its verdict, even
--     if it drifted to another line number.
-- Never mix position into the key; that would defeat the whole design.
--
-- Storage: stdpath("state")/agent-review/<sha256(root):16>/state.json
-- The plain repo root is stored inside the file so the directory is
-- human-debuggable. Writes are atomic (temp file in the same directory, fsync,
-- then rename) AND validated: a short write (ENOSPC) or a failed fsync aborts
-- the save instead of renaming truncated JSON over good verdicts.
--
-- Two Neovim instances in the same repo (one per tmux/zellij pane) share this
-- one file, so "last writer wins" would silently drop a pane's verdicts. Both
-- the read and the write path therefore stat the file:
--   * load() reloads when the file changed underneath and MERGES by hunk id
--     (verdicts are independent keys; the newer `ts` wins on a collision);
--   * save() detects that the file moved since we loaded it, merges the same
--     way before writing, and REFUSES to write when the on-disk file cannot be
--     read or parsed. Nothing is ever lost without a message.
--
-- Corrupt JSON degrades to an empty state with a warning that carries the real
-- decode error, after copying the file aside (state.json.corrupt-<stamp>): it
-- never throws and never wipes the file behind the user's back. A file written
-- by a NEWER version of this module is refused, not downgraded.
--
-- This module deliberately knows nothing about git: it is fed plain tables.
--
---@class ARHunk
---@field file      string   -- relative to repo root
---@field new_start integer
---@field new_count integer
---@field class     "whitespace"|"imports"|"comments"|"logic"
---@field id        string   -- stable content hash; THE key
---@field lines     string[]
--
---@class ARVerdict
---@field verdict "accept"|"reject"|"comment"
---@field text    string|nil
---@field ts      integer
--
---@class ARFinding
---@field file     string
---@field lnum     integer
---@field end_lnum integer|nil
---@field text     string
---@field kind     "reject"|"comment"|"check"
---@field source   string|nil
---@field diff     string|nil

local M = {}

local TITLE = "AgentReview"
local VERSION = 1
local KEY_LEN = 16

local VERDICTS = { accept = true, reject = true, comment = true }

-- Fallback finding text when the user recorded a verdict without a comment.
local DEFAULT_TEXT = {
	reject = "Rejected by reviewer.",
	comment = "Reviewer comment.",
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

-- Paths -------------------------------------------------------------------

---Absolute, trailing-slash-free repo root.
--- `fnamemodify(..., ":p")` only: `expand()` would also perform $VAR, wildcard
--- and backtick expansion, so a root that happens to contain one of those would
--- hash to a different key and its verdicts would land in another store.
local function normalize(root)
	local abs = vim.fn.fnamemodify(root, ":p")
	return (abs:gsub("[\\/]+$", ""))
end

local function repo_key(root)
	return vim.fn.sha256(root):sub(1, KEY_LEN)
end

local function state_dir(root)
	return table.concat({ vim.fn.stdpath("state"), "agent-review", repo_key(root) }, "/")
end

local function state_file(root)
	return state_dir(root) .. "/state.json"
end

-- State -------------------------------------------------------------------

local cache = {} -- normalized root -> state table
local stamps = {} -- normalized root -> file stamp seen when that state was read
local reported = {} -- normalized root -> last refusal reported, so it is said once
local current = nil -- normalized root of the most recent load()

local function empty_state(root)
	return { version = VERSION, root = root, base = nil, verdicts = {} }
end

---Identity of the file on disk. `false` means "not there".
--- The inode is part of it on purpose: every save renames a fresh temp file over
--- the target, so a rewrite changes the inode even when mtime granularity (1 s on
--- some filesystems) and size would not give it away.
local function stamp_of(path)
	local st = vim.uv.fs_stat(path)
	if not st then
		return false
	end
	return { ino = st.ino, size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec }
end

local function same_stamp(a, b)
	if a == false and b == false then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	return a.ino == b.ino and a.size == b.size and a.sec == b.sec and a.nsec == b.nsec
end

---Read the whole file. Returns nil, err (absent files are not an error: nil, nil).
local function read_file(path)
	if not vim.uv.fs_stat(path) then
		return nil, nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, tostring(lines)
	end
	return table.concat(lines, "\n"), nil
end

---Copy a file that failed to parse aside before anything can overwrite it.
---@return string|nil backup
local function back_up(path)
	local backup = ("%s.corrupt-%s"):format(path, os.date("%Y%m%d-%H%M%S"))
	local ok = vim.uv.fs_copyfile(path, backup)
	return ok and backup or nil
end

---Turn raw file contents into a state table, repairing anything unexpected.
--- Returns nil, err only when the file must NOT be touched (a newer format).
---@return table|nil state, string|nil err
local function parse(contents, root, path)
	local ok, decoded = pcall(vim.json.decode, contents)
	if not ok or type(decoded) ~= "table" then
		local backup = back_up(path)
		notify(
			("Unreadable review state at %s: %s. Starting empty%s."):format(
				path,
				tostring(decoded),
				backup and (" — the old file was copied to " .. backup) or " (no backup could be made)"
			),
			vim.log.levels.WARN
		)
		return empty_state(root), nil
	end

	-- A newer format is refused rather than silently downgraded: writing this
	-- version's shape over it would drop whatever the newer one recorded.
	if type(decoded.version) == "number" and decoded.version > VERSION then
		return nil,
			("%s was written by a newer agent-review (version %d > %d): refusing to use or overwrite it"):format(
				path,
				decoded.version,
				VERSION
			)
	end

	local state = empty_state(root)
	if type(decoded.base) == "string" then
		state.base = decoded.base
	end
	local dropped = 0
	if type(decoded.verdicts) == "table" then
		for id, v in pairs(decoded.verdicts) do
			if type(id) == "string" and type(v) == "table" and VERDICTS[v.verdict] then
				state.verdicts[id] = {
					verdict = v.verdict,
					text = type(v.text) == "string" and v.text ~= "" and v.text or nil,
					ts = type(v.ts) == "number" and v.ts or os.time(),
				}
			else
				dropped = dropped + 1
			end
		end
	end
	if dropped > 0 then
		local backup = back_up(path)
		notify(
			("Dropped %d unusable entry/entries from %s%s"):format(
				dropped,
				path,
				backup and (" — the old file was copied to " .. backup) or ""
			),
			vim.log.levels.WARN
		)
	end
	return state, nil
end

---Read + parse in one step. An absent (or empty) file yields an empty state.
---@return table|nil state, string|nil err
local function read_state(path, root)
	local contents, err = read_file(path)
	if err then
		return nil, ("could not read %s: %s"):format(path, err)
	end
	if contents == nil or vim.trim(contents) == "" then
		return empty_state(root), nil
	end
	return parse(contents, root, path)
end

---Fold `from`'s verdicts into `into`. Verdicts are independent keys, so a merge
---is lossless; the newer timestamp wins when both sides know an id.
---@return integer added, integer updated
local function merge_verdicts(into, from)
	local added, updated = 0, 0
	for id, v in pairs(from or {}) do
		local mine = into[id]
		if mine == nil then
			into[id] = v
			added = added + 1
		elseif (v.ts or 0) > (mine.ts or 0) then
			into[id] = v
			updated = updated + 1
		end
	end
	return added, updated
end

---Reconcile the in-memory state for `root` with the file, which another Neovim
---instance may have rewritten. Returns false only when the file exists but
---cannot be used, in which case the caller must not overwrite it.
---@return boolean ok, string|nil err
local function sync_from_disk(root)
	local path = state_file(root)
	local st = stamp_of(path)
	if same_stamp(st, stamps[root]) then
		return true, nil
	end
	local disk, err = read_state(path, root)
	if not disk then
		return false, err
	end
	local mine = cache[root]
	local added, updated = merge_verdicts(mine.verdicts, disk.verdicts)
	if disk.base and disk.base ~= mine.base then
		if mine.base == nil then
			mine.base = disk.base
		else
			notify(
				("Another Neovim instance armed this repo against %s; keeping this one's base %s"):format(
					disk.base,
					mine.base
				),
				vim.log.levels.WARN
			)
		end
	end
	stamps[root] = st
	if added + updated > 0 then
		notify(
			("Merged %d verdict(s) recorded elsewhere for this repo (%d new, %d newer)"):format(
				added + updated,
				added,
				updated
			),
			vim.log.levels.WARN
		)
	end
	return true, nil
end

-- Public API --------------------------------------------------------------

---Report a refusal once per root and per distinct reason: load() runs on every
---buffer switch, so a broken file must not turn into a toast storm.
local function report_once(root, err)
	if reported[root] ~= err then
		reported[root] = err
		notify(err, vim.log.levels.ERROR)
	end
end

---Load (and cache) the verdict store for a repo root. Creates an empty state
---when nothing is on disk. Subsequent calls for the same root reuse the cache,
---but always stat the file first: another Neovim instance in the same repo may
---have written verdicts since, and those are merged in instead of being lost.
---@param root string absolute repo root
---@return table|nil state, string|nil err
function M.load(root)
	if type(root) ~= "string" or root == "" then
		notify("load() needs a repo root", vim.log.levels.ERROR)
		return nil, "no repo root"
	end

	root = normalize(root)
	current = root
	if cache[root] then
		local ok, err = sync_from_disk(root)
		if not ok then
			report_once(root, err)
		end
		return cache[root], nil
	end

	local path = state_file(root)
	-- Stamped BEFORE the read: if the file changes in between, the stale stamp
	-- makes the next save notice and merge, which is the safe direction.
	local st = stamp_of(path)
	local loaded, err = read_state(path, root)
	if not loaded then
		report_once(root, err)
		return nil, err
	end
	reported[root] = nil
	cache[root] = loaded
	stamps[root] = st
	return cache[root], nil
end

---The root of the currently loaded state.
---@return string|nil
function M.root()
	return current
end

---Where the currently loaded state is persisted (introspection / debugging).
---@return string|nil
function M.state_path()
	return current and state_file(current) or nil
end

---Persist the current state atomically: write a sibling temp file, fsync it,
---then rename it over the target. A half-written file can never replace the
---previous verdicts -- neither through a crash (the rename is atomic) nor
---through a short write or a failed fsync (both abort the save).
---
---`force` skips the merge with whatever another instance wrote and is reserved
---for the deliberately destructive :AgentReviewReset.
---@param force? boolean
---@return boolean ok, string|nil err
local function write_state(force)
	if not current or not cache[current] then
		return false, "no state loaded"
	end

	if not force then
		-- Someone else may have rewritten the file since we read it. Merging is
		-- lossless (verdicts are independent keys); when the file cannot be read
		-- we refuse rather than clobber it.
		local ok, serr = sync_from_disk(current)
		if not ok then
			local err = "refusing to overwrite " .. state_file(current) .. ": " .. tostring(serr)
			notify("Failed to save review state: " .. err, vim.log.levels.ERROR)
			return false, err
		end
	end

	local dir = state_dir(current)
	if vim.fn.isdirectory(dir) ~= 1 and vim.fn.mkdir(dir, "p") ~= 1 then
		local err = "could not create " .. dir
		notify("Failed to save review state: " .. err, vim.log.levels.ERROR)
		return false, err
	end

	local state = cache[current]
	local payload = {
		version = VERSION,
		root = state.root,
		base = state.base,
		-- vim.json.encode turns a plain empty table into a list; keep it a map.
		verdicts = next(state.verdicts) == nil and vim.empty_dict() or state.verdicts,
	}
	local ok, encoded = pcall(vim.json.encode, payload)
	if not ok then
		notify("Failed to encode review state: " .. tostring(encoded), vim.log.levels.ERROR)
		return false, tostring(encoded)
	end

	local target = state_file(current)
	local tmp = string.format("%s.%d.tmp", target, vim.uv.os_getpid())

	local function fail(err)
		vim.uv.fs_unlink(tmp)
		notify("Failed to save review state: " .. err, vim.log.levels.ERROR)
		return false, err
	end

	local fd, open_err = vim.uv.fs_open(tmp, "w", 420) -- 0644
	if not fd then
		return fail(tostring(open_err))
	end
	-- fs_write returns a BYTE COUNT: on ENOSPC it is positive but short, and
	-- renaming truncated JSON over the good file would lose the whole round.
	local written, write_err = vim.uv.fs_write(fd, encoded, 0)
	if not written then
		vim.uv.fs_close(fd)
		return fail(tostring(write_err))
	end
	if written ~= #encoded then
		vim.uv.fs_close(fd)
		return fail(("short write: %d of %d bytes (disk full?)"):format(written, #encoded))
	end
	local synced, sync_err = vim.uv.fs_fsync(fd)
	vim.uv.fs_close(fd)
	if not synced then
		return fail("fsync failed: " .. tostring(sync_err))
	end

	local renamed, rename_err = vim.uv.fs_rename(tmp, target)
	if not renamed then
		return fail(tostring(rename_err))
	end
	-- Remember what we just put there, so the next save can tell our own write
	-- apart from another instance's.
	stamps[current] = stamp_of(target)
	return true, nil
end

---@return boolean ok, string|nil err
function M.save()
	return write_state(false)
end

---Record the snapshot ref this review round is diffed against.
---@param ref string|nil
---@return boolean ok, string|nil err
function M.set_base(ref)
	if not current or not cache[current] then
		return false, "no state loaded"
	end
	cache[current].base = ref
	return M.save()
end

---@return string|nil
function M.base()
	local state = current and cache[current]
	return state and state.base or nil
end

---Record a verdict for a hunk id. Persists immediately so a crash cannot lose
---the review.
---@param id string hunk content hash
---@param verdict "accept"|"reject"|"comment"
---@param text string|nil
---@return boolean ok, string|nil err
function M.set_verdict(id, verdict, text)
	if not current or not cache[current] then
		return false, "no state loaded"
	end
	if type(id) ~= "string" or id == "" then
		return false, "invalid hunk id"
	end
	if not VERDICTS[verdict] then
		local err = "unknown verdict: " .. tostring(verdict)
		notify(err, vim.log.levels.ERROR)
		return false, err
	end

	cache[current].verdicts[id] = {
		verdict = verdict,
		text = (type(text) == "string" and text ~= "") and text or nil,
		ts = os.time(),
	}
	return M.save()
end

---@param id string
---@return ARVerdict|nil
function M.get_verdict(id)
	local state = current and cache[current]
	if not state or type(id) ~= "string" then
		return nil
	end
	return state.verdicts[id]
end

---@param id string
---@return boolean ok, string|nil err
function M.clear_verdict(id)
	local state = current and cache[current]
	if not state then
		return false, "no state loaded"
	end
	if state.verdicts[id] == nil then
		return true, nil
	end
	state.verdicts[id] = nil
	return M.save()
end

---Drop every verdict for this repo (a fresh review round from scratch).
---Deliberately destructive, so it forces the write: merging back what another
---instance recorded would resurrect exactly what the user asked to remove. The
---merge still runs first, so the report below counts everything that is going.
---@return boolean ok, string|nil err
function M.reset()
	local state = current and cache[current]
	if not state then
		return false, "no state loaded"
	end
	local ok, serr = sync_from_disk(current)
	if not ok then
		notify("Review state on disk could not be read before resetting: " .. tostring(serr), vim.log.levels.WARN)
	end
	local n = vim.tbl_count(state.verdicts)
	state.verdicts = {}
	state.base = nil
	local saved, err = write_state(true)
	if saved and n > 0 then
		notify(("Cleared %d verdict(s) from %s"):format(n, state_file(current)))
	end
	return saved, err
end

---@param hunks ARHunk[]
---@return integer reviewed, integer total
function M.progress(hunks)
	hunks = hunks or {}
	local reviewed = 0
	for _, hunk in ipairs(hunks) do
		if M.get_verdict(hunk.id) then
			reviewed = reviewed + 1
		end
	end
	return reviewed, #hunks
end

---First hunk with no verdict, scanning forward from `after_id` and wrapping
---around. `after_id` nil (or unknown) starts at the beginning.
---@param hunks ARHunk[]
---@param after_id string|nil
---@return ARHunk|nil
function M.next_unreviewed(hunks, after_id)
	hunks = hunks or {}
	local start = 0
	if after_id then
		for i, hunk in ipairs(hunks) do
			if hunk.id == after_id then
				start = i
				break
			end
		end
	end
	for offset = 1, #hunks do
		local hunk = hunks[((start + offset - 1) % #hunks) + 1]
		if not M.get_verdict(hunk.id) then
			return hunk
		end
	end
	return nil
end

---Join hunks with their verdicts into findings for the prompt renderer.
---Accepted hunks produce nothing: they are not feedback.
---@param hunks ARHunk[]
---@return ARFinding[]
function M.findings(hunks)
	hunks = hunks or {}
	local out = {}
	for i, hunk in ipairs(hunks) do
		local v = M.get_verdict(hunk.id)
		if v and (v.verdict == "reject" or v.verdict == "comment") then
			-- Deleted-file hunks report new_count == 0 (and sometimes
			-- new_start == 0); clamp so a finding never lands on line 0.
			local lnum = math.max(hunk.new_start or 1, 1)
			local end_lnum = lnum + math.max(hunk.new_count or 1, 1) - 1
			out[#out + 1] = {
				order = i,
				finding = {
					file = hunk.file,
					lnum = lnum,
					end_lnum = end_lnum ~= lnum and end_lnum or nil,
					text = v.text or DEFAULT_TEXT[v.verdict],
					kind = v.verdict,
					source = "human",
					diff = table.concat(hunk.lines or {}, "\n"),
				},
			}
		end
	end

	-- Deterministic order (it feeds a snapshot-tested renderer); the original
	-- index breaks ties so table.sort's instability can't leak through.
	table.sort(out, function(a, b)
		if a.finding.file ~= b.finding.file then
			return a.finding.file < b.finding.file
		end
		if a.finding.lnum ~= b.finding.lnum then
			return a.finding.lnum < b.finding.lnum
		end
		return a.order < b.order
	end)

	local findings = {}
	for _, entry in ipairs(out) do
		findings[#findings + 1] = entry.finding
	end
	return findings
end

---Drop stored verdicts whose hunk is gone from the current round.
---@param hunks ARHunk[]
---@return integer removed
function M.prune(hunks)
	local state = current and cache[current]
	if not state then
		return 0
	end
	local live = {}
	for _, hunk in ipairs(hunks or {}) do
		live[hunk.id] = true
	end
	local removed = 0
	for id in pairs(state.verdicts) do
		if not live[id] then
			state.verdicts[id] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		M.save()
	end
	return removed
end

return M
