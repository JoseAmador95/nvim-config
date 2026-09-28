vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local load_calls = 0
local resolution
package.loaded["config.deferred"] = {
	load = function(name)
		load_calls = load_calls + 1
		assert(name == "config.tool_bootstrap")
		return {
			resolve = function(tool, command)
				return resolution(tool, command)
			end,
		}
	end,
}

local runtime = require("config.lsp_runtime")
local catalog = require("config.lsp_catalog")
local toolchain = require("config.toolchain")
local original_rpc_start = vim.lsp.rpc.start
local rpc_calls = {}
vim.lsp.rpc.start = function(argv, dispatchers, options)
	rpc_calls[#rpc_calls + 1] = {
		argv = vim.deepcopy(argv),
		dispatchers = dispatchers,
		options = vim.deepcopy(options),
	}
	return { rpc = true }
end

test("requiring the runtime does not resolve or spawn a tool", function()
	assert(load_calls == 0, "verified-tools loaded during module discovery")
	assert(#rpc_calls == 0, "an LSP process started during module discovery")
end)

test("every managed catalog server has one exact manifest command", function()
	for _, server in ipairs(catalog.servers) do
		assert(type(server.args) == "table" or server.args == nil, server.name .. " has invalid argv")
		if server.package then
			local entry = assert(toolchain.mason_entry(server.package), server.package)
			assert(
				toolchain.executable_map(entry)[server.command],
				server.name .. " command is absent from its manifest"
			)
		else
			assert(server.name == "rust_analyzer" and server.external == "rust-analyzer")
		end
	end
end)

test("managed startup resolves once at the final RPC seam and uses the absolute path", function()
	load_calls = 0
	rpc_calls = {}
	resolution = function(tool, command)
		assert(tool == "bash-language-server" and command == "bash-language-server")
		return "/verified/bin/bash-language-server"
	end
	local binding = assert(catalog.server("bashls"))
	local dispatchers = { notification = function() end }
	local rpc = runtime.managed_start(binding, dispatchers, {
		cmd_cwd = "/repo",
		cmd_env = { TEST = "1" },
		detached = true,
	})
	assert(rpc.rpc and load_calls == 1 and #rpc_calls == 1)
	assert(vim.deep_equal(rpc_calls[1].argv, { "/verified/bin/bash-language-server", "start" }))
	assert(rpc_calls[1].dispatchers == dispatchers)
	assert(vim.deep_equal(rpc_calls[1].options, { cwd = "/repo", env = { TEST = "1" }, detached = true }))
end)

test("absence, drift, and malformed paths fail before RPC spawn", function()
	for _, denied in ipairs({
		{ path = nil, err = "absent" },
		{ path = nil, err = "drift: metadata changed" },
		{ path = "relative/ruff", err = nil },
	}) do
		rpc_calls = {}
		resolution = function()
			return denied.path, denied.err
		end
		local ok, err = pcall(runtime.managed_start, assert(catalog.server("ruff")), {}, {})
		local message = tostring(err)
		assert(
			not ok and (message:find("Cannot start LSP", 1, true) or message:find("normalized absolute path", 1, true)),
			message
		)
		assert(#rpc_calls == 0, "denied runtime reached vim.lsp.rpc.start")
	end
end)

test("native root gating turns ordinary absence into a quiet non-start", function()
	local upstream = 0
	local roots = 0
	local notifications = 0
	runtime._notify = function(message)
		notifications = notifications + 1
		assert(message:find("absent", 1, true))
	end
	runtime._reset_for_tests()
	resolution = function()
		return nil, "absent"
	end
	local wrapper = runtime.wrap_root_dir(assert(catalog.server("marksman")), function(_, on_dir)
		upstream = upstream + 1
		on_dir("/repo")
	end)
	wrapper(1, function()
		roots = roots + 1
	end)
	wrapper(1, function()
		roots = roots + 1
	end)
	assert(upstream == 0 and roots == 0, "missing runtime still activated an LSP root")
	assert(notifications == 1, "identical missing-runtime warnings were not coalesced")

	resolution = function()
		return "/verified/bin/marksman"
	end
	wrapper(1, function(root)
		roots = roots + 1
		assert(root == "/repo")
	end)
	assert(upstream == 1 and roots == 1, "verified runtime did not reach native root resolution")
end)

test("clangd absolute override must match the attested executable", function()
	resolution = function()
		return "/verified/bin/clangd"
	end
	rpc_calls = {}
	local binding = assert(catalog.server("clangd"))
	local ok, err = pcall(runtime.managed_start, binding, {}, {}, { "--clang-tidy" }, "/host/bin/clangd")
	assert(not ok and tostring(err):find("does not match the attested executable", 1, true))
	assert(#rpc_calls == 0)
	assert(runtime.managed_start(binding, {}, {}, { "--clang-tidy" }, "/verified/bin/clangd").rpc)
	assert(vim.deep_equal(rpc_calls[1].argv, { "/verified/bin/clangd", "--clang-tidy" }))
end)

test("Rust host lookup is deferred and never changes argv through a shell", function()
	rpc_calls = {}
	local lookups = 0
	runtime._rust_analyzer = function()
		lookups = lookups + 1
		return "/host/bin/rust-analyzer"
	end
	assert(lookups == 0)
	local rpc = runtime.external_rust_start(assert(catalog.server("rust_analyzer")), {}, {})
	assert(rpc.rpc and lookups == 1)
	assert(vim.deep_equal(rpc_calls[1].argv, { "/host/bin/rust-analyzer" }))

	rpc_calls = {}
	runtime._rust_analyzer = function()
		return nil
	end
	local ok, err = pcall(runtime.external_rust_start, assert(catalog.server("rust_analyzer")), {}, {})
	assert(not ok and tostring(err):find("explicit host/user PATH", 1, true))
	assert(#rpc_calls == 0)
end)

vim.lsp.rpc.start = original_rpc_start

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("lsp_runtime_spec: %d tests passed", count))
vim.cmd("quitall!")
