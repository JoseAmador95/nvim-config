vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = assert(vim.uv.fs_realpath(vim.fn.getcwd()))
local helper = repo .. "/scripts/nvim-review-open"
local fixture = vim.fn.tempname()
local state = fixture .. "/state"
local bin = fixture .. "/bin"
local log = fixture .. "/nvim.log"
assert(vim.fn.mkdir(state .. "/editors", "p") == 1)
assert(vim.fn.mkdir(state .. "/requests", "p") == 1)
assert(vim.fn.mkdir(bin, "p") == 1)
local fake_nvim = bin .. "/nvim"
assert(vim.fn.writefile({
	"#!/bin/sh",
	[[printf '%s\n' "$*" >> "$FAKE_NVIM_LOG"]],
	[[if [ "$5" = "1" ]; then]],
	[[  if [ "${FAKE_NVIM_PROBE_FAIL_ONCE:-}" = 1 ] && [ ! -e "$FAKE_NVIM_LOG.once" ]; then printf 'failed\n' > "$FAKE_NVIM_LOG.once"; exit 7; fi]],
	[[  [ "${FAKE_NVIM_PROBE_FAIL:-}" != 1 ] || exit 7]],
	[[  printf '1\n']],
	[[else]],
	[[  printf '%s\n' "${FAKE_NVIM_FINAL:-1}"]],
	[[fi]],
	"exit 0",
}, fake_nvim) == 0)
assert(vim.fn.setfperm(fake_nvim, "rwxr-xr-x") == 1)

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function reset()
	vim.fn.delete(state .. "/editors", "rf")
	vim.fn.delete(state .. "/requests", "rf")
	assert(vim.fn.mkdir(state .. "/editors", "p") == 1)
	assert(vim.fn.mkdir(state .. "/requests", "p") == 1)
	vim.fn.delete(log)
	vim.fn.delete(log .. ".once")
end

