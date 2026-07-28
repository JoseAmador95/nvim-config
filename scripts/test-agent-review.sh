#!/usr/bin/env bash
# scripts/test-agent-review.sh
#
# The only automated test in this config. It covers the two pure-ish layers of
# the agent-review feature (lua/config/agent_review/), which are exactly where
# the subtle bugs showed up while it was written:
#
#   A. the snapshot/diff engine (git.lua)      -- untracked files, mid-run
#      commits, whitespace-only detection, stable hunk ids, scoring
#   B. the prompt renderer (prompt.lua)        -- pure, byte-exact output
#   C. the verdict store (state.lua)           -- content-hash keying
#   D. the machine pass (checks.lua)           -- ASYNC, hunk line arithmetic
#
# Usage:  scripts/test-agent-review.sh
#         NVIM_BIN=/path/to/nvim scripts/test-agent-review.sh
#
# Dependencies: bash, git, nvim. Nothing else.
#
# Notes that are not obvious and cost time to rediscover:
#
#   * `nvim --headless -l script.lua` EXITS AS SOON AS THE SCRIPT RETURNS, so
#     anything deferred (vim.defer_fn / vim.schedule) never runs. checks.run is
#     asynchronous, therefore group D is driven with `-c "luafile ..."` and
#     quits explicitly from inside the callback. Using -l there yields a green
#     run that tested nothing. Do not "simplify" it back.
#   * Every nvim run gets throwaway XDG_{STATE,DATA,CACHE,CONFIG}_HOME dirs:
#     state.lua writes verdicts under stdpath("state") and git.lua writes its
#     throwaway index under stdpath("cache"). The developer's real state must
#     never be touched by running the tests.
#   * Fixtures are real git repos under mktemp -d, removed by a trap. The real
#     repository is only ever read (for lua/), never written.
#   * GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM=/dev/null plus a per-fixture
#     user.name/user.email so this works on a machine with no git identity and
#     with arbitrary global git config (hooks, templates, default branch...).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_LUA="$REPO/lua"

# --- nvim discovery -------------------------------------------------------
# A config repo may legitimately be checked out on a machine without nvim.
# Skipping is not a failure; hard-failing would make the script useless there.
if [ -n "${NVIM_BIN:-}" ]; then
	if [ ! -x "$NVIM_BIN" ]; then
		echo "# SKIP: NVIM_BIN=$NVIM_BIN is not an executable file"
		exit 0
	fi
elif command -v nvim >/dev/null 2>&1; then
	NVIM_BIN="$(command -v nvim)"
else
	echo "# SKIP: no nvim found (set NVIM_BIN=/path/to/nvim to run these tests)"
	exit 0
fi

if ! command -v git >/dev/null 2>&1; then
	echo "# SKIP: no git found"
	exit 0
fi

# Backstop for a hung nvim; the Lua side has its own shorter watchdog.
if command -v timeout >/dev/null 2>&1; then
	TIMEOUT=(timeout 120)
else
	TIMEOUT=()
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-review-tests.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

mkdir -p "$TMPROOT/lua" "$TMPROOT/scripts" "$TMPROOT/xdg"

# --- harness --------------------------------------------------------------

N=0
FAILURES=0

pass() {
	N=$((N + 1))
	printf 'ok %d - %s\n' "$N" "$1"
}

fail() {
	N=$((N + 1))
	FAILURES=$((FAILURES + 1))
	printf 'not ok %d - %s\n' "$N" "$1"
}

# Consume a nvim run's output: PASS/FAIL lines become numbered results,
# everything else is echoed as a TAP-style diagnostic. Fed with a here-string,
# never through a pipe: a pipeline would run this in a subshell and the
# counters would silently stay at zero.
consume() {
	local line
	while IFS= read -r line; do
		case "$line" in
		"PASS "*) pass "${line#PASS }" ;;
		"FAIL "*) fail "${line#FAIL }" ;;
		"") ;;
		*) printf '# %s\n' "$line" ;;
		esac
	done
}

