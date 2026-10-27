local T = MiniTest.new_set()
T["toolchain"] = function()
	vim.o.shadafile = "NONE"
	vim.o.swapfile = false
	local repo = vim.fn.getcwd()
	vim.opt.runtimepath:prepend(repo)
	local original_vim = _G.vim
	_G.vim = nil
	local ok, catalog = pcall(assert(loadfile(repo .. "/lua/config/toolchain.lua")))
	_G.vim = original_vim
	assert(ok, catalog)
	assert(catalog.tools.gumtree == nil and catalog.tools["rust-analyzer"] == nil)
	assert(catalog.versions["devcontainers-cli"] == "0.89.0")
	assert(catalog.versions.node == "24.20.0")
	assert(catalog.supported("mmdflux", "macos-arm64"))
	assert(not catalog.supported("mmdflux", "linux-arm64"))
	assert(not catalog.supported("markdown-preview", "linux-arm64"))
	assert(not catalog.supported("clangd", "linux-arm64"))
	assert(catalog.target_key("Darwin", "aarch64") == "macos-arm64")
	assert(catalog.target_key("Linux", "x86_64") == "linux-x64")
	local file = assert(io.open(repo .. "/mise.toml", "rb"))
	local config = file:read("*a")
	file:close()
	assert(config == catalog.mise_config(), "mise.toml differs from its catalog; run scripts/update-tool-lock")
	local commands = {}
	for _, name in ipairs(catalog.tool_order) do
		local entry = catalog.tools[name]
		assert(entry.version ~= "latest" and entry.backend:find(":", 1, true))
		for _, command in ipairs(entry.commands) do
			assert(not commands[command], "duplicate executable: " .. command)
			commands[command] = name
		end
	end
	for _, server in ipairs(require("config.lsp_catalog").servers) do
		if server.package then
			assert(
				commands[server.command] == server.package,
				"LSP command is missing from the Mise catalog: " .. server.name
			)
		end
	end
	for _, target in ipairs({ "macos-arm64", "macos-x64", "linux-arm64", "linux-x64" }) do
		assert(#catalog.mise_checksums[target] == 64)
	end
end
return T