local function record(id, pid, roots)
	local value = {
		version = 1,
		instance_id = id,
		pid = pid or vim.uv.os_getpid(),
		socket = fixture .. "/" .. id .. ".sock",
		repo_roots = roots or { repo },
		TMUX_PANE = vim.NIL,
		updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local path = state .. "/editors/" .. id .. ".json"
	assert(vim.fn.writefile({ vim.json.encode(value) }, path) == 0)
	assert(vim.fn.setfperm(path, "rw-------") == 1)
	return path
end

local function invoke(extra_env, file, line, column)
	local environment = {
		NVIM_REVIEW_STATE_HOME = state,
		FAKE_NVIM_LOG = log,
		PATH = bin .. ":" .. vim.env.PATH,
		PYTHONPYCACHEPREFIX = fixture .. "/pycache",
	}
	for key, value in pairs(extra_env or {}) do
		environment[key] = value
	end
	return vim.system({
		helper,
		"--cwd",
		repo,
		"--file",
		file or "README.md",
		"--line",
		tostring(line or 1),
		"--column",
		tostring(column or 1),
	}, { text = true, env = environment }):wait()
end

local function calls()
	if vim.fn.filereadable(log) ~= 1 then
		return {}
	end
	return vim.fn.readfile(log)
end

local function assert_server_only()
	for _, call in ipairs(calls()) do
		assert(call:sub(1, 20) == "--headless --server ", "nvim call omitted headless server mode: " .. call)
		assert(call:find(" --remote-expr ", 1, true), "nvim call omitted --remote-expr")
	end
end

test("zero live editors fails without plain-nvim fallback", function()
	reset()
	local result = invoke()
	assert(result.code ~= 0 and result.stderr:find("no live registered editor", 1, true))
	assert(#calls() == 0)
end)

test("dead records and stale requests are pruned at entry", function()
	reset()
	local dead = record("11111111-1111-4111-8111-111111111111", 2147483647)
	local stale = state .. "/requests/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"
	assert(vim.fn.writefile({ "{}" }, stale) == 0)
	local old = os.time() - 3600
	assert(vim.uv.fs_utime(stale, old, old))
	local result = invoke()
	assert(result.code ~= 0)
	assert(vim.uv.fs_lstat(dead) == nil, "dead registry was not pruned")
	assert(vim.uv.fs_lstat(stale) == nil, "stale request was not pruned")
	assert(#calls() == 0)
end)

test("a transient probe failure is retried before delivering the request", function()
	reset()
	local live = record("12121212-1212-4212-8212-121212121212")
	local result = invoke({ FAKE_NVIM_PROBE_FAIL_ONCE = "1" })
	assert(result.code == 0, result.stderr)
	assert(vim.uv.fs_lstat(live), "transient probe failure deleted a live registry")
	assert(#calls() == 3, "expected one failed probe, one successful probe, and one request")
	assert_server_only()
end)

test("a persistently unreachable editor fails closed after bounded retries", function()
	reset()
	local live = record("13131313-1313-4313-8313-131313131313")
	local result = invoke({ FAKE_NVIM_PROBE_FAIL = "1" })
	assert(result.code ~= 0 and result.stderr:find("temporarily unreachable; retry", 1, true))
	assert(vim.uv.fs_lstat(live), "unreachable live registry was deleted")
	assert(#calls() == 3, "persistent probe was not bounded to three attempts")
	assert_server_only()
end)

test("multiple matching live editors fail visibly after server-only probes", function()
	reset()
	record("22222222-2222-4222-8222-222222222222")
	record("33333333-3333-4333-8333-333333333333")
	local result = invoke()
	assert(result.code ~= 0 and result.stderr:find("multiple live", 1, true))
	assert(#calls() == 2)
	assert_server_only()
end)

test("a transiently unreachable peer cannot conceal editor ambiguity", function()
	reset()
	record("24242424-2424-4424-8424-242424242424")
	record("34343434-3434-4434-8434-343434343434")
	local result = invoke({ FAKE_NVIM_PROBE_FAIL_ONCE = "1" })
	assert(result.code ~= 0 and result.stderr:find("multiple live", 1, true))
	assert(#calls() == 4, "both editors were not reprobed before ambiguity resolution")
	assert_server_only()
end)

test("one exact editor receives only opaque UUID and exact line and column", function()
	reset()
	local id = "44444444-4444-4444-8444-444444444444"
	record(id)
	local result = invoke(nil, "README.md", 37, 11)
	assert(result.code == 0, result.stderr)
	local request_files = vim.fn.glob(state .. "/requests/*.json", false, true)
	assert(#request_files == 1)
	local request = vim.json.decode(table.concat(vim.fn.readfile(request_files[1]), "\n"))
	assert(request.instance_id == id and request.repo_root == repo and request.path == "README.md")
	assert(request.line == 37 and request.column == 11)
	assert(assert(vim.uv.fs_lstat(request_files[1])).mode % 512 == 384, "request is not 0600")
	local all_calls = calls()
	assert(#all_calls == 2)
	local final = all_calls[2]
	assert(final:match('v:lua%.NvimReviewOpenRequest%("[0-9a-f%-]+"%)$'))
	assert(not final:find("README.md", 1, true) and not final:find(repo, 1, true), "raw path reached remote expression")
	assert_server_only()
end)

test("non-acknowledging editor fails and removes its request", function()
	reset()
	record("55555555-5555-4555-8555-555555555555")
	local result = invoke({ FAKE_NVIM_FINAL = "not-one" })
	assert(result.code ~= 0 and result.stderr:find("rejected", 1, true))
	assert(#vim.fn.glob(state .. "/requests/*.json", false, true) == 0)
	assert_server_only()
end)

test("target containment rejects symlink escape before editor lookup", function()
	reset()
	local outside = vim.fn.tempname()
	local link = repo .. "/.nvim-review-open-escape"
	assert(vim.fn.writefile({ "outside" }, outside) == 0)
	assert(vim.uv.fs_symlink(outside, link))
	local result = invoke(nil, link)
	vim.fn.delete(link)
	vim.fn.delete(outside)
	assert(result.code ~= 0 and result.stderr:find("outside the repository", 1, true))
	assert(#calls() == 0)
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("nvim_review_open_spec: %d tests passed", count))
vim.cmd("quitall!")
