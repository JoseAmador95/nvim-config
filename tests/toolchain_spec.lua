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

test("toolchain manifest is pinned and independent of Neovim", function()
	local original_vim = _G.vim
	local chunk = assert(loadfile(repo .. "/lua/config/toolchain.lua"))
	_G.vim = nil
	local ok, toolchain = pcall(chunk)
	_G.vim = original_vim
	assert(ok, toolchain)

	local expected_versions = {
		neovim = "0.12.4",
		stylua = "2.5.2",
		shellcheck = "0.11.0",
		actionlint = "1.7.12",
		tree_sitter = "0.26.11",
		mmdflux = "2.6.0",
		plantuml = "1.2026.6",
	}
	assert(original_vim.deep_equal(toolchain.versions, expected_versions), "version manifest drifted")
	assert(toolchain.target_key("Darwin", "aarch64") == "darwin-arm64")
	assert(toolchain.target_key("macOS", "amd64") == "darwin-x86_64")
	assert(toolchain.target_key("Linux", "x64") == "linux-x86_64")
	assert(toolchain.target_key("Plan9", "x64") == nil)
end)

test("validation assets cover every supported target with exact metadata", function()
	local toolchain = require("config.toolchain")
	local targets = { "darwin-arm64", "darwin-x86_64", "linux-arm64", "linux-x86_64" }
	for _, name in ipairs(toolchain.validation_order) do
		local entry = assert(toolchain.validation_tools[name], name)
		assert(entry.version == toolchain.versions[name], name .. " version is not canonical")
		for _, target in ipairs(targets) do
			local asset = assert(entry.assets[target], name .. " lacks " .. target)
			assert(asset.archive and asset.archive ~= "", name .. " asset name is empty")
			assert(asset.sha256:match("^[0-9a-f]+$") and #asset.sha256 == 64, name .. " SHA is invalid")
			local url = toolchain.release_url(entry, asset)
			assert(url:sub(-#asset.archive) == asset.archive, name .. " URL does not end in its asset")
		end
	end
	assert(toolchain.validation_tools.tree_sitter.assets["darwin-arm64"].kind == "gzip")
	assert(toolchain.validation_tools.shellcheck.assets["linux-x86_64"].kind == "tar.xz")
end)

test("managed releases are prebuilt and target-aware", function()
	local toolchain = require("config.toolchain")
	assert(vim.deep_equal(toolchain.managed_order, { "mmdflux", "plantuml" }))
	for _, name in ipairs(toolchain.managed_order) do
		local entry = assert(toolchain.managed_tools[name], name)
		assert(entry.version == toolchain.versions[name])
		assert(entry.repository and entry.tag and entry.executable)
		for _, asset in pairs(entry.assets) do
			assert(asset.archive and asset.sha256 and #asset.sha256 == 64)
		end
	end
	assert(toolchain.managed_tools.mmdflux.assets["linux-arm64"] == nil, "unsupported binary was invented")
	local jar = assert(toolchain.managed_tools.plantuml.assets["darwin-x86_64"])
	assert(jar.kind == "jar")
	assert(vim.deep_equal(jar.requires_all, { "java" }))
	assert(vim.deep_equal(jar.wrapper, { "java", "-jar", "{artifact}" }))
	assert(toolchain.installers == nil, "package-manager installers remain in the manifest")
end)

test("Mason manifest is complete, exact, and stably ordered", function()
	local toolchain = require("config.toolchain")
	local expected_order = {
		"clangd",
		"docker-language-server",
		"lemminx",
		"lua-language-server",
		"marksman",
		"ruff",
		"taplo",
		"codelldb",
		"hadolint",
		"jq",
		"shellcheck",
		"shfmt",
		"stylua",
		"tree-sitter-cli",
		"bash-language-server",
		"json-lsp",
		"pyright",
		"vtsls",
		"yaml-language-server",
		"markdownlint-cli2",
		"prettierd",
		"cmake-language-server",
		"clang-format",
		"debugpy",
	}
	local expected = {
		["clangd"] = "22.1.6",
		["docker-language-server"] = "v0.20.1",
		["lemminx"] = "0.29.3",
		["lua-language-server"] = "3.18.2",
		["marksman"] = "2026-02-08",
		["ruff"] = "0.16.1",
		["taplo"] = "0.10.0",
		["codelldb"] = "v1.12.2",
		["hadolint"] = "v2.15.1",
		["jq"] = "jq-1.7",
		["shellcheck"] = "v0.11.0",
		["shfmt"] = "v3.13.1",
		["stylua"] = "v2.5.2",
		["tree-sitter-cli"] = "v0.26.11",
		["bash-language-server"] = "5.6.0",
		["json-lsp"] = "4.10.0",
		["pyright"] = "1.1.411",
		["vtsls"] = "0.3.0",
		["yaml-language-server"] = "1.24.0",
		["markdownlint-cli2"] = "0.23.2",
		["prettierd"] = "0.29.0",
		["cmake-language-server"] = "0.1.11",
		["clang-format"] = "22.1.8",
		["debugpy"] = "1.8.21",
	}
	assert(vim.deep_equal(toolchain.mason_order, expected_order), "Mason order drifted")
	assert(#toolchain.mason_order == 24 and #toolchain.mason_order == vim.tbl_count(expected), "Mason count drifted")
	local seen = {}
	for _, name in ipairs(toolchain.mason_order) do
		assert(not seen[name], "duplicate Mason entry: " .. name)
		seen[name] = true
		local entry = assert(toolchain.mason_entry(name), name)
		assert(entry.version == expected[name], name .. " pin drifted")
		assert(entry.executables and #entry.executables > 0, name .. " lacks executable probes")
		assert(toolchain.identity(name, entry) == name .. "@" .. expected[name])
	end
	for _, removed in ipairs({ "gofumpt", "gopls", "delve", "goimports", "rust-analyzer" }) do
		assert(toolchain.mason_entry(removed) == nil, "removed tool leaked into Mason: " .. removed)
	end
	assert(vim.deep_equal(toolchain.mason_entry("pyright").requires_all, { "node", "npm" }))
	assert(toolchain.mason_entry("debugpy").requires_python_venv == true)
end)

test("manual Mason sync receives every exact pin without startup automation", function()
	local original_offline = vim.env.NVIM_CONFIG_OFFLINE
	local original_installer = package.loaded["mason-tool-installer"]
	local captured
	vim.env.NVIM_CONFIG_OFFLINE = nil
	package.loaded["plugins.lsp"] = nil
	package.loaded["mason-tool-installer"] = {
		setup = function(options)
			captured = options
		end,
	}
	local specs = require("plugins.lsp")
	local installer_spec
	for _, spec in ipairs(specs) do
		if spec[1] == "WhoIsSethDaniel/mason-tool-installer.nvim" then
			installer_spec = spec
		end
	end
	assert(installer_spec and vim.tbl_contains(installer_spec.cmd, "MasonToolsInstallSync"))
	installer_spec.config()
	local toolchain = require("config.toolchain")
	assert(#captured.ensure_installed == #toolchain.mason_order)
	for index, item in ipairs(captured.ensure_installed) do
		local name = toolchain.mason_order[index]
		assert(item[1] == name)
		assert(item.version == toolchain.mason_entry(name).version)
		assert(type(item.condition) == "function")
	end
	assert(captured.run_on_start == false)
	assert(captured.auto_update == false)
	for _, enabled in pairs(captured.integrations) do
		assert(enabled == false)
	end

	package.loaded["mason-tool-installer"] = original_installer
	package.loaded["plugins.lsp"] = nil
	vim.env.NVIM_CONFIG_OFFLINE = original_offline
end)

test("LSP catalog separates the exact server set from external Rust eligibility", function()
	local catalog = require("config.lsp_catalog")
	local expected = {
		"bashls",
		"clangd",
		"cmake",
		"docker_language_server",
		"jsonls",
		"lemminx",
		"lua_ls",
		"marksman",
		"pyright",
		"ruff",
		"rust_analyzer",
		"taplo",
		"vtsls",
		"yamlls",
	}
	assert(vim.deep_equal(catalog.server_names(), expected), "native LSP server set drifted")
	local without_rust = catalog.enabled_servers(function()
		return nil
	end)
	assert(not vim.tbl_contains(without_rust, "rust_analyzer"), "missing external Rust server was enabled")
	local with_rust = catalog.enabled_servers(function(name)
		return name == "rust-analyzer" and "/host/bin/rust-analyzer" or nil
	end)
	assert(vim.deep_equal(with_rust, expected), "external rust-analyzer was not enabled")
	local toolchain = require("config.toolchain")
	for _, server in ipairs(catalog.servers) do
		if server.package then
			assert(
				toolchain.mason_entry(server.package),
				"LSP package is absent from Mason manifest: " .. server.package
			)
		else
			assert(server.name == "rust_analyzer" and server.external == "rust-analyzer")
		end
	end
end)

test("Rust tools use external paths and the missing analyzer notice is one-shot", function()
	local original_paths = package.loaded["config.tool_paths"]
	local external = {}
	package.loaded["config.tool_paths"] = {
		external_executable = function(name)
			return external[name]
		end,
	}
	package.loaded["config.rust_tools"] = nil
	local rust_tools = require("config.rust_tools")
	local notifications = {}
	rust_tools._notify = function(message, level)
		notifications[#notifications + 1] = { message = message, level = level }
	end

	assert(rust_tools.rust_analyzer() == nil and rust_tools.rustfmt() == nil)
	rust_tools.setup_missing_analyzer_notice(nil)
	vim.api.nvim_exec_autocmds("FileType", { pattern = "rust", modeline = false })
	vim.api.nvim_exec_autocmds("FileType", { pattern = "rust", modeline = false })
	assert(#notifications == 1, "missing rust-analyzer notice was not one-shot")
	assert(notifications[1].message:find("edit%-only"), "Rust notice omitted edit-only behavior")
	assert(notifications[1].message:find(":checkhealth nvimconfig", 1, true), "Rust notice omitted health guidance")

	external["rust-analyzer"] = "/host/bin/rust-analyzer"
	external.rustfmt = "/user/bin/rustfmt"
	assert(rust_tools.rust_analyzer() == "/host/bin/rust-analyzer")
	assert(rust_tools.rustfmt() == "/user/bin/rustfmt")
	rust_tools._reset_for_tests()
	rust_tools.setup_missing_analyzer_notice(external["rust-analyzer"])
	vim.api.nvim_exec_autocmds("FileType", { pattern = "rust", modeline = false })
	assert(#notifications == 1, "available external rust-analyzer still notified")

	package.loaded["config.tool_paths"] = original_paths
	package.loaded["config.rust_tools"] = nil
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
	local command = clangd.command()
	assert(command[1] == "/host/bin/clangd-custom", "local clangd path was ignored")
	assert(vim.tbl_contains(command, "--clang-tidy"), "dynamic clangd argv lost --clang-tidy")

	local root = temp_dir()
	assert(vim.fn.writefile({ "[]" }, root .. "/compile_commands.json") == 0)
	root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
	assert(clangd.validate_compile_commands(root) == root, "valid database was rejected")
	clangd._roots[root] = { manual = root }
	command = clangd.command(root)
	assert(command[2] == "--compile-commands-dir=" .. root, "root-scoped compile database flag is misplaced")
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
