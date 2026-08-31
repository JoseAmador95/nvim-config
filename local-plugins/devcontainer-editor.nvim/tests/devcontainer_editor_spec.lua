vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

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

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture .. "/repo/sub", "p") == 1)
assert(vim.fn.mkdir(fixture .. "/state/workspaces", "p") == 1)
assert(vim.fn.mkdir(fixture .. "/spool", "p") == 1)
assert(vim.fn.writefile({ "hello" }, fixture .. "/repo/sub/file.txt") == 0)
local repo = assert(vim.uv.fs_realpath(fixture .. "/repo"))
local state = assert(vim.uv.fs_realpath(fixture .. "/state"))
local spool = assert(vim.uv.fs_realpath(fixture .. "/spool"))
local token = string.rep("s", 32)
local original_env = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_DEVCONTAINER_TOKEN = vim.env.NVIM_DEVCONTAINER_TOKEN,
	NVIM_DEVCONTAINER_CONTAINER_ROOT = vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT,
	NVIM_DEVCONTAINER_SPOOL_ROOT = vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
}

vim.env.NVIM_DEVCONTAINER = "1"
vim.env.NVIM_DEVCONTAINER_TOKEN = token
vim.env.NVIM_DEVCONTAINER_CONTAINER_ROOT = repo
vim.env.NVIM_DEVCONTAINER_SPOOL_ROOT = spool
vim.env.NVIM_CONFIG_OFFLINE = "1"

local opened
local plugin_module = require("devcontainer_editor")
plugin_module.setup({
	state_root = state,
	spool_root = spool,
	launcher = "/bin/devcontainer-editor",
	watch = false,
	uuid = function()
		return "00000000-0000-4000-8000-000000000001"
	end,
	open = function(path, position)
		opened = { path = path, position = position }
	end,
})

test("workspace identity is exact, lexical, and copied", function()
	local input = { runtime = "container", root = "/workspaces/project", repo_identity = repo }
	local value = assert(plugin_module.workspace_key(input))
	input.runtime = "changed"
	assert(value.runtime == "container")
	assert(
		plugin_module.workspace_key({ runtime = "container", root = "/workspaces/../tmp", repo_identity = repo }) == nil
	)
	assert(plugin_module.workspace_key({ runtime = "container", root = "relative", repo_identity = repo }) == nil)
	assert(plugin_module.workspace_key({
		runtime = "container",
		root = "/workspaces/project",
		repo_identity = repo,
		injected = true,
	}) == nil)
end)

test("routing is contained and rejects traversal through symlinks", function()
	local routed = assert(plugin_module.route("sub/file.txt", repo, "/workspaces/project", "file"))
	assert(routed == "/workspaces/project/sub/file.txt")
	assert(plugin_module.route("../outside", repo, "/workspaces/project", "file") == nil)
	assert(vim.uv.fs_symlink("/tmp", repo .. "/escape") == true)
	assert(plugin_module.route("escape/file", repo, "/workspaces/project", "file") == nil)
end)

test("authenticated inbox opens one exact contained file and writes a private ACK", function()
	assert(plugin_module._prepare_spool(spool))
	local request_id = "00000000-0000-4000-8000-000000000002"
	local request = {
		version = 1,
		token = token,
		request_id = request_id,
		action = "open_location",
		path = "sub/file.txt",
		line = 7,
		column = 3,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local path = spool .. "/inbox/" .. request_id .. ".json"
	assert(plugin_module._atomic_write(path, vim.json.encode(request) .. "\n"))
	assert(plugin_module.consume_spool_once() == 1)
	assert(opened.path == repo .. "/sub/file.txt")
	assert(opened.position.lnum == 7 and opened.position.col == 3)
	local ack_path = spool .. "/acks/" .. request_id .. ".json"
	local ack = vim.json.decode(assert(plugin_module._secure_read(ack_path, "ack")))
	assert(ack.ok == true and ack.token == token and ack.request_id == request_id)
	assert(vim.uv.fs_lstat(ack_path).mode % 512 == tonumber("600", 8))
end)

test("wrong-token and traversal requests fail closed", function()
	for index, fields in ipairs({
		{ token = "wrong", path = "sub/file.txt" },
		{ token = token, path = "../outside" },
	}) do
		local request_id = ("00000000-0000-4000-8000-%012d"):format(index + 10)
		local request = {
			version = 1,
			token = fields.token,
			request_id = request_id,
			action = "open_location",
			path = fields.path,
			line = 1,
			column = 1,
			created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		local path = spool .. "/inbox/" .. request_id .. ".json"
		assert(plugin_module._atomic_write(path, vim.json.encode(request) .. "\n"))
		assert(plugin_module.consume_spool_once() == 1)
		assert(vim.uv.fs_lstat(path) == nil)
	end
end)

test("host requests use an authenticated private spool and exact allowlist", function()
	local callback_value
	local function defer(callback)
		local request_path = spool .. "/outbox/00000000-0000-4000-8000-000000000001.json"
		local request = vim.json.decode(assert(plugin_module._secure_read(request_path, "request")))
		local ack = {
			version = 1,
			token = token,
			request_id = request.request_id,
			ok = true,
			action = request.action,
			error = vim.NIL,
		}
		assert(plugin_module._atomic_write(spool .. "/acks/" .. request.request_id .. ".json", vim.json.encode(ack)))
		callback()
	end
	assert(plugin_module.request_host("lazygit", { defer = defer }, function(value)
		callback_value = value
	end))
	assert(callback_value.action == "lazygit")
	assert(plugin_module.request_host("publish") == nil)
	assert(plugin_module.request_host("execute") == nil)
end)

test("offline authorization and lifecycle argv are explicit", function()
	assert(plugin_module.in_workspace())
	assert(not plugin_module.network_authorized())
	local argv = assert(plugin_module.lifecycle_argv("up", {
		root = repo,
		recreate = true,
		allow_network = true,
	}))
	assert(vim.deep_equal(argv, {
		"/bin/devcontainer-editor",
		"up",
		"--repo",
		repo,
		"--recreate",
		"--allow-network",
	}))
	assert(plugin_module.lifecycle_argv("delete", {}) == nil)
end)

test("workspace status rejects hostile state and returns immutable copies", function()
	local record = {
		version = 1,
		host_root = repo,
		config_path = repo .. "/.devcontainer/devcontainer.json",
		container_root = "/workspaces/project",
		container_id = "container",
		workspace_key = { runtime = "container", root = "/workspaces/project", repo_identity = repo },
		pid = 1,
		status = "running",
		network_authorized = false,
		ssh_agent_forwarding = false,
		token = token,
		tmux_pane = vim.NIL,
		log_path = state .. "/log",
		updated_at = "2026-08-31T00:00:00Z",
		exit_code = vim.NIL,
		error = vim.NIL,
	}
	local path = state .. "/workspaces/" .. vim.fn.sha256(repo) .. ".json"
	assert(plugin_module._atomic_write(path, vim.json.encode(record)))
	local first = assert(plugin_module.status(repo))
	assert(first.token == nil and first.workspace_key.runtime == "container")
	first.workspace_key.runtime = "changed"
	assert(assert(plugin_module.status(repo)).workspace_key.runtime == "container")
	assert(vim.uv.fs_unlink(path))
	assert(vim.uv.fs_symlink(repo .. "/sub/file.txt", path))
	assert(plugin_module.status(repo) == nil)
end)

plugin_module.stop()
for name, value in pairs(original_env) do
	vim.env[name] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("devcontainer_editor_spec: %d tests passed", count))
vim.cmd("quitall!")
