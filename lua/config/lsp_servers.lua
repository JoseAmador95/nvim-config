local M = {}

local catalog = require("config.lsp_catalog")
local deferred = require("config.lsp_deferred")
local runtime = require("config.lsp_runtime")
local review = require("config.code_review")
local bridge = require("config.lsp_neoconf")
local rust_tools = require("config.rust_tools")
local tombi = require("config.tombi")

local function register(name, config)
	vim.lsp.config(name, config)
	local resolved = vim.lsp.config[name]
	local rooted = review.wrap_lsp_root_dir(
		bridge.wrap_root_dir(name, resolved and resolved.root_dir or nil, resolved and resolved.root_markers or nil)
	)
	vim.lsp.config(name, {
		before_init = bridge.wrap_before_init(name, resolved and resolved.before_init or nil),
		root_dir = runtime.wrap_root_dir(assert(catalog.server(name)), rooted),
		on_new_config = bridge.wrap_on_new_config(name, resolved and resolved.on_new_config or nil),
	})
end

local function capabilities()
	local blink = package.loaded["blink.cmp"]
	return type(blink) == "table" and blink.get_lsp_capabilities() or vim.lsp.protocol.make_client_capabilities()
end

function M.setup(context)
	assert(context == nil or next(context) == nil, "LSP setup no longer accepts eager executable paths")
	local client_capabilities = capabilities()
	local schemastore = package.loaded.schemastore
	local has_schemastore = type(schemastore) == "table"
	local function managed(name, config)
		config.cmd = deferred.managed_command(name)
		register(name, config)
	end

	register("clangd", {
		capabilities = client_capabilities,
		cmd = deferred.clangd_command(),
	})
	managed("ty", {
		capabilities = client_capabilities,
		settings = { ty = { configuration = {} } },
		root_dir = deferred.ty_root_dir,
		before_init = deferred.ty_before_init,
		on_new_config = deferred.ty_on_new_config,
	})
	managed("ruff", { capabilities = client_capabilities })
	managed("cmake", { capabilities = client_capabilities })
	managed("yamlls", {
		capabilities = client_capabilities,
		settings = {
			yaml = {
				keyOrdering = false,
				schemaStore = has_schemastore and { enable = false, url = "" } or { enable = true },
				schemas = has_schemastore and schemastore.yaml.schemas() or {},
			},
		},
	})
	managed("jsonls", {
		capabilities = client_capabilities,
		settings = {
			json = {
				validate = { enable = true },
				schemas = has_schemastore and schemastore.json.schemas() or {},
			},
		},
	})
	managed("tombi", {
		capabilities = client_capabilities,
		cmd_env = tombi.env(),
		settings = tombi.settings(),
	})
	managed("bashls", { capabilities = client_capabilities })
	managed("marksman", { capabilities = client_capabilities })
	managed("lua_ls", {
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
	managed("lemminx", { capabilities = client_capabilities })
	register("rust_analyzer", {
		capabilities = client_capabilities,
		cmd = deferred.rust_analyzer_command(),
		settings = {
			["rust-analyzer"] = {
				check = { command = "clippy" },
				cargo = { allFeatures = true },
			},
		},
	})
	managed("vtsls", { capabilities = client_capabilities })
	managed("docker_language_server", { capabilities = client_capabilities })
	rust_tools.setup_missing_analyzer_notice(nil)

	for _, server in ipairs(catalog.servers) do
		local config = vim.lsp.config[server.name]
		assert(
			type(config) == "table" and type(config.cmd) == "function",
			"LSP lacks runtime boundary: " .. server.name
		)
	end
end

return M
