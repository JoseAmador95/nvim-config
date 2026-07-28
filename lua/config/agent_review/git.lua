-- lua/config/agent_review/git.lua
-- Snapshot-and-diff engine for the agent-review workflow: take a baseline
-- *before* letting an agent run, then review exactly what the agent changed --
-- and nothing else.
--
-- A snapshot is built through a throwaway index under stdpath("cache"):
--   GIT_INDEX_FILE=<cache>/agent-review/ar-index git read-tree HEAD
--   GIT_INDEX_FILE=...                           git add -A      (honours .gitignore)
--   tree=$(GIT_INDEX_FILE=...                    git write-tree)
--   commit=$(git commit-tree $tree -p HEAD -m "agent-review snapshot")
--   git update-ref refs/agent-review/<id> $commit
-- Every part of that matters:
--   * the throwaway GIT_INDEX_FILE means the user's real index is never touched;
--   * `git add -A` captures tracked modifications *and* untracked new files, so
--     the baseline already contains the user's own pre-existing dirty work and
--     the later diff shows the agent's changes only;
--   * a *commit* (not a bare tree) is stored so `:DiffviewOpen <ref>` and
--     `:Gitsigns change_base <ref>` accept it as a revision;
--   * being a ref, it survives the agent committing mid-run.
--
-- Three traps this module exists to avoid (all verified):
--   1. `git diff <ref>` silently omits untracked files the agent created. So the
--      change list never uses `git diff <ref>`: a second "now" tree is built the
--      same throwaway-index way and the two *trees* are diffed.
--   2. `git diff -w --name-only` does NOT filter whitespace-only files -- it
--      still lists them. Whitespace-only is therefore decided per file, by
--      testing that `git diff -w <base_tree> <now_tree> -- <path>` is empty.
--   3. A binary file has no line counts (--numstat prints "-") and no @@ hunks
--      at all, so the naive reading is "+0/-0, nothing to review". A swapped
--      2 MB asset or a checked-in .so is exactly what a human must decide on,
--      so binaries are flagged and get a synthetic hunk of their own.
--
-- Nothing throws: every entry point returns `nil, err` on failure, and a failed
-- per-file probe is reported instead of being folded into a plausible-looking
-- default (a file quietly losing risk score because git errored is the ranking
-- lying to the reviewer).

---@class ARChangedFile
---@field path            string   -- relative to repo root, forward slashes
---@field status          "A"|"M"|"D"
---@field added           integer  -- 0 for binaries: git reports no line counts
---@field removed         integer  -- idem
---@field binary          boolean  -- git reported "-" line counts: no textual diff
---@field whitespace_only boolean
---@field generated       boolean
---@field score           number

---@class ARHunk
---@field file      string
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field class     "whitespace"|"imports"|"comments"|"logic"|"binary"
---@field id        string    -- stable content hash of the hunk body
---@field lines     string[]  -- raw diff body lines, keeping their +/-/space prefix

local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "AgentReview" })
end

local REF_PREFIX = "refs/agent-review/"

-- Paths (or added lines) matching these raise the risk score.
local SENSITIVE = { "exec", "eval", "subprocess", "os%.system", "token", "secret", "auth", "chmod" }

-- Lockfiles and vendored/minified paths: reviewing them by hand is pointless.
local GENERATED = {
	"lazy%-lock%.json",
	"package%-lock%.json",
	"yarn%.lock",
	"Cargo%.lock",
	"poetry%.lock",
	"%.min%.",
	"^vendor/",
	"^node_modules/",
}

-- Added lines that are "just an import" in the languages this config sees.
local IMPORT_PATTERNS = {
	"^%s*import%s",
	"^%s*from%s+.*%s+import%s",
	"^%s*local%s+[%w_]+%s*=%s*require%(",
	"^%s*require%(",
	"^%s*use%s",
	"^%s*#include%s",
}

local COMMENT_PREFIXES = { "--", "//", "#", "*", "/*" }

local function cache_dir()
	local dir = vim.fn.stdpath("cache") .. "/agent-review"
	vim.fn.mkdir(dir, "p")
	return dir
end

