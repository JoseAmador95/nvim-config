vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = assert(vim.uv.fs_realpath(vim.fn.getcwd()))
local helper = repo .. "/scripts/exact-editor-open"
-- Unix socket paths are limited to roughly 100 bytes on supported hosts. The
-- full gate deliberately nests TMPDIR, so keep this socket-bearing fixture
-- short while retaining per-process uniqueness.
local fixture = ("/tmp/nvim-eeo-%d-%d"):format(vim.uv.os_getpid(), vim.uv.hrtime() % 1000000000)
local state = fixture .. "/state"
local bin = fixture .. "/bin"
local log = fixture .. "/nvim.log"
assert(vim.fn.mkdir(state .. "/editors", "p") == 1)
assert(vim.fn.mkdir(state .. "/requests", "p") == 1)
assert(vim.fn.mkdir(state .. "/waits", "p") == 1)
assert(vim.fn.mkdir(state .. "/sockets", "p") == 1)
assert(vim.fn.mkdir(bin, "p") == 1)
local fake_nvim = bin .. "/nvim"
assert(vim.fn.writefile({
	"#!/usr/bin/env python3",
	"import datetime",
	"import json",
	"import os",
	"import re",
	"import signal",
	"import sys",
	"import time",
	'log = os.environ["FAKE_NVIM_LOG"]',
	[[with open(log, "a", encoding="utf-8") as handle: handle.write(" ".join(sys.argv[1:]) + "\n")]],
	"expression = sys.argv[5]",
	[[if expression == "1":]],
	[[    once = log + ".once"]],
	[[    if os.environ.get("FAKE_NVIM_PROBE_FAIL_ONCE") == "1" and not os.path.exists(once):]],
	[[        open(once, "w", encoding="utf-8").close()]],
	[[        raise SystemExit(7)]],
	[[    if os.environ.get("FAKE_NVIM_PROBE_FAIL") == "1": raise SystemExit(7)]],
	[[    print("1")]],
	[[    raise SystemExit(0)]],
	[[match = re.fullmatch(r'v:lua\.ExactEditorRequest\("([0-9a-f-]+)"\)', expression)]],
	[[if match:]],
	[[    if os.environ.get("FAKE_NVIM_REQUEST_HANG") == "1": time.sleep(10)]],
	[[    request_id = match.group(1)]],
	'    root = os.environ["NVIM_EXACT_EDITOR_STATE_HOME"]',
	[[    request_path = os.path.join(root, "requests", request_id + ".json")]],
	[[    if os.path.isfile(request_path):]],
	[[        with open(request_path, encoding="utf-8") as handle: request = json.load(handle)]],
	[[        if os.environ.get("FAKE_NVIM_REQUEST_LOG"):]],
	[[            with open(os.environ["FAKE_NVIM_REQUEST_LOG"], "w", encoding="utf-8") as handle: json.dump(request, handle)]],
	[[        if request.get("version") == 2:]],
	[[            os.unlink(request_path)]],
	[[            wait_path = os.path.join(root, "waits", request_id + ".json")]],
	[[            mode = os.environ.get("FAKE_NVIM_WAIT_MODE", "valid")]],
	[[            def write_wait(status):]],
	[[                value = {"version": 1, "request_id": request_id, "instance_id": request["instance_id"], "status": status, "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}]],
	[[                temporary = wait_path + ".tmp." + str(os.getpid())]],
	[[                with open(temporary, "w", encoding="utf-8") as handle: json.dump(value, handle); handle.write("\n")]],
	[[                os.chmod(temporary, 0o600)]],
	[[                os.replace(temporary, wait_path)]],
	[[            if mode == "symlink": os.symlink(request_path, wait_path)]],
	[[            elif mode == "malformed":]],
	[[                with open(wait_path, "w", encoding="utf-8") as handle: handle.write("not json\n")]],
	[[                os.chmod(wait_path, 0o600)]],
	[[            elif mode != "missing":]],
	[[                write_wait(os.environ.get("FAKE_NVIM_WAIT_INITIAL", "waiting"))]],
	[[                final = os.environ.get("FAKE_NVIM_WAIT_FINAL")]],
	[[                if final:]],
	[[                    delay = float(os.environ.get("FAKE_NVIM_WAIT_DELAY", "0"))]],
	[[                    if delay:]],
	[[                        child = os.fork()]],
	[[                        if child == 0:]],
	[[                            with open(os.devnull, "w") as devnull:]],
	[[                                os.dup2(devnull.fileno(), 1)]],
	[[                                os.dup2(devnull.fileno(), 2)]],
	[[                            time.sleep(delay)]],
	[[                            write_wait(final)]],
	[[                            os._exit(0)]],
	[[                    else: write_wait(final)]],
	[[kill_pid = os.environ.get("FAKE_NVIM_KILL_PID")]],
	[[if kill_pid: os.kill(int(kill_pid), signal.SIGTERM)]],
	[[print(os.environ.get("FAKE_NVIM_FINAL", "1"))]],
}, fake_nvim) == 0)
assert(vim.fn.setfperm(fake_nvim, "rwxr-xr-x") == 1)

local failures = {}
local count = 0
local socket_handles = {}

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
	for _, handle in ipairs(socket_handles) do
		if not handle:is_closing() then
			handle:close()
		end
	end
	socket_handles = {}
	vim.fn.delete(state .. "/editors", "rf")
	vim.fn.delete(state .. "/requests", "rf")
	vim.fn.delete(state .. "/waits", "rf")
	vim.fn.delete(state .. "/sockets", "rf")
	assert(vim.fn.mkdir(state .. "/editors", "p") == 1)
	assert(vim.fn.mkdir(state .. "/requests", "p") == 1)
	assert(vim.fn.mkdir(state .. "/waits", "p") == 1)
	assert(vim.fn.mkdir(state .. "/sockets", "p") == 1)
	vim.fn.delete(log)
	vim.fn.delete(log .. ".once")
end

local function record(id, pid, workspaces, pane, legacy)
	local socket = state .. "/sockets/" .. id:sub(1, 8) .. ".sock"
	local pipe = assert(vim.uv.new_pipe(false))
	assert(pipe:bind(socket))
	assert(pipe:listen(16, function() end))
	assert(vim.uv.fs_chmod(socket, tonumber("600", 8)))
	socket_handles[#socket_handles + 1] = pipe
	local value = {
		version = 2,
		instance_id = id,
		pid = pid or vim.uv.os_getpid(),
		socket = socket,
		workspaces = workspaces or { { runtime = "host", root = repo, repo_identity = repo } },
		TMUX_PANE = pane or vim.NIL,
		updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	if legacy then
		value.version = 1
		value.repo_roots = { repo }
		value.workspaces = nil
	end
	local path = state .. "/editors/" .. id .. ".json"
	assert(vim.fn.writefile({ vim.json.encode(value) }, path) == 0)
	assert(vim.fn.setfperm(path, "rw-------") == 1)
	return path, socket
end

local function environment(extra_env)
	local environment = {
		NVIM_EXACT_EDITOR_STATE_HOME = state,
		FAKE_NVIM_LOG = log,
		HOME = vim.env.HOME or fixture,
		PATH = bin .. ":" .. vim.env.PATH,
		PYTHONPYCACHEPREFIX = fixture .. "/pycache",
	}
	for key, value in pairs(extra_env or {}) do
		environment[key] = value
	end
	return environment
end

local function invoke(extra_env, file, line, column, workspace, tmux_pane)
	local command = {
		helper,
		"--cwd",
		repo,
		"--file",
		file or "README.md",
		"--line",
		tostring(line or 1),
		"--column",
		tostring(column or 1),
	}
	if workspace then
		vim.list_extend(command, {
			"--runtime",
			workspace.runtime,
			"--workspace-root",
			workspace.root,
			"--repo-identity",
			workspace.repo_identity,
		})
	end
	if tmux_pane then
		command[#command + 1] = "--tmux-pane"
		command[#command + 1] = tmux_pane
	end
	return vim.system(command, { text = true, env = environment(extra_env), clear_env = true }):wait()
end

local function invoke_editor(extra_env, file, signal_ready, tmux_pane, wait_timeout)
	local command = { helper, "--wait-editor" }
	if signal_ready then
		command[#command + 1] = "--signal-ready"
	end
	if tmux_pane then
		command[#command + 1] = "--tmux-pane"
		command[#command + 1] = tmux_pane
	end
	if wait_timeout then
		command[#command + 1] = "--wait-timeout"
		command[#command + 1] = tostring(wait_timeout)
	end
	command[#command + 1] = file
	return vim.system(command, { text = true, env = environment(extra_env), clear_env = true, cwd = repo }):wait(5000)
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
	local dead, dead_socket = record("11111111-1111-4111-8111-111111111111", 2147483647)
	local stale = state .. "/requests/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json"
	local stale_wait = state .. "/waits/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.json"
	assert(vim.fn.writefile({ "{}" }, stale) == 0)
	assert(vim.fn.writefile({ "{}" }, stale_wait) == 0)
	local old = os.time() - 3600
	assert(vim.uv.fs_utime(stale, old, old))
	assert(vim.uv.fs_utime(stale_wait, old - 8 * 24 * 60 * 60, old - 8 * 24 * 60 * 60))
	local result = invoke()
	assert(result.code ~= 0)
	assert(vim.uv.fs_lstat(dead) == nil, "dead registry was not pruned")
	assert(vim.uv.fs_lstat(dead_socket) == nil, "dead registry socket was not pruned")
	assert(vim.uv.fs_lstat(stale) == nil, "stale request was not pruned")
	assert(vim.uv.fs_lstat(stale_wait) == nil, "stale wait state was not pruned")
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

test("version-1 registry records remain selectable as host workspaces", function()
	reset()
	record("15151515-1515-4515-8515-151515151515", nil, nil, nil, true)
	local result = invoke()
	assert(result.code == 0, result.stderr)
	assert(#calls() == 2)
	assert(calls()[2]:match('v:lua%.ExactEditorRequest%("[0-9a-f%-]+"%)$'))
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

test("a live record with a missing socket fails closed and is retained", function()
	reset()
	local live, socket = record("14141414-1414-4414-8414-141414141414")
	assert(vim.uv.fs_unlink(socket))
	local result = invoke()
	assert(result.code == 2 and result.stderr:find("temporarily unreachable; retry", 1, true), result.stderr)
	assert(vim.uv.fs_lstat(live), "active broken registry was incorrectly cleaned")
	assert(#calls() == 0, "missing socket was passed to nvim")
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

test("normal requests can bind selection to one exact tmux pane", function()
	reset()
	local other_id = "25252525-2525-4525-8525-252525252525"
	local expected_id = "35353535-3535-4535-8535-353535353535"
	record(other_id, nil, nil, "%41")
	record(expected_id, nil, nil, "%42")
	local result = invoke(nil, "README.md", 1, 1, nil, "%42")
	assert(result.code == 0, result.stderr)
	local files = vim.fn.glob(state .. "/requests/*.json", false, true)
	assert(#files == 1)
	local request = vim.json.decode(table.concat(vim.fn.readfile(files[1]), "\n"))
	assert(request.instance_id == expected_id, "normal request selected a different tmux pane")
	local invalid = invoke(nil, "README.md", 1, 1, nil, "not-a-pane")
	assert(invalid.code ~= 0 and invalid.stderr:find("exact tmux pane id", 1, true), invalid.stderr)
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
	assert(final:match('v:lua%.ExactEditorRequest%("[0-9a-f%-]+"%)$'))
	assert(not final:find("README.md", 1, true) and not final:find(repo, 1, true), "raw path reached remote expression")
	assert_server_only()
end)

test("workspace runtime, root, and repository identity select exactly one editor", function()
	reset()
	local host_id = "45454545-4545-4545-8545-454545454545"
	local container_id = "56565656-5656-4656-8656-565656565656"
	local identity = "logical-repository"
	record(host_id, nil, { { runtime = "host", root = repo, repo_identity = identity } })
	record(container_id, nil, {
		{ runtime = "container", root = "/workspaces/project", repo_identity = identity },
	})
	local result = invoke(nil, "README.md", 1, 1, {
		runtime = "container",
		root = "/workspaces/project",
		repo_identity = identity,
	})
	assert(result.code == 0, result.stderr)
	local files = vim.fn.glob(state .. "/requests/*.json", false, true)
	assert(#files == 1)
	local request = vim.json.decode(table.concat(vim.fn.readfile(files[1]), "\n"))
	assert(request.instance_id == container_id and request.repo_root == "/workspaces/project")
end)

test("a complete environment triplet selects the container workspace", function()
	reset()
	local host_id = "61616161-6161-4161-8161-616161616161"
	local container_id = "62626262-6262-4262-8262-626262626262"
	local identity = "logical-environment-repository"
	record(host_id, nil, { { runtime = "host", root = repo, repo_identity = repo } })
	record(container_id, nil, {
		{ runtime = "container", root = "/workspaces/environment", repo_identity = identity },
	})
	local result = invoke({
		NVIM_EXACT_EDITOR_RUNTIME = "container",
		NVIM_EXACT_EDITOR_WORKSPACE_ROOT = "/workspaces/environment",
		NVIM_EXACT_EDITOR_REPO_IDENTITY = identity,
	})
	assert(result.code == 0, result.stderr)
	local files = vim.fn.glob(state .. "/requests/*.json", false, true)
	assert(#files == 1)
	local request = vim.json.decode(table.concat(vim.fn.readfile(files[1]), "\n"))
	assert(request.instance_id == container_id and request.repo_root == "/workspaces/environment")
end)

test("a complete command-line triplet overrides a conflicting environment", function()
	reset()
	local cli_id = "63636363-6363-4363-8363-636363636363"
	local env_id = "64646464-6464-4464-8464-646464646464"
	record(cli_id, nil, {
		{ runtime = "container", root = "/workspaces/cli", repo_identity = "cli-repository" },
	})
	record(env_id, nil, {
		{ runtime = "container", root = "/workspaces/environment", repo_identity = "env-repository" },
	})
	local result = invoke(
		{
			NVIM_EXACT_EDITOR_RUNTIME = "container",
			NVIM_EXACT_EDITOR_WORKSPACE_ROOT = "/workspaces/environment",
			NVIM_EXACT_EDITOR_REPO_IDENTITY = "env-repository",
		},
		nil,
		nil,
		nil,
		{
			runtime = "container",
			root = "/workspaces/cli",
			repo_identity = "cli-repository",
		}
	)
	assert(result.code == 0, result.stderr)
	local files = vim.fn.glob(state .. "/requests/*.json", false, true)
	assert(#files == 1)
	local request = vim.json.decode(table.concat(vim.fn.readfile(files[1]), "\n"))
	assert(request.instance_id == cli_id and request.repo_root == "/workspaces/cli")
end)

test("partial command-line and environment identities fail before editor lookup", function()
	reset()
	record("65656565-6565-4565-8565-656565656565")
	local base = { helper, "--cwd", repo, "--file", "README.md" }
	local command = vim.deepcopy(base)
	vim.list_extend(command, { "--runtime", "container" })
	local result = vim.system(command, {
		text = true,
		env = environment(),
		clear_env = true,
	}):wait()
	assert(result.code ~= 0 and result.stderr:find("requires runtime, root, and repository identity", 1, true))
	assert(#calls() == 0, "partial command-line identity reached editor lookup")

	result = vim.system(base, {
		text = true,
		env = environment({ NVIM_EXACT_EDITOR_RUNTIME = "container" }),
		clear_env = true,
	}):wait()
	assert(result.code ~= 0 and result.stderr:find("requires runtime, root, and repository identity", 1, true))
	assert(#calls() == 0, "partial environment identity reached editor lookup")
end)

test("wait-editor inherits the exact environment workspace without raw path transport", function()
	reset()
	local id = "66666666-6666-4666-8666-666666666666"
	local identity = "blocking-environment-repository"
	record(id, nil, {
		{ runtime = "container", root = "/workspaces/blocking", repo_identity = identity },
	})
	local target = vim.fn.tempname()
	local request_log = fixture .. "/environment-wait-request.json"
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local result = invoke_editor({
		NVIM_EXACT_EDITOR_RUNTIME = "container",
		NVIM_EXACT_EDITOR_WORKSPACE_ROOT = "/workspaces/blocking",
		NVIM_EXACT_EDITOR_REPO_IDENTITY = identity,
		FAKE_NVIM_REQUEST_LOG = request_log,
		FAKE_NVIM_WAIT_INITIAL = "completed",
	}, target)
	assert(result.code == 0, result.stderr)
	local request = vim.json.decode(table.concat(vim.fn.readfile(request_log), "\n"))
	assert(request.instance_id == id and request.repo_root == "/workspaces/blocking")
	vim.fn.delete(target)
end)

test("corrupt permissions are cleaned and symlinked registry entries fail closed", function()
	reset()
	local corrupt = record("57575757-5757-4757-8757-575757575757")
	assert(vim.fn.setfperm(corrupt, "rw-r--r--") == 1)
	local result = invoke()
	assert(result.code == 3, result.stderr)
	assert(vim.uv.fs_lstat(corrupt) == nil, "corrupt record was not cleaned")

	reset()
	local target = fixture .. "/hostile-record"
	assert(vim.fn.writefile({ "{}" }, target) == 0)
	assert(vim.uv.fs_symlink(target, state .. "/editors/hostile.json"))
	result = invoke()
	assert(result.code == 2 and result.stderr:find("unsafe entry", 1, true), result.stderr)
	assert(vim.uv.fs_lstat(state .. "/editors/hostile.json").type == "link")
end)

test("wait-editor sends exact version-2 request, signals readiness, and blocks until completion", function()
	reset()
	local id = "46464646-4646-4646-8646-464646464646"
	record(id)
	local target = vim.fn.tempname() .. " gh body ; literal.md"
	local request_log = fixture .. "/request.json"
	assert(vim.fn.writefile({ "pull request body" }, target) == 0)
	local canonical = assert(vim.uv.fs_realpath(target))
	local started = vim.uv.hrtime()
	local result = invoke_editor({
		FAKE_NVIM_REQUEST_LOG = request_log,
		FAKE_NVIM_WAIT_FINAL = "completed",
		FAKE_NVIM_WAIT_DELAY = "0.15",
	}, target, true)
	local elapsed = (vim.uv.hrtime() - started) / 1e9
	assert(result.code == 0, result.stderr)
	assert(result.stdout == "READY\n", "readiness output changed: " .. tostring(result.stdout))
	assert(elapsed >= 0.1, "helper returned before durable completion")
	local request_value = vim.json.decode(table.concat(vim.fn.readfile(request_log), "\n"))
	local request_keys = vim.tbl_keys(request_value)
	table.sort(request_keys)
	assert(
		vim.deep_equal(request_keys, { "created_at", "instance_id", "path", "repo_root", "request_id", "version" }),
		"version-2 request keys changed"
	)
	assert(request_value.version == 2 and request_value.instance_id == id)
	assert(request_value.repo_root == repo and request_value.path == canonical)
	local final = calls()[2]
	assert(final:match('v:lua%.ExactEditorRequest%("[0-9a-f%-]+"%)$'))
	assert(not final:find(target, 1, true) and not final:find(repo, 1, true), "raw path reached remote expression")
	assert(#vim.fn.glob(state .. "/requests/*.json", false, true) == 0)
	assert(#vim.fn.glob(state .. "/waits/*.json", false, true) == 0)
	vim.fn.delete(target)
end)

test("wait-editor accepts completion before polling and reports an aborted edit", function()
	reset()
	record("47474747-4747-4747-8747-474747474747")
	local target = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local completed = invoke_editor({ FAKE_NVIM_WAIT_INITIAL = "completed" }, target)
	assert(completed.code == 0, completed.stderr)

	reset()
	record("48484848-4848-4848-8848-484848484848")
	local aborted = invoke_editor({ FAKE_NVIM_WAIT_INITIAL = "aborted" }, target)
	assert(aborted.code ~= 0 and aborted.stderr:find("without saving", 1, true))
	assert(#vim.fn.glob(state .. "/waits/*.json", false, true) == 0)
	vim.fn.delete(target)
end)

test("wait-editor can bind selection to one exact tmux pane", function()
	reset()
	local other_id = "49494949-4949-4949-8949-494949494949"
	local expected_id = "50505050-5050-4050-8050-505050505050"
	record(other_id, nil, nil, "%41")
	record(expected_id, nil, nil, "%42")
	local target = vim.fn.tempname()
	local request_log = fixture .. "/pane-request.json"
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local result = invoke_editor({
		FAKE_NVIM_REQUEST_LOG = request_log,
		FAKE_NVIM_WAIT_INITIAL = "completed",
	}, target, false, "%42")
	assert(result.code == 0, result.stderr)
	local request = vim.json.decode(table.concat(vim.fn.readfile(request_log), "\n"))
	assert(request.instance_id == expected_id, "wait-editor selected a different tmux pane")
	local invalid = invoke_editor(nil, target, false, "not-a-pane")
	assert(invalid.code ~= 0 and invalid.stderr:find("exact tmux pane id", 1, true), invalid.stderr)
	vim.fn.delete(target)
end)

test("wait-editor bounds an unresponsive RPC delivery", function()
	reset()
	record("54545454-5454-4454-8454-545454545454")
	local target = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local started = vim.uv.hrtime()
	local result = invoke_editor({ FAKE_NVIM_REQUEST_HANG = "1" }, target)
	local elapsed = (vim.uv.hrtime() - started) / 1e9
	assert(result.code ~= 0 and result.stderr:find("timed out", 1, true), result.stderr)
	assert(elapsed < 3, "RPC timeout was not bounded")
	assert(#vim.fn.glob(state .. "/requests/*.json", false, true) == 0)
	vim.fn.delete(target)
end)

test("wait-editor bounds a live editor that never completes", function()
	reset()
	record("58585858-5858-4858-8858-585858585858")
	local target = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local result = invoke_editor(nil, target, false, nil, 0.1)
	assert(result.code == 2 and result.stderr:find("timed out waiting", 1, true), result.stderr)
	assert(#vim.fn.glob(state .. "/waits/*.json", false, true) == 0)
	vim.fn.delete(target)
end)

test("wait-editor rejects missing, malformed, and symlinked durable state", function()
	local target = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local ids = {
		"51515151-5151-4151-8151-515151515151",
		"52525252-5252-4252-8252-525252525252",
		"53535353-5353-4353-8353-535353535353",
	}
	for index, mode in ipairs({ "missing", "malformed", "symlink" }) do
		reset()
		record(ids[index])
		local result = invoke_editor({ FAKE_NVIM_WAIT_MODE = mode }, target)
		assert(result.code ~= 0, mode .. " wait state unexpectedly succeeded")
		assert(result.stderr:find("wait state", 1, true), result.stderr)
	end
	vim.fn.delete(target)
end)

test("wait-editor fails closed when the selected editor dies while waiting", function()
	reset()
	local sleeper = vim.system({ "sleep", "10" })
	assert(type(sleeper.pid) == "number" and sleeper.pid > 0)
	record("69696969-6969-4969-8969-696969696969", sleeper.pid)
	local target = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	local result = invoke_editor({ FAKE_NVIM_KILL_PID = tostring(sleeper.pid) }, target)
	assert(result.code ~= 0 and result.stderr:find("exited before editing completed", 1, true), result.stderr)
	sleeper:wait(1000)
	assert(#vim.fn.glob(state .. "/waits/*.json", false, true) == 0)
	vim.fn.delete(target)
end)

test("wait-editor rejects symlink and binary targets before editor lookup", function()
	reset()
	local target = vim.fn.tempname()
	local link = fixture .. "/editor-target-link"
	local binary = vim.fn.tempname()
	assert(vim.fn.writefile({ "text" }, target) == 0)
	assert(vim.uv.fs_symlink(target, link))
	local binary_file = assert(io.open(binary, "wb"))
	assert(binary_file:write("binary\0payload"))
	assert(binary_file:close())
	for _, unsafe in ipairs({ link, binary }) do
		local result = invoke_editor(nil, unsafe)
		assert(result.code ~= 0, "unsafe editor target succeeded")
	end
	assert(#calls() == 0)
	vim.fn.delete(target)
	vim.fn.delete(link)
	vim.fn.delete(binary)
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
	local link = repo .. "/.exact-editor-open-escape"
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

print(string.format("exact_editor_open_spec: %d tests passed", count))
vim.cmd("quitall!")
