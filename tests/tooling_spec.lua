vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("tooling_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				local mason_options = require("mason.settings").current
				assert(
					mason_options.install_root_dir == require("config.tool_paths").mason_root(),
					"Mason is not rooted in the primary editor data directory"
				)
				assert(mason_options.PATH == "append", "Mason still prepends itself ahead of host tools")
				local mason_settings = require("mason-lspconfig.settings").current
				assert(mason_settings.automatic_enable == false, "Mason automatic LSP enablement is not disabled")
				assert(vim.tbl_isempty(mason_settings.ensure_installed), "mason-lspconfig still schedules installs")
				assert(vim.lsp.is_enabled("docker_language_server"), "Docker LSP is not explicitly enabled")
				assert(not vim.lsp.is_enabled("stylua"), "Stylua was unexpectedly enabled as an LSP")
				assert(vim.lsp.config["*"].before_init == nil, "wildcard before_init hook is still configured")
				assert(type(vim.lsp.config.pyright.root_dir) == "function", "native LSP startup gate is missing")
				assert(vim.fn.exists(":NvimConfigToolsInstall") == 2, "pinned tool installer command is missing")
				assert(vim.fn.exists(":MasonToolsInstallSync") == 2, "manual Mason sync command is missing")

				local neoconf = require("neoconf")
				local rust_path = require("config.rust_tools").rust_analyzer()
				assert(
					vim.lsp.is_enabled("rust_analyzer") == (rust_path ~= nil),
					"Rust LSP enablement does not match the external executable"
				)
				if rust_path then
					assert(vim.lsp.config.rust_analyzer.cmd[1] == rust_path, "Rust LSP did not pin the external path")
					assert(not require("config.tool_paths").is_mason_path(rust_path), "Rust LSP resolved through Mason")
				end

				local project = vim.fn.tempname()
				assert(vim.fn.mkdir(project .. "/.vscode", "p") == 1, "could not create neoconf fixture")
				assert(vim.fn.writefile({
					'{ "python.analysis.typeCheckingMode": "strict", "python.analysis.autoSearchPaths": false }',
				}, project .. "/.vscode/settings.json") == 0, "could not write neoconf fixture")
				local real_config = {
					name = "pyright",
					root_dir = project,
					settings = { python = { analysis = { diagnosticMode = "openFilesOnly" } } },
				}
				local upstream_saw_settings = false
				require("config.lsp_neoconf").wrap_before_init("pyright", function(_, config)
					upstream_saw_settings = config.settings.python.analysis.typeCheckingMode == "strict"
				end)({}, real_config)
				assert(upstream_saw_settings, "upstream before_init ran before real VSCode settings")
				assert(
					real_config.settings.python.analysis.autoSearchPaths == false,
					"real .vscode/settings.json was not merged"
				)
				assert(
					real_config.settings.python.analysis.diagnosticMode == "openFilesOnly",
					"base server settings were lost during real neoconf merge"
				)

				real_config.on_new_config = require("config.lsp_neoconf").wrap_on_new_config("pyright")
				assert(vim.fn.writefile({
					'{ "python.analysis.typeCheckingMode": "basic", "python.analysis.autoSearchPaths": true }',
				}, project .. "/.vscode/settings.json") == 0, "could not update neoconf fixture")
				local original_get_clients = vim.lsp.get_clients
				local notification
				vim.lsp.get_clients = function()
					return {
						{
							name = "pyright",
							config = real_config,
							notify = function(method, payload)
								notification = { method = method, payload = payload }
								return true
							end,
						},
					}
				end
				local reload_ok, reload_err = xpcall(function()
					vim.api.nvim_exec_autocmds("BufWritePost", {
						group = "Neoconf",
						pattern = project .. "/.vscode/settings.json",
						modeline = false,
					})
				end, debug.traceback)
				vim.lsp.get_clients = original_get_clients
				assert(reload_ok, reload_err)
				assert(
					real_config.settings.python.analysis.typeCheckingMode == "basic",
					"neoconf live reload did not reapply changed VSCode settings"
				)
				assert(
					real_config.settings.python.analysis.diagnosticMode == "openFilesOnly",
					"neoconf live reload lost original server settings"
				)
				assert(
					notification and notification.method == "workspace/didChangeConfiguration",
					"neoconf live reload did not notify the active client"
				)

				assert(
					vim.fn.writefile({ '{ "lspconfig": { "pyright": false } }' }, project .. "/.neoconf.json") == 0,
					"could not write the disabled-server fixture"
				)
				local disabled_buf = vim.api.nvim_create_buf(false, false)
				vim.api.nvim_buf_set_name(disabled_buf, project .. "/disabled.py")
				assert(
					neoconf.get("lspconfig.pyright", {}, { file = project .. "/disabled.py" }) == false,
					"neoconf did not expose the disabled-server setting"
				)
				local disabled_started = false
				vim.lsp.config.pyright.root_dir(disabled_buf, function()
					disabled_started = true
				end)
				assert(not disabled_started, "lspconfig.pyright=false did not prevent native LSP startup")
				vim.api.nvim_buf_delete(disabled_buf, { force = true })
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
				navigation.declaration()
				assert(request_count == 2, "declaration issued more than one LSP request")
				assert(opened and opened.path == "/tmp/only.lua", "single declaration did not open directly")
				assert(vim.deep_equal(opened.position, { lnum = 11, col = 6 }), "direct declaration position drifted")

				vim.lsp.get_clients = original_get_clients
				vim.lsp.buf.definition = original_definition
				vim.lsp.buf.declaration = original_declaration
				snacks.picker.pick = original_pick
				snacks.picker.lsp_definitions = original_source
				editor.open_file_in_tab = original_open

				for _, lhs in ipairs({ "K", "gO", "gra", "gri", "grn", "grr", "grt", "grx" }) do
					assert(vim.fn.maparg(lhs, "n") == "", "Neovim default LSP mapping remains: " .. lhs)
				end
				assert(vim.fn.maparg("gra", "x") == "", "Neovim visual code-action mapping remains")
				local keymap_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_exec_autocmds("LspAttach", {
					buffer = keymap_buf,
					group = "LspKeymaps",
					modeline = false,
				})
				vim.api.nvim_buf_call(keymap_buf, function()
					for _, lhs in ipairs({ "gd", "gD", "gi", "gr", "K", "<C-k>", "<leader>rn", "<leader>ca" }) do
						local mapping = vim.fn.maparg(lhs, "n", false, true)
						assert(mapping and mapping.buffer == 1, "custom LSP mapping is missing: " .. lhs)
					end
					local scratch = vim.fn.maparg("<leader>.", "n", false, true)
					assert(scratch and scratch.buffer == 0, "LSP mapping shadowed the global project scratch")
					assert(scratch.desc == "Project scratch", "<leader>. no longer routes to project scratch")
				end)
				vim.api.nvim_buf_delete(keymap_buf, { force = true })
				local menu_route_count = 0
				local original_navigation_definition = navigation.definition
				navigation.definition = function()
					menu_route_count = menu_route_count + 1
				end
				require("config.menu.actions").run("lsp.definition")
				navigation.definition = original_navigation_definition
				assert(menu_route_count == 1, "menu definition bypassed shared LSP navigation")

				local clangd_command = vim.lsp.config.clangd.cmd
				assert(clangd_command[1] == "clangd", "clangd ignored the default local binary setting")
				assert(vim.tbl_contains(clangd_command, "--clang-tidy"), "clangd lost --clang-tidy")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			print("tooling_spec: 1 test passed")
			vim.cmd("quitall!")
		end)
	end,
})
