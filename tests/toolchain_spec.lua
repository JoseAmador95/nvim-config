vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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
		["markdown-preview"] = "0.0.10",
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
	assert(vim.deep_equal(toolchain.managed_order, { "mmdflux", "plantuml", "markdown-preview" }))
	for _, name in ipairs(toolchain.managed_order) do
		local entry = assert(toolchain.managed_tools[name], name)
		assert(entry.version == toolchain.versions[name])
		assert(entry.repository and entry.tag and entry.executable)
		assert(vim.deep_equal(toolchain.executable_map(entry), { [entry.executable] = entry.executable }))
		for _, asset in pairs(entry.assets) do
			assert(asset.archive and asset.sha256 and #asset.sha256 == 64)
			local layout = toolchain.release_layout(entry, asset)
			assert(layout.commands[entry.executable] == "bin/" .. entry.executable)
			assert(#layout.artifacts == (asset.kind == "jar" and 1 or 0))
		end
	end
	assert(toolchain.managed_tools.mmdflux.assets["linux-arm64"] == nil, "unsupported binary was invented")
	local markdown = toolchain.managed_tools["markdown-preview"]
	assert(markdown.assets["linux-arm64"] == nil, "unsupported markdown-preview binary was invented")
	assert(markdown.assets["darwin-arm64"].sha256 == "339f9a968fbbc4197259f811dd3f9780459f9d903532a29befcf16679b97babd")
	assert(
		markdown.assets["darwin-x86_64"].sha256 == "580552e6506f858d9e7b2215888d62edbf5511e3201dd62c91afe502c3142204"
	)
	assert(markdown.assets["linux-x86_64"].sha256 == "95eb4d2774c62e93998c41361fe2276a5134ef173dddab29026d34ef80ad44ef")
	local jar = assert(toolchain.managed_tools.plantuml.assets["darwin-x86_64"])
	assert(jar.kind == "jar")
	assert(vim.deep_equal(jar.requires_all, { "java" }))
	assert(vim.deep_equal(jar.wrapper, { "java", "-jar", "{artifact}" }))
	assert(toolchain.installers == nil, "package-manager installers remain in the manifest")
end)

test("dynamic npm release uses only latest metadata and pinned private Node assets", function()
	local toolchain = require("config.toolchain")
	assert(vim.deep_equal(toolchain.dynamic_order, { "devcontainers-cli" }))
	local entry = assert(toolchain.dynamic_entry("devcontainers-cli"))
	assert(entry.backend == "npm-release")
	assert(entry.package == "@devcontainers/cli" and entry.command == "devcontainer")
	assert(entry.dist_tag == "latest")
	assert(entry.metadata_url == "https://registry.npmjs.org/%40devcontainers%2fcli/latest")
	assert(entry.node.version == "24.20.0")
	local expected = {
		["darwin-arm64"] = "40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8",
		["darwin-x86_64"] = "9e5b2644cf107befb6aefca676b96d3296bc10138096f022ed378d6233ed81f4",
		["linux-arm64"] = "3515603e2487879a39bc75716f1a2affd027500c64ba50e845cf72cb33219013",
		["linux-x86_64"] = "855d581f8a4eb1a8117e3426de25fe02770592febcfb31369aee1ffbfee9e8ec",
	}
	for target, sha256 in pairs(expected) do
		local asset = assert(entry.node.assets[target])
		assert(asset.sha256 == sha256)
		assert(toolchain.node_release_url(entry.node, asset) == "https://nodejs.org/dist/v24.20.0/" .. asset.archive)
	end
	assert(toolchain.dynamic_entry("unknown") == nil)
	assert(toolchain.versions["devcontainers-cli"] == nil, "latest was converted into a startup-time static version")
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
		"tombi",
		"codelldb",
		"hadolint",
		"jq",
		"shellcheck",
		"shfmt",
		"stylua",
		"tree-sitter-cli",
		"bash-language-server",
		"json-lsp",
		"vtsls",
		"yaml-language-server",
		"markdownlint-cli2",
		"prettierd",
		"ty",
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
		["ruff"] = "0.16.6",
		["tombi"] = "v1.2.7",
		["codelldb"] = "v1.12.2",
		["hadolint"] = "v2.15.1",
		["jq"] = "jq-1.7",
		["shellcheck"] = "v0.11.0",
		["shfmt"] = "v3.13.1",
		["stylua"] = "v2.5.2",
		["tree-sitter-cli"] = "v0.26.11",
		["bash-language-server"] = "5.6.0",
		["json-lsp"] = "4.10.0",
		["vtsls"] = "0.3.0",
		["yaml-language-server"] = "1.24.0",
		["markdownlint-cli2"] = "0.23.2",
		["prettierd"] = "0.29.0",
		["ty"] = "0.0.77",
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
		local executable_map = toolchain.executable_map(entry)
		assert(executable_map[entry.version_probe], name .. " version probe is not a declared command")
		assert(vim.tbl_count(executable_map) == #entry.executables)
		local integrity = toolchain.mason_integrity(name, entry)
		assert(integrity.kind == "mason-local-integrity")
		assert(integrity.receipt.package == name and integrity.receipt.version == expected[name])
		for command in pairs(executable_map) do
			assert(integrity.commands[command] == "bin/" .. command)
		end
		assert(toolchain.identity(name, entry) == name .. "@" .. expected[name])
	end
	for _, removed in ipairs({ "gofumpt", "gopls", "delve", "goimports", "pyright", "rust-analyzer" }) do
		assert(toolchain.mason_entry(removed) == nil, "removed tool leaked into Mason: " .. removed)
	end
	assert(vim.deep_equal(toolchain.mason_entry("ty").requires_any, { "python3", "python" }))
	assert(toolchain.mason_entry("ty").requires_python_venv == true)
	assert(toolchain.mason_entry("debugpy").requires_python_venv == true)
end)

test("Mason tool installer is removed and verified-tools retains manual authority", function()
	package.loaded["plugins.lsp"] = nil
	local specs = require("plugins.lsp")
	for _, spec in ipairs(specs) do
		assert(spec[1] ~= "WhoIsSethDaniel/mason-tool-installer.nvim")
	end
	assert(type(require("config.tool_bootstrap").install) == "function")
	package.loaded["plugins.lsp"] = nil
end)

test("LSP catalog binds every managed server and keeps Rust as an explicit host exception", function()
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
		"ruff",
		"rust_analyzer",
		"tombi",
		"ty",
		"vtsls",
		"yamlls",
	}
	assert(vim.deep_equal(catalog.server_names(), expected), "native LSP server set drifted")
	assert(vim.deep_equal(catalog.enabled_servers(), expected), "native LSP enablement drifted")
	local toolchain = require("config.toolchain")
	for _, server in ipairs(catalog.servers) do
		if server.package then
			local entry = assert(toolchain.mason_entry(server.package), server.package)
			assert(toolchain.executable_map(entry)[server.command], "LSP command is absent from its exact manifest")
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

	assert(rust_tools.rust_analyzer() == nil)
	assert(rust_tools.rustfmt == nil, "unverified rustfmt resolution remains public")
	rust_tools.setup_missing_analyzer_notice(nil)
	vim.api.nvim_exec_autocmds("FileType", { pattern = "rust", modeline = false })
	vim.api.nvim_exec_autocmds("FileType", { pattern = "rust", modeline = false })
	assert(#notifications == 1, "missing rust-analyzer notice was not one-shot")
	assert(notifications[1].message:find("edit%-only"), "Rust notice omitted edit-only behavior")
	assert(notifications[1].message:find(":checkhealth nvimconfig", 1, true), "Rust notice omitted health guidance")

	external["rust-analyzer"] = "/host/bin/rust-analyzer"
	assert(rust_tools.rust_analyzer() == "/host/bin/rust-analyzer")
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
		plugin = function(name, defaults)
			assert(name == "clangd_compile_db")
			local configured = vim.deepcopy(defaults)
			configured.path = "/host/bin/clangd-custom"
			return configured
		end,
	}
	package.loaded["config.clangd"] = nil
	local clangd = require("config.clangd")
	assert(package.loaded.clangd_compile_db == nil, "clangd router loaded before a root-scoped operation")
	local lsp_boundary = require("config.lsp_deferred")
	assert(
		lsp_boundary.clangd_command() == lsp_boundary.clangd_rpc_start,
		"native clangd registration did not retain the deferred root-scoped RPC function"
	)
	local command = clangd.command()
	assert(package.loaded.clangd_compile_db == nil, "base clangd argv activated the compile-db router")
	assert(command[1] == "/host/bin/clangd-custom", "local clangd path was ignored")
	assert(vim.tbl_contains(command, "--clang-tidy"), "dynamic clangd argv lost --clang-tidy")

	local root = temp_dir()
	assert(vim.fn.writefile({ "[]" }, root .. "/compile_commands.json") == 0)
	root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
	assert(clangd.validate_compile_commands(root) == root, "valid database was rejected")
	clangd._router().setup({ defer = function() end })
	assert(clangd.set_manual(root, root), "valid manual database was not applied")
	command = clangd.command(root)
	assert(command[2] == "--compile-commands-dir=" .. root, "root-scoped compile database flag is misplaced")
	local original_rpc_start = vim.lsp.rpc.start
	local lsp_runtime = require("config.lsp_runtime")
	local original_resolve = lsp_runtime._resolve
	lsp_runtime._resolve = function(tool, executable)
		assert(tool == "clangd" and executable == "clangd")
		return "/host/bin/clangd-custom"
	end
	local rpc_call
	vim.lsp.rpc.start = function(argv, dispatchers, options)
		rpc_call = { argv = argv, dispatchers = dispatchers, options = options }
		return { rpc = true }
	end
	local dispatchers = { notification = function() end }
	local rpc = clangd.rpc_start(dispatchers, {
		root_dir = root,
		cmd_cwd = root,
		cmd_env = { TEST = "1" },
		detached = true,
	})
	lsp_runtime._resolve = original_resolve
	vim.lsp.rpc.start = original_rpc_start
	assert(rpc.rpc and rpc_call.dispatchers == dispatchers)
	assert(rpc_call.argv[2] == "--compile-commands-dir=" .. root, "native RPC start lost its root database")
	assert(rpc_call.options.cwd == root and rpc_call.options.env.TEST == "1" and rpc_call.options.detached == true)
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