# run_nvim <cwd> <sync|async> <luafile> <expected_results> [ENV=VAL ...]
#
# `expected_results` is not bureaucracy: a Lua script that dies early, or an
# async one accidentally driven with `-l`, reports NOTHING and would otherwise
# leave the suite green while testing nothing at all. A run that produces fewer
# results than expected is a failure.
run_nvim() {
	local cwd="$1" mode="$2" script="$3" expected="$4"
	shift 4
	local out rc=0 before="$N"
	local -a env_args=(
		"HOME=$TMPROOT/xdg"
		"XDG_CONFIG_HOME=$TMPROOT/xdg/config"
		"XDG_DATA_HOME=$TMPROOT/xdg/data"
		"XDG_STATE_HOME=$TMPROOT/xdg/state"
		"XDG_CACHE_HOME=$TMPROOT/xdg/cache"
		"GIT_CONFIG_GLOBAL=/dev/null"
		"GIT_CONFIG_SYSTEM=/dev/null"
		"GIT_AUTHOR_NAME=Agent Review Tests"
		"GIT_AUTHOR_EMAIL=tests@example.invalid"
		"GIT_COMMITTER_NAME=Agent Review Tests"
		"GIT_COMMITTER_EMAIL=tests@example.invalid"
		"NVIM_APPNAME=nvim"
	)
	env_args+=("$@")

	if [ "$mode" = "async" ]; then
		# -c "luafile" keeps the event loop alive so deferred callbacks run;
		# the script itself quits (qa! / cq). See the header comment.
		out="$(cd "$cwd" && env "${env_args[@]}" "${TIMEOUT[@]}" \
			"$NVIM_BIN" -u NONE --noplugin -n -i NONE --headless \
			-c "luafile $script" 2>&1)" || rc=$?
	else
		out="$(cd "$cwd" && env "${env_args[@]}" "${TIMEOUT[@]}" \
			"$NVIM_BIN" -u NONE --noplugin -n -i NONE \
			-l "$script" 2>&1)" || rc=$?
	fi

	consume <<<"$out"
	if [ "$rc" -ne 0 ] && ! grep -q '^FAIL ' <<<"$out"; then
		fail "$(basename "$script") exited $rc without reporting a failure"
	fi
	local produced=$((N - before))
	if [ "$produced" -lt "$expected" ]; then
		fail "$(basename "$script") reported $produced results, expected $expected"
	fi
}

# Emits the shared Lua prelude (module search path + tiny assertion helper).
lua_prelude() {
	cat <<EOF
package.path = "$REPO_LUA/?.lua;$REPO_LUA/?/init.lua;$TMPROOT/lua/?.lua;" .. package.path
local T = require("artest")
EOF
}

# --- Lua assertion helper -------------------------------------------------

cat >"$TMPROOT/lua/artest.lua" <<'LUA'
-- Minimal assertion helper shared by every Lua test script.
-- Results go to stdout as "PASS <name>" / "FAIL <name>: <detail>"; the bash
-- side numbers them. io.stdout is used instead of print() because it behaves
-- identically under `-l` and under headless `-c luafile`.
local T = { failed = 0 }

local function flat(s)
	return (tostring(s):gsub("%s+", " "))
end

function T.emit(s)
	io.stdout:write(s .. "\n")
	io.stdout:flush()
end

function T.diag(s)
	T.emit("| " .. flat(s))
end

function T.ok(name, cond, detail)
	if cond then
		T.emit("PASS " .. name)
	else
		T.failed = T.failed + 1
		T.emit("FAIL " .. name .. (detail and (": " .. flat(detail)) or ""))
	end
	return cond and true or false
end

function T.eq(name, got, want)
	return T.ok(name, got == want, ("expected %s, got %s"):format(vim.inspect(want), vim.inspect(got)))
end

