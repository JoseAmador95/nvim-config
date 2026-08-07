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
				local mason_settings = require("mason-lspconfig.settings").current
				assert(mason_settings.automatic_enable == false, "Mason automatic LSP enablement is not disabled")
				if vim.env.NVIM_CONFIG_OFFLINE == "1" then
					assert(
						vim.tbl_isempty(mason_settings.ensure_installed),
						"offline mode still schedules Mason installs"
					)
				end
				assert(vim.lsp.is_enabled("docker_language_server"), "Docker LSP is not explicitly enabled")
				assert(not vim.lsp.is_enabled("stylua"), "Stylua was unexpectedly enabled as an LSP")
				assert(vim.lsp.config["*"].before_init == nil, "wildcard before_init hook is still configured")
				assert(type(vim.lsp.config.pyright.root_dir) == "function", "native LSP startup gate is missing")
				assert(vim.fn.exists(":NvimConfigToolsInstall") == 2, "pinned tool installer command is missing")
				assert(vim.fn.exists(":PlantumlLspInstall") == 2, "PlantUML install compatibility command is missing")
				assert(
					vim.fn.exists("#PlantumlLspMissing#FileType") == 0,
					"PlantUML FileType auto-install hook still exists"
				)

				local neoconf = require("neoconf")
				local original_get = neoconf.get
				local merge_calls = 0
				neoconf.get = function(key)
					merge_calls = merge_calls + 1
					if key == "vscode" then
						return { ["rust-analyzer"] = { vscode_probe = "merged" } }
					end
					if key == "lspconfig.rust_analyzer" then
						return { ["rust-analyzer"] = { neoconf_probe = "merged" } }
					end
					return {}
				end

				local rust_config = vim.lsp.config.rust_analyzer
				local runtime_config = vim.deepcopy(rust_config)
				runtime_config.name = "rust_analyzer"
				runtime_config.root_dir = vim.fn.getcwd()
				local init_params = {}
				local hook_ok, hook_err = xpcall(function()
					rust_config.before_init(init_params, runtime_config)
				end, debug.traceback)
				neoconf.get = original_get

				assert(hook_ok, hook_err)
				assert(merge_calls == 2, string.format("neoconf public API ran %d times", merge_calls))
				assert(runtime_config.original_settings ~= nil, "neoconf stage did not run")
				assert(init_params.initializationOptions ~= nil, "Rust upstream before_init did not run")
				assert(
					init_params.initializationOptions.neoconf_probe == "merged",
					"Rust upstream hook ran before neoconf settings were merged"
				)
				assert(
					init_params.initializationOptions.vscode_probe == "merged",
					"VSCode settings were not merged through neoconf.get"
				)

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

				local unicode_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(unicode_buf, 0, -1, false, { "a🙂b" })
				local byte_col =
					require("config.lsp_navigation").byte_column(unicode_buf, { line = 0, character = 3 }, "utf-16")
				assert(byte_col == 5, string.format("UTF-16 column converted to byte %d instead of 5", byte_col))
				vim.api.nvim_buf_delete(unicode_buf, { force = true })

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