-- Run git synchronously in argv form (never a shell string, so there are no
-- quoting hazards). Returns stdout, nil on success or nil, err on failure.
-- These are fast local plumbing calls, so blocking on :wait() is acceptable.
local function git(root, args, env)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	local opts = { text = true, cwd = root }
	if env then
		opts.env = env
	end
	local ok, res = pcall(function()
		return vim.system(cmd, opts):wait()
	end)
	if not ok then
		return nil, "could not run git: " .. tostring(res)
	end
	if res.code ~= 0 then
		local msg = vim.trim(res.stderr or "")
		if msg == "" then
			msg = vim.trim(res.stdout or "")
		end
		if msg == "" then
			msg = ("git %s failed (exit %d)"):format(table.concat(args, " "), res.code)
		end
		return nil, msg
	end
	return res.stdout or "", nil
end

-- Same as git(), with `--literal-pathspecs` in front of the subcommand. Used by
-- every call that passes a user path after `--`: a literal match is tried before
-- fnmatch, so `app/[slug]/page.tsx` already worked, but this also stops a
-- glob-matching sibling from being pulled in alongside it and turns a leading
-- `:` into a plain path instead of "Invalid pathspec magic".
local function git_path(root, args)
	local full = { "--literal-pathspecs" }
	vim.list_extend(full, args)
	return git(root, full)
end