-- For `-l` scripts: exit right away.
function T.finish()
	os.exit(T.failed > 0 and 1 or 0)
end

-- For headless `-c luafile` scripts: must be called from inside the callback,
-- otherwise nvim sits in the event loop forever.
function T.quit()
	vim.cmd(T.failed > 0 and "cq" or "qa!")
end

return T
LUA

# --- snapshot driver (shared by fixtures A and D) -------------------------
# Takes the snapshot from inside nvim, i.e. through the real code path, at the
# exact moment the fixture is in the "user has dirty work, agent has not run
# yet" state.

{
	lua_prelude
	cat <<'LUA'
local git = require("config.agent_review.git")

local id = vim.env.AR_SNAP_ID
local ref, err = git.snapshot({ id = id })
if not ref then
	T.ok("snapshot(" .. tostring(id) .. ")", false, tostring(err))
	T.finish()
end
if ref ~= "refs/agent-review/" .. id then
	T.ok("snapshot ref name", false, ref)
end

if vim.env.AR_CHECK_INDEX == "1" then
	-- The snapshot builds its trees through a throwaway GIT_INDEX_FILE. If that
	-- ever regressed to the real index, the user would find their working tree
	-- staged behind their back.
	local res = vim.system({ "git", "diff", "--cached", "--name-only" }, { text = true, cwd = git.root() }):wait()
	T.ok(
		"snapshotting leaves the real git index untouched",
		res.code == 0 and vim.trim(res.stdout or "") == "",
		"git diff --cached: " .. tostring(res.stdout)
	)
end

T.finish()
LUA
} >"$TMPROOT/scripts/snapshot.lua"

# =========================================================================
# Group A -- the snapshot engine
# =========================================================================

FIX_A="$TMPROOT/fixture-a"
mkdir -p "$FIX_A/src" "$FIX_A/notes"

cat >"$FIX_A/src/app.lua" <<'EOF'
local M = {}

function M.add(a, b)
  return a + b
end

return M
EOF

cat >"$FIX_A/src/keep.lua" <<'EOF'
-- The user was editing this before the agent ran.
return { user = true }
EOF

cat >"$FIX_A/src/old.lua" <<'EOF'
-- The agent deletes this file.
return {}
EOF

# Indented with two spaces; the agent will only re-indent it to four.
cat >"$FIX_A/src/indent.lua" <<'EOF'
local function f(x)
  if x then
    return x
  end
end

return f
EOF

