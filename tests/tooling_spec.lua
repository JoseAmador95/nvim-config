local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function global_mapping(mode, lhs)
	for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
		if mapping.lhs == lhs then
			return mapping
		end
	end
end

T["tooling"] = function()
	assert(package.loaded.mason == nil, "Mason loaded before its UI was requested")
	assert(package.loaded["mason-registry"] == nil, "Mason registry loaded on the file-open path")
	assert(package.loaded["mason-lspconfig"] == nil, "mason-lspconfig loaded on the file-open path")
	require("lazy").load({ plugins = { "venv-selector.nvim" } })
	assert(vim.fn.exists(":VenvSelect") == 2, "manual Python environment picker is missing")
	assert(
		vim.fn.exists("#VenvSelectorUvDetect") == 0,
		"venv-selector still runs install-capable PEP 723 uv automation"
	)

	assert(package.loaded.mason == nil, "Python environment selection activated Mason")
	assert(require("lazy.core.config").plugins["mason.nvim"] == nil, "Mason remains installed by the config")
	assert(vim.fn.exists(":NvimConfigMiseInstall") == 2, "explicit Mise installer is missing")

	assert(vim.lsp.is_enabled("docker_language_server"), "Docker LSP is not explicitly enabled")
	assert(not vim.lsp.is_enabled("stylua"), "Stylua was unexpectedly enabled as an LSP")
	assert(vim.lsp.config["*"].before_init == nil, "wildcard before_init hook is still configured")
	assert(type(vim.lsp.config.ty.root_dir) == "function", "native LSP startup gate is missing")
	assert(vim.lsp.is_enabled("ty"), "ty is not explicitly enabled")
	assert(not vim.lsp.is_enabled("pyright"), "Pyright remains enabled")
	assert(vim.fn.exists(":NvimConfigToolsInstall") == 2, "pinned tool installer command is missing")
	assert(vim.fn.exists(":MasonToolsInstallSync") == 0, "retired Mason sync command remains")
	for _, name in ipairs({ "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonUpdate" }) do
		assert(vim.fn.exists(":" .. name) == 0, "Mason mutation command remains: " .. name)
	end

	local neoconf = require("neoconf")
	assert(vim.lsp.is_enabled("rust_analyzer"), "deferred host Rust LSP registration is missing")
	assert(type(vim.lsp.config.rust_analyzer.cmd) == "function", "Rust path was resolved eagerly")
	local lsp_runtime = require("config.lsp_runtime")
	local original_runtime_resolve = lsp_runtime._resolve
	lsp_runtime._resolve = function(_, command)
		return "/verified/bin/" .. command
	end

	local project = vim.fn.tempname()
	assert(vim.fn.mkdir(project .. "/.vscode", "p") == 1, "could not create project settings fixture")
	assert(vim.fn.mkdir(project .. "/.venv/bin", "p") == 1, "could not create local Python fixture")
	project = vim.uv.fs_realpath(project) or project
	local local_python = project .. "/.venv/bin/python"
	assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, local_python) == 0)
	assert(vim.uv.fs_chmod(local_python, tonumber("700", 8)))
	assert(vim.fn.writefile({
		vim.json.encode({
			["ty.configuration.environment.python"] = project .. "/.venv",
			["ty.configuration.rules.unresolved-reference"] = "warn",
			["ty.disableLanguageServices"] = false,
		}),
	}, project .. "/.vscode/settings.json") == 0)
	assert(vim.fn.writefile({ '{ "lspconfig": { "ruff": false } }' }, project .. "/.neoconf.json") == 0)

	local project_settings = require("config.project_settings")
	project_settings.setup({
		active = true,
		repo = {
			root = function()
				return project
			end,
		},
		neoconf = neoconf,
	})
	assert(vim.fn.exists(":NvimConfigTrustProjectSettings") == 0, "removed project trust command remains")
	assert(vim.fn.exists(":Neoconf") == 2, "Neoconf global UI command is missing")
	assert(vim.fn.exists("#Neoconf#BufWritePost") == 0, "Neoconf live reload remains enabled")
	for _, item in
		ipairs(require("neoconf.commands").get_files({
			["local"] = true,
			global = true,
			file = project,
		}))
	do
		assert(item.is_global, "Neoconf UI retained direct project-file authority")
	end
	assert(
		neoconf.get("lspconfig.ruff", {}, { file = project .. "/disabled.py" }) ~= false,
		"Neoconf imported project settings directly instead of through the adapter"
	)

	local startup_config = vim.deepcopy(vim.lsp.config.ty)
	startup_config.root_dir = project
	local startup_client = { settings = startup_config.settings }
	vim.lsp.config.ty.before_init({}, startup_config)
	assert(rawequal(startup_config.settings, startup_client.settings))
	assert(
		startup_client.settings.ty.configuration.rules["unresolved-reference"] == "warn",
		"project VSCode settings did not reach ty"
	)
	assert(startup_client.settings.ty.disableLanguageServices == false)
	assert(startup_client.settings.ty.configuration.environment.python == project .. "/.venv")
	assert(require("config.python").for_root(project) == local_python)
	local updated_config = vim.deepcopy(vim.lsp.config.ty)
	updated_config.root_dir = project
	local updated_settings = updated_config.settings
	vim.lsp.config.ty.on_new_config(updated_config, project)
	assert(rawequal(updated_config.settings, updated_settings))
	assert(updated_config.settings.ty.configuration.environment.python == project .. "/.venv")
	assert(updated_config.settings.ty.configuration.rules["unresolved-reference"] == "warn")

	local disabled_buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(disabled_buf, project .. "/disabled.py")
	local disabled_started = false
	vim.lsp.config.ruff.root_dir(disabled_buf, function()
		disabled_started = true
	end)
	assert(not disabled_started, "project lspconfig.ruff=false did not gate startup")

	local real_config = {
		name = "ty",
		root_dir = project,
		settings = {
			ty = { configuration = { rules = { ["possibly-unresolved-reference"] = "ignore" } } },
		},
	}
	local upstream_rule
	local wrapped_before_init = require("config.lsp_neoconf").wrap_before_init("ty", function(_, config)
		upstream_rule = config.settings.ty.configuration.rules["unresolved-reference"]
	end)
	wrapped_before_init({}, real_config)
	assert(upstream_rule == "warn", "project settings were not merged before upstream before_init")
	assert(real_config.settings.ty.configuration.rules["possibly-unresolved-reference"] == "ignore")

	assert(vim.fn.writefile({
		'{ "ty.configuration.rules.unresolved-reference": "error" }',
	}, project .. "/.vscode/settings.json") == 0)
	local changed = { root_dir = project, settings = {} }
	vim.lsp.config.ty.before_init({}, changed)
	assert(
		changed.settings.ty.configuration.rules["unresolved-reference"] == "error",
		"edited project settings were not applied"
	)
	local stable_settings = real_config.settings
	wrapped_before_init({}, real_config)
	assert(rawequal(stable_settings, real_config.settings), "LSP settings table identity changed on edit")
	assert(upstream_rule == "error", "edited settings were not visible to the upstream hook")
	assert(
		real_config.settings.ty.configuration.rules["possibly-unresolved-reference"] == "ignore",
		"base settings were lost"
	)
	assert(vim.fn.writefile({ "{}" }, project .. "/.neoconf.json") == 0)
	disabled_started = false
	vim.lsp.config.ruff.root_dir(disabled_buf, function()
		disabled_started = true
	end)
	assert(disabled_started, "removing lspconfig.ruff=false did not release the startup gate")
	vim.api.nvim_buf_delete(disabled_buf, { force = true })
	project_settings.setup({
		repo = require("config.repo"),
		neoconf = neoconf,
		notify = vim.notify,
	})
	vim.fn.delete(project, "rf")

	local navigation = require("config.lsp_navigation")
	local snacks = require("snacks")
	local editor = require("config.editor")
	local original_get_clients = vim.lsp.get_clients
	local original_definition = vim.lsp.buf.definition
	local original_declaration = vim.lsp.buf.declaration
	local original_pick = snacks.picker.pick
	local original_source = snacks.picker.lsp_definitions
	local original_open = editor.open_file_in_tab
	local request_count = 0
	local picked
	local opened
	vim.lsp.get_clients = function(options)
		assert(options.method == "textDocument/definition" or options.method == "textDocument/declaration")
		return { { id = 1 } }
	end
	vim.lsp.buf.definition = function(options)
		request_count = request_count + 1
		options.on_list({
			title = "LSP locations",
			items = {
				{ filename = "/tmp/one.lua", lnum = 3, col = 5, text = "one" },
				{ filename = "/tmp/two.lua", lnum = 7, col = 2, text = "two" },
			},
		})
	end
	snacks.picker.pick = function(options)
		picked = options
	end
	snacks.picker.lsp_definitions = function()
		error("definition source made a second LSP request")
	end
	navigation.definition()
	assert(request_count == 1, "definition issued more than one LSP request")
	assert(picked and #picked.items == 2, "multiple definitions did not reach one picker")
	assert(vim.deep_equal(picked.items[1].pos, { 3, 4 }), "quickfix position was not converted for Snacks")
	assert(picked.items[2].file == "/tmp/two.lua", "picker lost a definition")

	vim.lsp.buf.declaration = function(options)
		request_count = request_count + 1
		options.on_list({ items = { { filename = "/tmp/only.lua", lnum = 11, col = 6 } } })
	end
	editor.open_file_in_tab = function(path, position)
		opened = { path = path, position = position }
	end
	local declaration_origin = package.loaded["config.navigation_history"].capture()
	navigation.declaration()
	assert(request_count == 2, "declaration issued more than one LSP request")
	assert(opened and opened.path == "/tmp/only.lua", "single declaration did not open directly")
	assert(opened.position.lnum == 11 and opened.position.col == 6, "direct declaration position drifted")
	assert(
		vim.deep_equal(opened.position.history_origin, declaration_origin),
		"direct declaration did not retain its invocation origin"
	)

	vim.lsp.get_clients = original_get_clients
	vim.lsp.buf.definition = original_definition
	vim.lsp.buf.declaration = original_declaration
	snacks.picker.pick = original_pick
	snacks.picker.lsp_definitions = original_source
	editor.open_file_in_tab = original_open

	for _, lhs in ipairs({ "K", "gO", "gra", "gri", "grn", "grr", "grt", "grx" }) do
		assert(global_mapping("n", lhs) == nil, "Neovim default global LSP mapping remains: " .. lhs)
	end
	assert(global_mapping("x", "gra") == nil, "Neovim visual code-action mapping remains")
	local keymap_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_exec_autocmds("LspAttach", {
		buffer = keymap_buf,
		group = "LspKeymaps",
		modeline = false,
	})
	vim.api.nvim_buf_call(keymap_buf, function()
		for _, lhs in ipairs({ "gd", "gD", "gi", "gr", "K", "<C-k>", "<leader>lr", "<leader>ca" }) do
			local mapping = vim.fn.maparg(lhs, "n", false, true)
			assert(mapping and mapping.buffer == 1, "custom LSP mapping is missing: " .. lhs)
		end
	end)
	vim.api.nvim_buf_delete(keymap_buf, { force = true })
	local menu_route_count = 0
	local original_navigation_definition = navigation.definition
	navigation.definition = function()
		menu_route_count = menu_route_count + 1
	end
	require("config.menu.actions").execute("lsp.definition")
	navigation.definition = original_navigation_definition
	assert(menu_route_count == 1, "menu definition bypassed shared LSP navigation")

	local clangd_command = vim.lsp.config.clangd.cmd
	assert(type(clangd_command) == "function", "clangd did not register a root-scoped command function")
	assert(
		clangd_command == require("config.lsp_deferred").clangd_rpc_start,
		"clangd command bypassed the deferred native RPC boundary"
	)
	for _, server in ipairs(require("config.lsp_catalog").servers) do
		assert(type(vim.lsp.config[server.name].cmd) == "function", server.name .. " bypassed runtime resolution")
	end
	lsp_runtime._resolve = original_runtime_resolve
end
return T
