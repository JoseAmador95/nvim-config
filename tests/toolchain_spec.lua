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

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p") == 1, "could not create temporary directory")
	return path
end

test("toolchain manifest is pinned and side-effect free", function()
	local toolchain = require("config.toolchain")
	assert(toolchain.versions.neovim == "0.12.4")
	assert(toolchain.versions.stylua == "2.5.2")
	assert(toolchain.versions.shellcheck == "0.11.0")
	assert(toolchain.versions.actionlint == "1.7.12")
	assert(toolchain.versions.claude_acp == "0.66.0")
	assert(toolchain.versions.mmdflux == "2.6.0")
	assert(toolchain.versions.plantuml_lsp == "v0.5.3")
	assert(
		vim.deep_equal(toolchain.installers.mmdflux, {
			"cargo",
			"install",
			"mmdflux",
			"--version",
			"2.6.0",
			"--locked",
		}),
		"mmdflux installer is not exact"
	)
	assert(
		vim.deep_equal(toolchain.installers["plantuml-lsp"], {
			"go",
			"install",
			"github.com/ptdewey/plantuml-lsp@v0.5.3",
		}),
		"plantuml-lsp installer is not exact"
	)
end)

test("tool installer launches pinned commands asynchronously", function()
	package.loaded["config.tool_installer"] = nil
	local original_system = vim.system
	local original_notify = vim.notify
	local commands = {}
	vim.notify = function() end
	vim.system = function(command, options, callback)
		commands[#commands + 1] = { command = vim.deepcopy(command), options = options }
		callback({ code = 0, stdout = "", stderr = "" })
		return {
			wait = function()
				error("installer unexpectedly waited for an async process")
			end,
		}
	end

	local completed
	require("config.tool_installer").install("all", function(ok)
		completed = ok
	end)
	assert(
		vim.wait(1000, function()
			return completed ~= nil
		end),
		"async install callbacks did not finish"
	)
	vim.system = original_system
	vim.notify = original_notify

	assert(completed == true, "aggregate install callback did not complete successfully")
	assert(#commands == 2, string.format("installer launched %d commands instead of 2", #commands))
	assert(commands[1].options.text == true, "installer did not request text output")
	local manifest = require("config.toolchain")
	assert(vim.deep_equal(commands[1].command, manifest.installers.mmdflux), "mmdflux argv drifted")
	assert(vim.deep_equal(commands[2].command, manifest.installers["plantuml-lsp"]), "plantuml-lsp argv drifted")
end)

test("LSP catalog derives Mason and enabled sets from host probes", function()
	local catalog = require("config.lsp_catalog")
	local host = {
		has_cmake_language_server = true,
		has_rust_analyzer = true,
		has_plantuml_lsp = false,
	}
	local ensure = catalog.ensure_installed(host)
	local enabled = catalog.enabled_servers(host)
	assert(not vim.tbl_contains(ensure, "cmake"), "host cmake-language-server was not preferred")
	assert(not vim.tbl_contains(ensure, "rust_analyzer"), "rustup rust-analyzer was not preferred")
	assert(vim.tbl_contains(ensure, "docker_language_server"), "Docker LSP is absent from Mason catalog")
	assert(vim.tbl_contains(enabled, "docker_language_server"), "Docker LSP is not explicitly enabled")
	assert(not vim.tbl_contains(enabled, "plantuml_lsp"), "missing PlantUML LSP was enabled")

	host.has_cmake_language_server = false
	host.has_rust_analyzer = false
	host.has_plantuml_lsp = true
	ensure = catalog.ensure_installed(host)
	enabled = catalog.enabled_servers(host)
	assert(vim.tbl_contains(ensure, "cmake"), "Mason cmake fallback is absent")
	assert(vim.tbl_contains(ensure, "rust_analyzer"), "Mason rust-analyzer fallback is absent")
	assert(vim.tbl_contains(enabled, "plantuml_lsp"), "available PlantUML LSP was not enabled")
end)

test("clangd has one argv builder and rejects invalid databases before stop", function()
	local original_local_config = package.loaded["config.local_config"]
	package.loaded["config.local_config"] = {
		get = function(key)
			assert(key == "clangd")
			return { path = "/host/bin/clangd-custom" }
		end,
	}
	package.loaded["config.clangd"] = nil
	local clangd = require("config.clangd")
	local command = clangd.command("/tmp/build")
	assert(command[1] == "/host/bin/clangd-custom", "local clangd path was ignored")
	assert(command[2] == "--compile-commands-dir=/tmp/build", "compile database flag is misplaced")
	assert(vim.tbl_contains(command, "--clang-tidy"), "dynamic clangd argv lost --clang-tidy")

	local root = temp_dir()
	assert(vim.fn.writefile({ "[]" }, root .. "/compile_commands.json") == 0)
	assert(clangd.validate_compile_commands(root) == vim.fs.normalize(root), "valid database was rejected")
	assert(vim.fn.writefile({ "{" }, root .. "/compile_commands.json") == 0)
	local valid, message = clangd.validate_compile_commands(root)
	assert(valid == nil and message:find("invalid", 1, true), "malformed database was accepted")

	local original_get_clients = vim.lsp.get_clients
	local stop_count = 0
	vim.lsp.get_clients = function()
		return {
			{
				name = "clangd",
				stop = function()
					stop_count = stop_count + 1
				end,
			},
		}
	end
	package.loaded["config.clangd_commands"] = nil
	local commands = require("config.clangd_commands")
	assert(commands.set_compile_commands(root) == false, "malformed database command succeeded")
	assert(stop_count == 0, "clangd was stopped before compile database validation")

	vim.lsp.get_clients = original_get_clients
	package.loaded["config.local_config"] = original_local_config
	package.loaded["config.clangd"] = nil
	vim.fn.delete(root, "rf")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("toolchain_spec: %d tests passed", count))
vim.cmd("quitall!")