local function lines_of(s)
	local out = {}
	for line in (s or ""):gmatch("([^\n]*)\n?") do
		out[#out + 1] = line
	end
	-- gmatch above yields a trailing empty capture; drop it.
	if #out > 0 and out[#out] == "" then
		out[#out] = nil
	end
	return out
end

-- Split NUL-separated plumbing output (-z), dropping the trailing empty field.
local function nul_split(s)
	local out = vim.split(s or "", "\0", { plain = true })
	while #out > 0 and out[#out] == "" do
		out[#out] = nil
	end
	return out
end

local function norm(path)
	return (path:gsub("\\", "/"))
end

--- Repository root for the current directory.
--- The error matters: git ≥ 2.35 answers `detected dubious ownership in
--- repository at '...'` (exit 128) for a repo owned by another uid -- routine in
--- containers and devcontainers -- and that message names its own fix
--- (`git config --global --add safe.directory <path>`). Collapsing it into a
--- bare nil made the whole feature insist you were not in a repository.
---@return string|nil root, string|nil err
function M.root()
	if vim.fn.executable("git") ~= 1 then
		return nil, "git executable not found"
	end
	local out, err = git(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
	if not out then
		return nil, err
	end
	local top = vim.trim(out)
	if top == "" then
		return nil, "git rev-parse --show-toplevel returned nothing"
	end
	return norm(top), nil
end

local function require_root()
	local root, err = M.root()
	if not root then
		return nil, err or "not inside a git repository"
	end
	return root, nil
end

-- HEAD's commit sha, or nil, err when the repository has no commits yet.
local function head_commit(root)
	local out = git(root, { "rev-parse", "--verify", "--quiet", "HEAD^{commit}" })
	local sha = out and vim.trim(out) or ""
	if sha == "" then
		return nil, "repository has no commits yet (unborn HEAD): commit something before snapshotting"
	end
	return sha, nil
end

-- Build a tree object from the *working tree* (tracked modifications and
-- untracked files alike, .gitignore honoured) using a throwaway index, so the
-- user's real index is never touched. Returns tree_sha, nil or nil, err.
local function worktree_tree(root, index_name)
	local head, err = head_commit(root)
	if not head then
		return nil, err
	end
	-- Per-process index name. A fixed one is shared by every Neovim on the
	-- machine, so two instances open on the same repo raced for its index.lock
	-- and one of them failed with "Unable to create ... .lock: File exists" --
	-- routine for this workflow, where the editor sits in one pane and the agent
	-- in another. state.lua already pid-suffixes its temp file; this matches it.
	local index = ("%s/%s.%d"):format(cache_dir(), index_name, vim.uv.os_getpid())
	vim.fn.delete(index)
	local env = { GIT_INDEX_FILE = index }

	local _, e = git(root, { "read-tree", head }, env)
	if e then
		return nil, "read-tree failed: " .. e
	end
	_, e = git(root, { "add", "-A", "--", "." }, env)
	if e then
		return nil, "add -A failed: " .. e
	end
	local out
	out, e = git(root, { "write-tree" }, env)
	if e then
		return nil, "write-tree failed: " .. e
	end
	local tree = vim.trim(out or "")
	if tree == "" then
		return nil, "write-tree produced no tree"
	end
	return tree, nil
end

-- The "now" tree is rebuilt from the working tree on every call, which re-hashes
-- the worktree (the throwaway index carries no stat cache). A review pass asks
-- for changed_files() and then hunks() of many files in a row, so the result is
-- memoised for a couple of seconds: that also keeps one pass internally
-- consistent. Anything the user edits afterwards shows up on the next call.
local now_cache = { root = nil, tree = nil, at = 0 }
local NOW_TTL_MS = 2000

local function now_tree(root)
	local t = vim.uv.hrtime() / 1e6
	if now_cache.root == root and now_cache.tree and (t - now_cache.at) < NOW_TTL_MS then
		return now_cache.tree, nil
	end
	local tree, err = worktree_tree(root, "ar-index-now")
	if not tree then
		return nil, err
	end
	now_cache = { root = root, tree = tree, at = t }
	return tree, nil
end

-- Resolve a ref/commit-ish to its tree sha.
local function tree_of(root, rev)
	local out, err = git(root, { "rev-parse", "--verify", "--quiet", rev .. "^{tree}" })
	local tree = out and vim.trim(out) or ""
	if tree == "" then
		return nil, ("cannot resolve %q to a tree%s"):format(rev, err and (": " .. err) or "")
	end
	return tree, nil
end

--- Take a snapshot of the current working tree and store it as a ref.
---@param opts? { id?: string, message?: string }
---@return string|nil ref, string|nil err
function M.snapshot(opts)
	opts = opts or {}
	local root, err = require_root()
	if not root then
		return nil, err
	end
	local head
	head, err = head_commit(root)
	if not head then
		return nil, err
	end

	local tree
	tree, err = worktree_tree(root, "ar-index")
	if not tree then
		return nil, err
	end

	local message = opts.message or "agent-review snapshot"
	local out
	out, err = git(root, { "commit-tree", tree, "-p", head, "-m", message })
	if not out then
		return nil, "commit-tree failed: " .. err
	end
	local commit = vim.trim(out)
	if commit == "" then
		return nil, "commit-tree produced no commit"
	end

	-- Timestamp-based id; disambiguate the (rare) collision within one second.
	local id = opts.id or os.date("%Y%m%d-%H%M%S")
	local ref = REF_PREFIX .. id
	if not opts.id then
		local n = 1
		while git(root, { "rev-parse", "--verify", "--quiet", ref }) ~= nil do
			n = n + 1
			ref = ("%s%s-%d"):format(REF_PREFIX, id, n)
		end
	end

	local _, uerr = git(root, { "update-ref", ref, commit })
	if uerr then
		return nil, "update-ref failed: " .. uerr
	end
	return ref, nil
end

-- Warn at most once per adopted ref, so the message lands when it matters
-- without turning every BufEnter into a toast.
local warned_adopted = nil

--- Resolve the base ref for a round: the recorded one, else the newest snapshot.
---
--- Adopting a snapshot nobody armed is the one way to review against a stale
--- baseline and never notice, so it warns. It deliberately does NOT persist the
--- adopted ref: persisting made `:AgentReviewReset` undo itself on the next
--- buffer switch, and made `:checkhealth` arm a round as a side effect.
---@param recorded string|nil the base already recorded for this round
---@return string|nil base, string|nil err, boolean adopted
function M.resolve_base(recorded)
	if recorded and recorded ~= "" then
		return recorded, nil, false
	end
	local latest = M.latest()
	if not latest then
		return nil, "no agent-review snapshot yet: take one first (<leader>vs)", false
	end
	if warned_adopted ~= latest then
		warned_adopted = latest
		local stamp = latest:match("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)$")
		notify(
			("No round was armed; showing the newest snapshot %s%s. Run <leader>vs to start a fresh round."):format(
				latest,
				stamp and (" (taken " .. stamp .. ")") or ""
			),
			vim.log.levels.WARN
		)
	end
	return latest, nil, true
end

--- The most recent refs/agent-review/* ref, or nil when there is none.
--- Second return value is the git error, when there was one: "no snapshot yet"
--- and "git refused to look" are not the same answer.
---@return string|nil ref, string|nil err
function M.latest()
	local root, err = M.root()
	if not root then
		return nil, err
	end
	local out
	out, err = git(root, { "for-each-ref", "--format=%(creatordate:unix)\t%(refname)", REF_PREFIX })
	if not out then
		return nil, "for-each-ref failed: " .. err
	end
	local best, best_at
	for _, line in ipairs(lines_of(out)) do
		local at, ref = line:match("^(%d+)\t(.+)$")
		if ref then
			at = tonumber(at)
			if not best_at or at > best_at or (at == best_at and ref > best) then
				best, best_at = ref, at
			end
		end
	end
	return best, nil
end

local function matches_any(s, patterns)
	for _, p in ipairs(patterns) do
		if s:match(p) then
			return true
		end
	end
	return false
end

local function is_generated(path)
	return matches_any(path, GENERATED)
end

local function is_test(path)
	for seg in path:lower():gmatch("[^/]+") do
		if seg:find("test", 1, true) or seg:find("spec", 1, true) then
			return true
		end
	end
	return false
end

local function is_sensitive(text)
	return matches_any(text:lower(), SENSITIVE)
end

-- `git diff -w` is empty <=> every change in the file is whitespace-only.
-- (`git diff -w --name-only` would still list the file, hence the per-file test.)
-- Returns ok, nil or false, err: a git failure must not read as "there is a real
-- change here" or "this is only whitespace" -- the caller has to say so.
local function whitespace_only(root, base_tree, new_tree, path)
	local out, err = git_path(root, { "diff", "-w", base_tree, new_tree, "--", path })
	if not out then
		return false, err
	end
	return vim.trim(out) == "", nil
end

-- The added ("+") lines of a file's diff, without their prefix.
-- Returns lines, nil or nil, err: returning {} on failure made the sensitive
-- content scan find nothing and the file silently drop its +3 risk score.
local function added_lines(root, base_tree, new_tree, path)
	local out, err = git_path(root, { "diff", "-U0", base_tree, new_tree, "--", path })
	if not out then
		return nil, err
	end
	local added = {}
	for _, line in ipairs(lines_of(out)) do
		if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
			added[#added + 1] = line:sub(2)
		end
	end
	return added, nil
end

local function score_of(f, sensitive)
	local score = 0
	if f.status == "A" then
		score = score + 3
	elseif f.status == "D" then
		score = score + 2
	end
	local net = f.added - f.removed
	if net > 0 then
		score = score + math.floor(net / 50)
	end
	if sensitive then
		score = score + 3
	end
	-- A binary change carries no line counts, so churn scores it at 0 and it
	-- would sink to the bottom of the ranking as if nothing had happened. It is
	-- the opposite: nobody can read it, so a human has to decide on it.
	if f.binary then
		score = score + 3
	end
	if f.whitespace_only then
		score = score - 5
	end
	if f.generated then
		score = score - 5
	end
	if is_test(f.path) then
		score = score - 1
	end
	return score
end

--- Files the agent changed since `base`, with per-file risk scoring.
--- Untracked files created by the agent ARE included (this is why a tree-to-tree
--- diff is used instead of `git diff <ref>`).
---@param base string ref or commit-ish
---@return ARChangedFile[]|nil files, string|nil err
function M.changed_files(base)
	local root, err = require_root()
	if not root then
		return nil, err
	end
	if not base or base == "" then
		return nil, "no snapshot given"
	end
	local base_tree
	base_tree, err = tree_of(root, base)
	if not base_tree then
		return nil, err
	end
	local new_tree
	new_tree, err = now_tree(root)
	if not new_tree then
		return nil, err
	end

	local out
	out, err = git(root, { "diff-tree", "-r", "-z", "--name-status", base_tree, new_tree })
	if not out then
		return nil, "diff-tree --name-status failed: " .. err
	end
	local fields = nul_split(out)
	local files, index = {}, {}
	local i = 1
	while i < #fields + 1 do
		local status, path = fields[i], fields[i + 1]
		i = i + 2
		if not path then
			break
		end
		local s = status:sub(1, 1)
		if s ~= "A" and s ~= "D" then
			s = "M" -- M, T (typechange) and anything else read as a modification
		end
		path = norm(path)
		local f = {
			path = path,
			status = s,
			added = 0,
			removed = 0,
			binary = false,
			whitespace_only = false,
			generated = is_generated(path),
			score = 0,
		}
		files[#files + 1] = f
		index[path] = f
	end

	out, err = git(root, { "diff-tree", "-r", "-z", "--numstat", base_tree, new_tree })
	if not out then
		return nil, "diff-tree --numstat failed: " .. err
	end
	-- Note the asymmetry with --name-status: with -z, --numstat packs the whole
	-- record into ONE NUL-terminated field, "added\tremoved\tpath".
	for _, record in ipairs(nul_split(out)) do
		local a, r, path = record:match("^(%S+)\t(%S+)\t(.*)$")
		local f = path and index[norm(path)]
		if f then
			-- "-\t-\t<path>" is how --numstat says "binary": there are no line
			-- counts to report. tonumber("-") is nil, and the old fallback to 0
			-- made a swapped 2 MB PNG read as "+0/-0", i.e. as nothing at all.
			f.binary = a == "-" or r == "-"
			f.added = tonumber(a) or 0
			f.removed = tonumber(r) or 0
		end
	end

	local probe_errs = {}
	for _, f in ipairs(files) do
		-- A binary file has no textual diff: `git diff -w` prints "Binary files
		-- ... differ", which is neither whitespace-only nor scannable content.
		if not f.binary then
			local ws, wserr = whitespace_only(root, base_tree, new_tree, f.path)
			if wserr then
				probe_errs[#probe_errs + 1] = f.path .. ": " .. wserr
			end
			f.whitespace_only = ws
		end
		local sensitive = is_sensitive(f.path)
		if not sensitive and not f.generated and not f.binary then
			-- Scanning a lockfile's body for "token"/"auth" is noise, so generated
			-- files are skipped here; they are dropped by -5 anyway.
			local added, aerr = added_lines(root, base_tree, new_tree, f.path)
			if not added then
				probe_errs[#probe_errs + 1] = f.path .. ": " .. tostring(aerr)
			end
			for _, line in ipairs(added or {}) do
				if is_sensitive(line) then
					sensitive = true
					break
				end
			end
		end
		f.score = score_of(f, sensitive)
	end
	-- One toast, not one per file: the ranking is now partly guesswork and the
	-- human has to know which files it could not read.
	if #probe_errs > 0 then
		notify(
			("Risk scoring is incomplete, git failed on %d probe(s): %s"):format(
				#probe_errs,
				table.concat(probe_errs, "; ")
			),
			vim.log.levels.WARN
		)
	end

	table.sort(files, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.path < b.path
	end)
	return files, nil
end

local function strip_ws(s)
	return (s:gsub("%s", ""))
end

local function is_import(line)
	return matches_any(line, IMPORT_PATTERNS)
end

local function is_comment(line)
	local t = vim.trim(line)
	for _, p in ipairs(COMMENT_PREFIXES) do
		if t:sub(1, #p) == p then
			return true
		end
	end
	return false
end

-- Classify a hunk from its added lines. Order matters, and anything uncertain
-- falls through to "logic": never hide a change from the human by mistake.
local function classify(hunk_lines, file_whitespace_only)
	local added, removed = {}, {}
	for _, line in ipairs(hunk_lines) do
		local c = line:sub(1, 1)
		if c == "+" then
			added[#added + 1] = line:sub(2)
		elseif c == "-" then
			removed[#removed + 1] = line:sub(2)
		end
	end

	if file_whitespace_only then
		return "whitespace"
	end
	if strip_ws(table.concat(added, "\n")) == strip_ws(table.concat(removed, "\n")) then
		return "whitespace"
	end

	local body = {}
	for _, line in ipairs(added) do
		if vim.trim(line) ~= "" then
			body[#body + 1] = line
		end
	end
	if #body == 0 then
		return "logic"
	end

	local all_imports, all_comments = true, true
	for _, line in ipairs(body) do
		if not is_import(line) then
			all_imports = false
		end
		if not is_comment(line) then
			all_comments = false
		end
	end
	if all_imports then
		return "imports"
	end
	if all_comments then
		return "comments"
	end
	return "logic"
end

--- Hunks of one file between `base` and the current working tree.
--- `id` is a content hash of the hunk body only (no line numbers), so a hunk
--- that merely shifted position keeps its id across rounds.
---@param base string ref or commit-ish
---@param file string path relative to the repo root
---@return ARHunk[]|nil hunks, string|nil err
function M.hunks(base, file)
	local root, err = require_root()
	if not root then
		return nil, err
	end
	if not base or base == "" then
		return nil, "no snapshot given"
	end
	if not file or file == "" then
		return nil, "no file given"
	end
	local base_tree
	base_tree, err = tree_of(root, base)
	if not base_tree then
		return nil, err
	end
	local new_tree
	new_tree, err = now_tree(root)
	if not new_tree then
		return nil, err
	end

	file = norm(file)
	local out
	out, err = git_path(root, { "diff", "-U0", base_tree, new_tree, "--", file })
	if not out then
		return nil, "diff -U0 failed: " .. err
	end
	local ws_only, wserr = whitespace_only(root, base_tree, new_tree, file)
	if wserr then
		notify(("Could not test %s for whitespace-only changes: %s"):format(file, wserr), vim.log.levels.WARN)
	end

	local hunks, cur = {}, nil
	local function flush()
		if cur then
			cur.class = classify(cur.lines, ws_only)
			-- The path is part of the identity, the position is not. Hashing the
			-- body alone made an agent's repeated edit -- the same import or the
			-- same logger line added to eight files -- collapse into one id, so
			-- reviewing one marked all eight reviewed. Line numbers stay out so a
			-- hunk that merely shifts keeps its verdict.
			cur.id = vim.fn.sha256(cur.file .. "\n" .. table.concat(cur.lines, "\n"))
			hunks[#hunks + 1] = cur
			cur = nil
		end
	end

	-- Binary files produce no @@ header at all, only "Binary files a/x and b/x
	-- differ" under an `index <old>..<new>` line.
	local binary_body = nil
	for _, line in ipairs(lines_of(out)) do
		-- Counts are omitted when they are 1: "@@ -1 +2 @@" is legal.
		local os_, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if os_ then
			flush()
			cur = {
				file = file,
				old_start = tonumber(os_),
				old_count = oc ~= "" and tonumber(oc) or 1,
				new_start = tonumber(ns),
				new_count = nc ~= "" and tonumber(nc) or 1,
				lines = {},
			}
		elseif cur then
			local c = line:sub(1, 1)
			-- "\ No newline at end of file" is a marker, not content: keeping it out
			-- of `lines` keeps the id stable.
			if c == "+" or c == "-" or c == " " then
				cur.lines[#cur.lines + 1] = line
			elseif line == "" then
				cur.lines[#cur.lines + 1] = " "
			end
		elseif line:match("^Binary files ") or line == "GIT binary patch" then
			binary_body = binary_body or {}
			binary_body[#binary_body + 1] = line
		elseif line:match("^index ") then
			-- Kept only if the file turns out to be binary: the blob shas are the
			-- only thing that changes when the content does, so they carry the
			-- identity that a textual body would carry elsewhere.
			binary_body = binary_body or {}
			binary_body[#binary_body + 1] = line
		end
	end
	flush()

	-- Without this, a replaced binary yields zero hunks, counts as fully
	-- reviewed, and the round happily announces "No unreviewed hunks left" over
	-- a 2 MB asset nobody looked at. One synthetic hunk stands for the whole
	-- file so it joins the ]v queue and needs an explicit verdict; hashing the
	-- index line means a second replacement invalidates the first verdict.
	if #hunks == 0 and binary_body then
		local body = { "Binary file: no textual diff, review the file itself" }
		vim.list_extend(body, binary_body)
		hunks[1] = {
			file = file,
			old_start = 1,
			old_count = 1,
			new_start = 1,
			new_count = 1,
			class = "binary",
			lines = body,
			id = vim.fn.sha256(file .. "\n" .. table.concat(body, "\n")),
		}
	end

	return hunks, nil
end

M.notify = notify

return M
