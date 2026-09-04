local M = {}

local review_lsp = require("config.native_review").lsp
local deferred = require("config.lsp_deferred")

local function register(name, config)
	vim.lsp.config(name, config)
	local resolved = vim.lsp.config[name]
	local bridge = require("config.lsp_neoconf")
	vim.lsp.config(name, {
		before_init = bridge.wrap_before_init(name, resolved and resolved.before_init or nil),
		root_dir = review_lsp.wrap_root_dir(
			bridge.wrap_root_dir(name, resolved and resolved.root_dir or nil, resolved and resolved.root_markers or nil)
		),
		on_new_config = bridge.wrap_on_new_config(name, resolved and resolved.on_new_config or nil),
	})
end

local function capabilities()
	local ok, blink = pcall(require, "blink.cmp")
	return ok and blink.get_lsp_capabilities() or vim.lsp.protocol.make_client_capabilities()
end

function M.setup(context)
	context = context or {}
	review_lsp.setup()
	local client_capabilities = capabilities()
	local has_schemastore, schemastore = pcall(require, "schemastore")

	register("clangd", {
		capabilities = client_capabilities,
		cmd = deferred.clangd_command(),
		on_new_config = deferred.clangd_on_new_config,
	})
	register("ty", {
		capabilities = client_capabilities,
		settings = { ty = { configuration = {} } },
		root_dir = deferred.ty_root_dir,
		before_init = deferred.ty_before_init,
		on_new_config = deferred.ty_on_new_config,
	})
	register("ruff", { capabilities = client_capabilities })
	register("cmake", {
		capabilities = client_capabilities,
		cmd = context.cmake_language_server_path ~= "" and { context.cmake_language_server_path } or nil,
	})
	register("yamlls", {
		capabilities = client_capabilities,
		settings = {
			yaml = {
				keyOrdering = false,
				schemaStore = has_schemastore and { enable = false, url = "" } or { enable = true },
				schemas = has_schemastore and schemastore.yaml.schemas() or {},
			},
		},
	})
	register("jsonls", {
		capabilities = client_capabilities,
		settings = {
			json = {
				validate = { enable = true },
				schemas = has_schemastore and schemastore.json.schemas() or {},
			},
		},
	})
	register("tombi", {
		capabilities = client_capabilities,
		cmd_env = require("config.tombi").env(),
		settings = require("config.tombi").settings(),
	})
	register("bashls", { capabilities = client_capabilities })
	register("marksman", { capabilities = client_capabilities })
	register("lua_ls", {
		capabilities = client_capabilities,
		settings = {
			Lua = {
				runtime = { version = "LuaJIT" },
				diagnostics = { globals = { "vim" } },
				telemetry = { enable = false },
				workspace = {
					checkThirdParty = false,
					library = vim.api.nvim_get_runtime_file("", true),
				},
			},
		},
	})
	register("lemminx", { capabilities = client_capabilities })
	if context.rust_analyzer_path then
		register("rust_analyzer", {
			capabilities = client_capabilities,
			cmd = { context.rust_analyzer_path },
			settings = {
				["rust-analyzer"] = {
					check = { command = "clippy" },
					cargo = { allFeatures = true },
				},
			},
		})
	end
	register("vtsls", { capabilities = client_capabilities })
	register("docker_language_server", { capabilities = client_capabilities })
	require("config.rust_tools").setup_missing_analyzer_notice(context.rust_analyzer_path)
end

return M
