vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = assert(vim.uv.fs_realpath(vim.fn.getcwd() .. "/local-plugins/exact-editor.nvim"))
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	vim.fn.getcwd() .. "/local-plugins/_shared/lua/?.lua",
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	package.path,
}, ";")

local exact = require("exact_editor")
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
local state = fixture .. "/state"
local root = fixture .. "/repo"
assert(vim.fn.mkdir(root, "p") == 1)

assert(not exact._normalize_workspace({
	runtime = "host",
	root = root,
	repo_identity = root,
	injected = true,
}))
root = assert(vim.uv.fs_realpath(root))
assert(vim.fn.writefile({ "return true" }, root .. "/target.lua") == 0)
assert(exact._prepare_state(state))

local workspace = { runtime = "host", root = root, repo_identity = "repo:test" }
local instance = {
	root = state,
	instance_id = "12345678-1234-4234-8234-123456789abc",
	pid = vim.uv.os_getpid(),
	socket = state .. "/sockets/exact.sock",
	workspaces = { [exact._workspace_identity(workspace)] = workspace },
}

local function private_json(path, value)
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	local encoded = vim.json.encode(value) .. "\n"
	assert(vim.uv.fs_write(fd, encoded, 0) == #encoded)
	assert(vim.uv.fs_fsync(fd))
	assert(vim.uv.fs_close(fd))
	assert(vim.uv.fs_chmod(path, tonumber("600", 8)))
end

local function normal_request(id, overrides)
	local value = {
		version = 1,
		request_id = id,
		instance_id = instance.instance_id,
		repo_root = root,
		path = "target.lua",
		line = 4,
		column = 2,
		created_at = "2026-08-31T10:00:00Z",
	}
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return value
end

local function request_path(id)
	return state .. "/requests/" .. id .. ".json"
end

test("registry persists an exact WorkspaceKey and returns detached values", function()
	local record = assert(exact.write_registry(instance))
	assert(record.version == 2)
	assert(vim.deep_equal(record.workspaces, { workspace }))
	record.workspaces[1].runtime = "container"
	assert(instance.workspaces[exact._workspace_identity(workspace)].runtime == "host")
	local path = state .. "/editors/" .. instance.instance_id .. ".json"
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == tonumber("600", 8))
end)

test("normal RPC opens one contained file and consumes the private request", function()
	local id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	private_json(request_path(id), normal_request(id))
	local opened
	local handled, err = exact.consume_normal(id, instance, {
		open_file = function(path, position)
			opened = { path = path, position = position }
		end,
	})
	assert(handled == 1, err)
	assert(opened.path == root .. "/target.lua")
	assert(opened.position.lnum == 4 and opened.position.col == 2)
	assert(vim.uv.fs_lstat(request_path(id)) == nil)
end)

test("normal RPC rejects traversal and a blocking schema before opening", function()
	local traversal = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	private_json(request_path(traversal), normal_request(traversal, { path = "../target.lua" }))
	assert(exact.consume_normal(traversal, instance, {
		open_file = function()
			error("opened")
		end,
	}) == nil)

	local blocking = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	private_json(request_path(blocking), {
		version = 2,
		request_id = blocking,
		instance_id = instance.instance_id,
		repo_root = root,
		path = root .. "/target.lua",
		created_at = "2026-08-31T10:00:00Z",
	})
	local handled, err = exact.consume_normal(blocking, instance, {
		open_file = function()
			error("opened")
		end,
	})
	assert(not handled and err:find("not normal", 1, true))
end)

test("blocking RPC creates durable owner-only wait state", function()
	local id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
	private_json(request_path(id), {
		version = 2,
		request_id = id,
		instance_id = instance.instance_id,
		repo_root = root,
		path = root .. "/target.lua",
		created_at = "2026-08-31T10:00:00Z",
	})
	local handled, err = exact.consume_blocking(id, instance, {
		open_file = function(path)
			vim.cmd("tabedit " .. vim.fn.fnameescape(path))
		end,
	})
	assert(handled == 1, err)
	local wait = state .. "/waits/" .. id .. ".json"
	assert(assert(vim.uv.fs_lstat(wait)).mode % 512 == tonumber("600", 8))
	assert(vim.json.decode(table.concat(vim.fn.readfile(wait), "\n")).status == "waiting")
	vim.api.nvim_exec_autocmds("VimLeavePre", {})
end)

test("symlink request and record paths are rejected without unlinking their targets", function()
	local id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
	local target = fixture .. "/hostile.json"
	private_json(target, normal_request(id))
	assert(vim.uv.fs_symlink(target, request_path(id)))
	local handled, err = exact.consume_normal(id, instance, {
		open_file = function()
			error("opened")
		end,
	})
	assert(not handled and err:find("non%-symlink"))
	assert(vim.uv.fs_lstat(request_path(id)).type == "link")

	local record = state .. "/editors/" .. instance.instance_id .. ".json"
	vim.fn.delete(record)
	assert(vim.uv.fs_symlink(target, record))
	exact._cleanup(instance)
	assert(vim.uv.fs_lstat(record).type == "link")
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("exact_editor_spec: %d tests passed", count))
vim.cmd("quitall!")
