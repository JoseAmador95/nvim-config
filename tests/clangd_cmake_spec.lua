vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local fixture = vim.fn.tempname()
for _, path in ipairs({ "/one/build", "/one/manual", "/two/build" }) do
	vim.fn.mkdir(fixture .. path, "p")
	vim.fn.writefile({ "[]" }, fixture .. path .. "/compile_commands.json")
end
fixture = vim.uv.fs_realpath(fixture) or fixture

local original_local = package.loaded["config.local_config"]
local original_clients = vim.lsp.get_clients
local original_start = vim.lsp.start
local original_config = vim.lsp.config
local original_defer = vim.defer_fn
local original_editor = package.loaded["config.editor"]

local profile = "full"
package.loaded["config.local_config"] = {
	get = function(name)
		assert(name == "clangd")
		return { path = "clangd-custom", profile = profile }
	end,
}

local buf_one = vim.api.nvim_create_buf(false, true)
local buf_two = vim.api.nvim_create_buf(false, true)
local stopped = {}
local started = {}
local clients = {
	{
		config = { root_dir = fixture .. "/one" },
		attached_buffers = { [buf_one] = true },
		stop = function(self)
			stopped[#stopped + 1] = self
		end,
	},
	{
		config = { root_dir = fixture .. "/two" },
		attached_buffers = { [buf_two] = true },
		stop = function(self)
			stopped[#stopped + 1] = self
		end,
	},
}
vim.lsp.get_clients = function(filter)
	assert(filter.name == "clangd")
	return clients
end
vim.lsp.config = { clangd = { name = "clangd" } }
vim.lsp.start = function(config, options)
	started[#started + 1] = { config = config, options = options }
end
vim.defer_fn = function(callback)
	callback()
end

local clangd = require("config.clangd")
local cmake_config = require("config.cmake")

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

test("CMake build directory restarts only clangd clients for the same root", function()
	assert(clangd.set_cmake(fixture .. "/one", fixture .. "/one/build"))
	assert(#stopped == 1 and stopped[1] == clients[1])
	assert(#started == 1 and started[1].options.bufnr == buf_one)
	assert(vim.tbl_contains(started[1].config.cmd, "--compile-commands-dir=" .. fixture .. "/one/build"))
	assert(clangd.status(fixture .. "/two").directory == nil)
	assert(
		vim.fn.filereadable(fixture .. "/one/compile_commands.json") == 0,
		"integration copied/symlinked the database"
	)
end)

test("manual compile database override wins without touching other roots", function()
	stopped = {}
	started = {}
	assert(clangd.set_manual(fixture .. "/one", fixture .. "/one/manual"))
	local state = clangd.status(fixture .. "/one")
	assert(state.source == "manual" and state.directory == fixture .. "/one/manual")
	assert(vim.tbl_contains(clangd.command(fixture .. "/one"), "--compile-commands-dir=" .. fixture .. "/one/manual"))
	assert(#stopped == 1 and stopped[1] == clients[1] and #started == 1)
end)

test("full is default and trusted light profile has an explicit flag surface", function()
	local full = clangd.command(fixture .. "/one")
	assert(full[1] == "clangd-custom")
	assert(vim.tbl_contains(full, "--background-index") and vim.tbl_contains(full, "--clang-tidy"))
	profile = "light"
	local light = clangd.command(fixture .. "/one")
	assert(not vim.tbl_contains(light, "--background-index") and not vim.tbl_contains(light, "--clang-tidy"))
	assert(clangd.status(fixture .. "/one").profile == "light")
	profile = "full"
end)

test("cmake-tools successful generate feeds its actual root, preset, and build directory", function()
	local callback_result
	local fake = {
		get_config = function()
			return { cwd = fixture .. "/two" }
		end,
		get_build_directory = function()
			return fixture .. "/two/build"
		end,
		get_configure_preset = function()
			return "host-debug"
		end,
		generate = function(_, callback)
			local result = {
				is_ok = function()
					return true
				end,
			}
			callback(result)
			return "generated"
		end,
	}
	cmake_config.setup(fake)
	assert(fake.generate({}, function(result)
		callback_result = result
	end) == "generated")
	assert(callback_result and callback_result:is_ok())
	local state = cmake_config.status(fixture .. "/two")
	assert(state and state.build_dir == fixture .. "/two/build" and state.preset == "host-debug")
	assert(clangd.status(fixture .. "/two").source == "cmake")
end)

test("source/header switch uses clangd and shared tab navigation", function()
	local opened
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path)
			opened = path
		end,
	}
	clients = {
		{
			request = function(_, method, _, callback)
				assert(method == "textDocument/switchSourceHeader")
				callback(nil, vim.uri_from_fname(fixture .. "/one/header.hpp"))
			end,
		},
	}
	vim.fn.writefile({ "#pragma once" }, fixture .. "/one/header.hpp")
	require("config.clangd_commands").switch_source_header()
	vim.wait(100, function()
		return opened ~= nil
	end)
	assert(opened == fixture .. "/one/header.hpp")
end)

package.loaded["config.local_config"] = original_local
package.loaded["config.editor"] = original_editor
vim.lsp.get_clients = original_clients
vim.lsp.start = original_start
vim.lsp.config = original_config
vim.defer_fn = original_defer
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("clangd_cmake_spec: %d tests passed", count))
vim.cmd("quitall!")
