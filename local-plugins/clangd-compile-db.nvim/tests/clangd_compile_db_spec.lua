vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.getcwd() .. "/local-plugins/clangd-compile-db.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local router = require("clangd_compile_db")
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local root = fixture .. "/project"
assert(vim.fn.mkdir(root, "p") == 1)

local function database(name, data)
	local directory = root .. "/" .. name
	assert(vim.fn.mkdir(directory, "p") == 1)
	assert(vim.fn.writefile({ data or "[]" }, directory .. "/compile_commands.json") == 0)
	return directory
end

local deferred = {}
local clients = {}
local stopped = {}
local starts = {}
local attached = {}

local function configure()
	router._reset_for_tests()
	deferred, clients, stopped, starts, attached = {}, {}, {}, {}, {}
	router.setup({
		defer = function(callback)
			deferred[#deferred + 1] = callback
		end,
		lsp = {
			clients = function()
				return clients
			end,
			client_root = function(client)
				return client.root
			end,
			stop = function(client)
				stopped[#stopped + 1] = client.id
			end,
			buffer_valid = function()
				return true
			end,
			config = function(config_root, active)
				local config = {
					root_dir = config_root,
					cmd = { "clangd" },
				}
				if active then
					config.cmd[#config.cmd + 1] = "--compile-commands-dir=" .. active.directory
				end
				return config
			end,
			start = function(config, bufnr)
				starts[#starts + 1] = { config = vim.deepcopy(config), bufnr = bufnr }
				return 77
			end,
			attach = function(bufnr, client_id)
				attached[#attached + 1] = { bufnr = bufnr, client_id = client_id }
			end,
		},
	})
	router.register_provider("cmake", { priority = 10 })
	router.register_provider("meson", { priority = 20 })
end

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

test("validation accepts only a structural JSON array", function()
	configure()
	local valid = database("valid", "[]")
	assert(router.validate(valid).validity == "structural")
	for name, data in pairs({ malformed = "{", future = '{"version":2,"commands":[]}', scalar = "true" }) do
		local result, err = router.validate(database(name, data))
		assert(result == nil and err:find("expected a JSON array", 1, true))
	end
end)

test("files over 256 MiB require explicit unchecked candidate and apply", function()
	configure()
	local directory = database("huge", "[]")
	local path = directory .. "/compile_commands.json"
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(fd, router.MAX_BYTES + 1))
	assert(vim.uv.fs_close(fd))
	local value, err = router.validate(directory)
	assert(value == nil and err:find("use bang", 1, true))
	local candidate = assert(router.candidate(root, "cmake", directory, { unchecked = true }))
	assert(candidate.validity == "unchecked")
	value, err = router.apply(root, { provider = "cmake" })
	assert(value == nil and err:find("requires bang", 1, true))
	assert(vim.fn.writefile({ "[]" }, path) == 0)
	local downgraded = assert(router.apply(root, { provider = "cmake" }))
	assert(downgraded.active.validity == "structural")

	local growing = database("growing", "[]")
	local candidate = assert(router.candidate(root, "cmake", growing))
	local growing_path = growing .. "/compile_commands.json"
	fd = assert(vim.uv.fs_open(growing_path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_ftruncate(fd, router.MAX_BYTES + 1))
	assert(vim.uv.fs_close(fd))
	value, err = router.apply(root, { provider = "cmake" })
	assert(value == nil and err:find("use bang", 1, true))
	assert(router.active(root).fingerprint == downgraded.active.fingerprint, "failed growth replaced active state")
	local unchecked = assert(router.apply(root, { provider = "cmake", unchecked = true }))
	assert(unchecked.active.validity == "unchecked" and unchecked.active.fingerprint ~= candidate.fingerprint)
end)

test("apply refreshes a mutated candidate and preserves active on invalid revalidation", function()
	configure()
	local stable = database("mutation-stable", "[]")
	local changing = database("mutation-changing", "[]")
	assert(router.set_provider(root, "meson", stable))
	local previous = assert(router.active(root))
	local candidate = assert(router.candidate(root, "cmake", changing))
	assert(
		vim.fn.writefile(
			{ '[{"directory":"/tmp","file":"probe.c","command":"cc probe.c"}]' },
			changing .. "/compile_commands.json"
		) == 0
	)
	local applied = assert(router.apply(root, { provider = "cmake" }))
	assert(applied.active.fingerprint ~= candidate.fingerprint, "apply published the stale candidate fingerprint")
	assert(applied.active.validity == "structural")

	local invalid = database("mutation-invalid", "[]")
	assert(router.candidate(root, "cmake", invalid))
	assert(vim.fn.writefile({ "{" }, invalid .. "/compile_commands.json") == 0)
	local result, err = router.apply(root, { provider = "cmake" })
	assert(result == nil and err:find("expected a JSON array", 1, true))
	assert(router.active(root).fingerprint == applied.active.fingerprint, "invalid revalidation replaced active state")
	assert(router.active(root).fingerprint ~= previous.fingerprint)
end)

test("candidate and apply are distinct with deterministic providers and RAM override", function()
	configure()
	local cmake = database("cmake")
	local meson = database("meson")
	local manual = database("manual")
	assert(router.candidate(root, "cmake", cmake))
	assert(router.status(root).state == "candidate" and router.active(root) == nil)
	assert(router.candidate(root, "meson", meson))
	local applied = assert(router.apply(root))
	local active = applied.active
	assert(active.provider == "meson" and active.directory == meson)
	assert(applied.state == "active" and applied.candidate == nil and applied.error == nil)
	local invalid, err = router.candidate(root, "cmake", database("provider-error", "{}"))
	assert(invalid == nil and err:find("expected a JSON array", 1, true))
	local error_state = router.status(root)
	assert(error_state.state == "error" and error_state.active.directory == meson)
	assert(router.set_override(root, manual).active.provider == "manual")
	assert(router.set_provider(root, "cmake", cmake).active.provider == "manual")
	assert(router.clear_override(root).active.provider == "meson")
	router._reset_for_tests()
	router.setup({})
	assert(router.active(root) == nil, "manual override survived process-local reset")
end)

test("changed or malformed active databases become stale without replacement", function()
	configure()
	local directory = database("stale")
	assert(router.set_provider(root, "cmake", directory))
	local active = assert(router.active(root))
	assert(vim.fn.writefile({ "not json" }, directory .. "/compile_commands.json") == 0)
	local status = router.status(root)
	assert(status.state == "stale" and status.active.directory == active.directory)
	local generation = status.generation
	assert(router.status(root).generation == generation, "stale status republished without a transition")
	assert(router.command_directory(root) == directory)
end)

test("restarts coalesce, build latest cmd first, and create one ordered client per root", function()
	configure()
	local first = database("first")
	local second = database("second")
	clients = {
		{ id = 1, root = root, attached_buffers = { [5] = true, [1] = true } },
		{ id = 2, root = root, attached_buffers = { [3] = true, [2] = true } },
		{ id = 3, root = fixture .. "/other", attached_buffers = { [9] = true } },
	}
	assert(router.set_provider(root, "cmake", first))
	assert(router.set_provider(root, "cmake", second))
	assert(#deferred == 1, "restart was not coalesced")
	deferred[1]()
	assert(vim.deep_equal(stopped, { 1, 2 }))
	assert(#starts == 1 and starts[1].bufnr == 1)
	assert(starts[1].config.cmd[2] == "--compile-commands-dir=" .. second)
	assert(vim.deep_equal(attached, {
		{ bufnr = 2, client_id = 77 },
		{ bufnr = 3, client_id = 77 },
		{ bufnr = 5, client_id = 77 },
	}))
	assert(router.set_provider(root, "cmake", second))
	assert(#deferred == 1, "unchanged active database scheduled another restart")
end)

test("clear override coalesces one restart for provider fallback and no database", function()
	configure()
	clients = { { id = 1, root = root, attached_buffers = { [1] = true } } }
	local fallback = database("clear-fallback")
	local manual = database("clear-manual")
	assert(router.set_provider(root, "cmake", fallback))
	assert(router.set_override(root, manual))
	local cleared = assert(router.clear_override(root))
	assert(cleared.active.provider == "cmake" and cleared.active.directory == fallback)
	assert(#deferred == 1, "fallback transitions did not coalesce to one restart")
	deferred[1]()
	assert(#starts == 1 and starts[1].config.cmd[2] == "--compile-commands-dir=" .. fallback)

	configure()
	clients = { { id = 2, root = root, attached_buffers = { [2] = true } } }
	fallback = database("clear-invalid-fallback")
	manual = database("clear-invalid-manual")
	assert(router.set_provider(root, "cmake", fallback))
	assert(router.set_override(root, manual))
	assert(vim.fn.writefile({ "{" }, fallback .. "/compile_commands.json") == 0)
	local failed, clear_err = router.clear_override(root)
	assert(failed == nil and clear_err:find("expected a JSON array", 1, true))
	assert(router.active(root) == nil, "invalid fallback retained the cleared manual database")
	assert(#deferred == 1, "invalid fallback did not coalesce the removal restart")
	deferred[1]()
	assert(#starts == 1 and vim.deep_equal(starts[1].config.cmd, { "clangd" }))

	configure()
	clients = { { id = 3, root = root, attached_buffers = { [3] = true } } }
	manual = database("clear-only-manual")
	assert(router.set_override(root, manual))
	cleared = assert(router.clear_override(root))
	assert(cleared.active == nil and cleared.state == "candidate")
	assert(#deferred == 1, "no-database transitions did not coalesce to one restart")
	deferred[1]()
	assert(#starts == 1 and vim.deep_equal(starts[1].config.cmd, { "clangd" }))
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("clangd_compile_db_spec: %d tests passed", count))
vim.cmd("quitall!")