cat >"$FIX_A/lazy-lock.json" <<'EOF'
{
  "some-plugin": { "branch": "main", "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
}
EOF

# Long enough that prepending lines later cannot merge with the agent's hunk.
: >"$FIX_A/src/shift.lua"
for i in $(seq 1 30); do
	printf 'local v%d = %d\n' "$i" "$i" >>"$FIX_A/src/shift.lua"
done

git -c init.defaultBranch=main init -q "$FIX_A"
git -C "$FIX_A" config user.email tests@example.invalid
git -C "$FIX_A" config user.name "Agent Review Tests"
git -C "$FIX_A" add -A
git -C "$FIX_A" commit -q -m "initial"

# The user's own dirty work, BEFORE the snapshot: it belongs to the baseline
# and must never show up as something the agent did.
printf -- '-- user was here\n' >>"$FIX_A/src/keep.lua"
printf -- 'user scratch notes\n' >"$FIX_A/notes/user_scratch.md"

echo "# group A: snapshot engine"
run_nvim "$FIX_A" sync "$TMPROOT/scripts/snapshot.lua" 1 AR_SNAP_ID=snapA AR_CHECK_INDEX=1

# --- the agent runs -------------------------------------------------------

# 1. modifies a tracked file
cat >"$FIX_A/src/app.lua" <<'EOF'
local M = {}

function M.add(a, b)
  if a == nil then
    return b
  end
  return a + b
end

return M
EOF

# 2. deletes a file
rm "$FIX_A/src/old.lua"

# 3. re-indents a file, changing nothing else
cat >"$FIX_A/src/indent.lua" <<'EOF'
local function f(x)
    if x then
        return x
    end
end

return f
EOF

# 4. bumps a lockfile
cat >"$FIX_A/lazy-lock.json" <<'EOF'
{
  "some-plugin": { "branch": "main", "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
}
EOF

# 5. edits a line deep inside a long file (used for the stable-id test)
: >"$FIX_A/src/shift.lua"
for i in $(seq 1 30); do
	if [ "$i" -eq 25 ]; then
		printf 'local v25 = 2500\n' >>"$FIX_A/src/shift.lua"
	else
		printf 'local v%d = %d\n' "$i" "$i" >>"$FIX_A/src/shift.lua"
	fi
done

# 6. commits midway (which also sweeps up the user's pre-snapshot dirty work,
#    exactly like a real agent would)
git -C "$FIX_A" add -A
git -C "$FIX_A" commit -q -m "agent: work in progress"

# 7. keeps working after the commit: a new untracked file...
cat >"$FIX_A/src/new_helper.lua" <<'EOF'
return function(x)
  return x * 2
end
EOF

# ...and another edit to an already-committed file
printf -- '-- post-commit tweak\n' >>"$FIX_A/src/app.lua"

{
	lua_prelude
	cat <<'LUA'
local git = require("config.agent_review.git")

local base = "refs/agent-review/snapA"
local root = git.root()

local files, err = git.changed_files(base)
if not files then
	T.ok("changed_files", false, tostring(err))
	T.finish()
end

local by_path, order = {}, {}
for i, f in ipairs(files) do
	by_path[f.path] = f
	order[f.path] = i
end

-- 1. `git diff <ref>` silently omits untracked files; the engine diffs two
--    trees precisely so the agent's brand-new file cannot go unreviewed.
local newf = by_path["src/new_helper.lua"]
T.ok(
	"an untracked file created by the agent is listed as added",
	newf ~= nil and newf.status == "A",
	"got " .. vim.inspect(newf) .. " of " .. vim.inspect(vim.tbl_keys(by_path))
)

-- 2. The baseline already contains the user's dirty work, so it diffs away.
T.ok(
	"the user's pre-snapshot dirty work is not attributed to the agent",
	by_path["src/keep.lua"] == nil and by_path["notes/user_scratch.md"] == nil,
	"unexpected: " .. vim.inspect({ by_path["src/keep.lua"], by_path["notes/user_scratch.md"] })
)

-- 3.
local del = by_path["src/old.lua"]
T.ok("a file the agent deleted reports status D", del ~= nil and del.status == "D", vim.inspect(del))

-- 4. A commit in the middle of the run must not truncate the diff: changes
--    from before AND after the commit have to be visible.
local hunks, herr = git.hunks(base, "src/app.lua")
local pre, post = false, false
for _, h in ipairs(hunks or {}) do
	for _, line in ipairs(h.lines) do
		if line == "+  if a == nil then" then
			pre = true
		end
		if line == "+-- post-commit tweak" then
			post = true
		end
	end
end
T.ok(
	"a mid-run commit does not break the diff",
	pre and post,
	("pre=%s post=%s err=%s hunks=%s"):format(tostring(pre), tostring(post), tostring(herr), vim.inspect(hunks))
)

-- 5. `git diff -w --name-only` still LISTS whitespace-only files, so the flag
--    is computed per file with an emptiness test on `git diff -w`.
local indent, app = by_path["src/indent.lua"], by_path["src/app.lua"]
T.ok(
	"a re-indented file is whitespace_only, a real change is not",
	indent ~= nil and indent.whitespace_only == true and app ~= nil and app.whitespace_only == false,
	("indent=%s app=%s"):format(vim.inspect(indent), vim.inspect(app))
)

-- 7. Lockfiles are recognised and sink below real logic changes: the ordering
--    is the whole point of the score.
local lock = by_path["lazy-lock.json"]
T.ok(
	"a lockfile is flagged generated and scores below a logic change",
	lock ~= nil
		and lock.generated == true
		and app ~= nil
		and app.generated == false
		and lock.score < app.score
		and order["lazy-lock.json"] > order["src/app.lua"],
	("lock=%s app=%s order=%s"):format(vim.inspect(lock), vim.inspect(app), vim.inspect(order))
)

-- 8. The hunk id is a hash of the body only, so a hunk that merely drifts to
--    another line number keeps its identity (and therefore its verdict).
local before = git.hunks(base, "src/shift.lua") or {}
if #before ~= 1 then
	T.ok("shift fixture has exactly one hunk", false, vim.inspect(before))
	T.finish()
end
local id, start = before[1].id, before[1].new_start

local path = root .. "/src/shift.lua"
local padded = { "-- pad 1", "-- pad 2", "-- pad 3", "-- pad 4", "-- pad 5" }
vim.list_extend(padded, vim.fn.readfile(path))
vim.fn.writefile(padded, path)

-- git.lua memoises the "now" tree for a couple of seconds; a fresh instance of
-- the module is the cheapest way to look at the world again immediately.
package.loaded["config.agent_review.git"] = nil
local git2 = require("config.agent_review.git")

local after = git2.hunks(base, "src/shift.lua") or {}
local moved
for _, h in ipairs(after) do
	if h.id == id then
		moved = h
	end
end
T.ok(
	"a hunk that only shifts position keeps its id",
	moved ~= nil and moved.new_start == start + 5,
	("id=%s start=%s after=%s"):format(id, tostring(start), vim.inspect(after))
)

T.finish()
LUA
} >"$TMPROOT/scripts/group_a.lua"

run_nvim "$FIX_A" sync "$TMPROOT/scripts/group_a.lua" 7

# =========================================================================
# Group B -- the prompt renderer (pure; exact strings)
# =========================================================================

echo "# group B: prompt renderer"

{
	lua_prelude
	cat <<'LUA'
local prompt = require("config.agent_review.prompt")

local findings = {
	{ file = "b.lua", lnum = 2, text = "una linea\n   y otra\n\n", kind = "comment" },
	{ file = "a.lua", lnum = 5, end_lnum = 9, text = "rango", kind = "reject" },
	{ file = "a.lua", lnum = 1, text = "primero", kind = "comment" },
}

-- Empty header/footer keeps the expected value small; the wording of the
-- defaults is prose, not behaviour.
local bare = { header = "", footer = "" }

local want = table.concat({
	"## a.lua",
	"",
	"- `a.lua:1` — primero",
	"- `a.lua:5-9` — rango",
	"",
	"## b.lua",
	"",
	"- `b.lua:2` — una linea y otra",
}, "\n") .. "\n"

local got = prompt.render(findings, bare)

-- 9 + 10 + 11 are three properties of one exact string, asserted separately so
-- a regression names itself.
T.eq("findings render grouped by file, one self-contained bullet each", got, want)
T.ok(
	"a finding with an end line renders as path:start-end",
	type(got) == "string" and got:find("- `a.lua:5-9` — rango", 1, true) ~= nil,
	got
)
T.ok(
	"multi-line finding text collapses to a single line",
	type(got) == "string" and got:find("- `b.lua:2` — una linea y otra", 1, true) ~= nil,
	got
)

-- 12. The renderer feeds a prompt the human re-reads across rounds: input order
--     must not perturb it (it is snapshot-tested for exactly this reason).
local shuffled = { findings[2], findings[3], findings[1] }
T.ok(
	"output is byte-identical regardless of finding order",
	prompt.render(findings) == prompt.render(shuffled),
	vim.inspect({ prompt.render(findings), prompt.render(shuffled) })
)

-- 13. No findings must yield no prompt at all -- not an empty buffer.
T.ok(
	"no findings renders nil, never an empty prompt",
	prompt.render({}) == nil and prompt.render(nil) == nil,
	vim.inspect({ prompt.render({}), prompt.render(nil) })
)

T.finish()
LUA
} >"$TMPROOT/scripts/group_b.lua"

run_nvim "$TMPROOT" sync "$TMPROOT/scripts/group_b.lua" 5

# =========================================================================
# Group C -- the verdict store
# =========================================================================

echo "# group C: verdict state"

{
	lua_prelude
	cat <<'LUA'
local state = require("config.agent_review.state")

local root = vim.env.AR_STATE_ROOT
assert(state.load(root), "state.load failed")

-- The same hunk body at three different positions/rewrites. Verdicts are keyed
-- by content hash, never by file+line.
local body = { "-context", "+local answer = 42" }
local id = vim.fn.sha256(table.concat(body, "\n"))

local original = { file = "src/a.lua", new_start = 10, new_count = 1, class = "logic", id = id, lines = body }
local moved = { file = "src/a.lua", new_start = 87, new_count = 1, class = "logic", id = id, lines = body }
local rewritten = {
	file = "src/a.lua",
	new_start = 10,
	new_count = 1,
	class = "logic",
	id = vim.fn.sha256("-context\n+local answer = 43"),
	lines = { "-context", "+local answer = 43" },
}

assert(state.set_verdict(original.id, "reject", "usa una constante"))

local reviewed_moved, total_moved = state.progress({ moved })
local reviewed_new, total_new = state.progress({ rewritten })
T.ok(
	"a hunk that only moved keeps its verdict; a rewritten one reads as unreviewed",
	state.get_verdict(moved.id) ~= nil
		and state.get_verdict(rewritten.id) == nil
		and reviewed_moved == 1
		and total_moved == 1
		and reviewed_new == 0
		and total_new == 1,
	vim.inspect({ reviewed_moved, total_moved, reviewed_new, total_new })
)

-- 15. Accepted hunks are not feedback: they must contribute nothing.
local accepted = {
	file = "src/b.lua",
	new_start = 3,
	new_count = 2,
	class = "logic",
	id = vim.fn.sha256("+ok"),
	lines = { "+ok" },
}
assert(state.set_verdict(accepted.id, "accept"))

local only_accepted = state.findings({ accepted })
local mixed = state.findings({ accepted, moved })
T.ok(
	"findings() emits nothing for an accepted hunk",
	#only_accepted == 0
		and #mixed == 1
		and mixed[1].file == "src/a.lua"
		and mixed[1].lnum == 87
		and mixed[1].text == "usa una constante",
	vim.inspect({ only_accepted, mixed })
)

T.finish()
LUA
} >"$TMPROOT/scripts/group_c.lua"

run_nvim "$TMPROOT" sync "$TMPROOT/scripts/group_c.lua" 2 "AR_STATE_ROOT=$TMPROOT/fixture-c"

# =========================================================================
# Group D -- the machine pass (ASYNC)
# =========================================================================

echo "# group D: machine pass"

FIX_D="$TMPROOT/fixture-d"
mkdir -p "$FIX_D/d"

cat >"$FIX_D/d/stub.lua" <<'EOF'
local M = {}

function M.run(a)
  local x = a * 2
  local y = x + 1
  local z = y - 3
  return z
end

return M
EOF

cat >"$FIX_D/d/errors.py" <<'EOF'
def load(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError as exc:
        raise RuntimeError("cannot read") from exc
EOF

cat >"$FIX_D/d/small.lua" <<'EOF'
local n = 1
return n
EOF

git -c init.defaultBranch=main init -q "$FIX_D"
git -C "$FIX_D" config user.email tests@example.invalid
git -C "$FIX_D" config user.name "Agent Review Tests"
git -C "$FIX_D" add -A
git -C "$FIX_D" commit -q -m "initial"

run_nvim "$FIX_D" sync "$TMPROOT/scripts/snapshot.lua" 0 AR_SNAP_ID=snapD

# The agent replaces three lines with four, and the TODO is the third added
# line: the reported line number is only right if "-" lines do NOT advance the
# cursor through the hunk body. That is the off-by-one this check lives on.
cat >"$FIX_D/d/stub.lua" <<'EOF'
local M = {}

function M.run(a)
  local x = a * 2
  local sum = x + 5
  local prod = sum * 2
  -- TODO: handle negative input
  return prod
end

return M
EOF

# A whole try/except block vanishes while "simplifying".
cat >"$FIX_D/d/errors.py" <<'EOF'
def load(path):
    with open(path) as fh:
        return fh.read()
EOF

# An ordinary one-line edit, which must stay silent.
cat >"$FIX_D/d/small.lua" <<'EOF'
local n = 2
return n
EOF

{
	lua_prelude
	cat <<'LUA'
local git = require("config.agent_review.git")
local checks = require("config.agent_review.checks")

local base = "refs/agent-review/snapD"
local root = git.root()

-- Assert against where the TODO actually is, not against a hardcoded number.
local todo_line
for i, line in ipairs(vim.fn.readfile(root .. "/d/stub.lua")) do
	if line:find("TODO", 1, true) then
		todo_line = i
	end
end
assert(todo_line, "fixture lost its TODO")

local t0 = vim.uv.hrtime()

-- If the callback never fires, nvim would sit in the event loop forever.
local watchdog = vim.defer_fn(function()
	T.ok("run() calls back even with no LSP available", false, "no callback after 20s")
	T.quit()
end, 20000)

checks.run(base, function(findings, err)
	watchdog:stop()
	local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6

	if not findings then
		T.ok("checks.run", false, tostring(err))
		T.quit()
		return
	end

	local function pick(file, source)
		local out = {}
		for _, f in ipairs(findings) do
			if f.file == file and f.source == source then
				out[#out + 1] = f
			end
		end
		return out
	end

	-- 16.
	local stubs = pick("d/stub.lua", "stub")
	T.ok(
		"a stub is reported at the exact line, past the hunk's removed lines",
		#stubs == 1 and stubs[1].lnum == todo_line and stubs[1].text:find("TODO", 1, true) ~= nil,
		("todo is on line %d, got %s"):format(todo_line, vim.inspect(stubs))
	)

	-- 17.
	local deletions = pick("d/errors.py", "deletion")
	local noise = pick("d/small.lua", "deletion")
	T.ok(
		"a deleted try/except is flagged; an ordinary small edit is not",
		#deletions == 1 and deletions[1].text:find("error handling removed", 1, true) ~= nil and #noise == 0,
		vim.inspect({ deletions, noise })
	)

	-- 18. With `-u NONE` there is no LSP whatsoever: the attach grace has to
	--     settle the pass instead of burning the full LSP timeout, and the
	--     callback must arrive regardless.
	T.ok(
		"run() calls back even with no LSP available",
		err == nil and #vim.lsp.get_clients() == 0 and elapsed_ms < 10000,
		("err=%s clients=%d elapsed=%dms"):format(tostring(err), #vim.lsp.get_clients(), elapsed_ms)
	)

	if T.failed > 0 then
		T.diag("all findings: " .. vim.inspect(findings))
	end
	T.quit()
end)
LUA
} >"$TMPROOT/scripts/group_d.lua"

run_nvim "$FIX_D" async "$TMPROOT/scripts/group_d.lua" 3

# --- summary --------------------------------------------------------------

echo
printf '1..%d\n' "$N"
if [ "$FAILURES" -eq 0 ]; then
	printf '# %d tests, 0 failures\n' "$N"
	exit 0
fi
printf '# %d tests, %d FAILURES\n' "$N" "$FAILURES"
exit 1
