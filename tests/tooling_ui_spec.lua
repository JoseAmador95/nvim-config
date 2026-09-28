vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("tooling_ui_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(package.loaded["config.tool_bootstrap"] == nil, "tool bootstrap loaded before a debug action")
				assert(package.loaded.verified_tools == nil, "verified-tools loaded before a debug action")
				local debug_paths = {
					["debugpy:debugpy-adapter"] = "/verified/debugpy-adapter",
					["codelldb:codelldb"] = "/verified/codelldb",
				}
				package.loaded["config.workflow_execution"] = {
					grant = function(capability)
						assert(capability == "debug")
						return true, { runtime = "host" }
					end,
					tool = function(capability, tool, command)
						assert(capability == "debug")
						return assert(debug_paths[tool .. ":" .. command]), { runtime = "host" }
					end,
					notify = function() end,
				}
				require("lazy").load({ plugins = { "nvim-dap" } })

				local dap = require("dap")
				assert(require("config.dap_ui").selected() == "dap-ui", "dap-ui is not the versioned default")
				assert(package.loaded.dapui, "default dap-ui module was not loaded")
				assert(package.loaded["dap-view"] == nil, "dap-view loaded alongside the default dap-ui")
				local python_adapter
				dap.adapters.python(function(adapter)
					python_adapter = adapter
				end, { request = "launch" })
				assert(python_adapter, "Python adapter callback did not return an adapter")

				assert(
					python_adapter.command == "/verified/debugpy-adapter",
					"Python DAP did not use the authorized path"
				)
				assert(vim.deep_equal(python_adapter.args, {}), "Python adapter argv drifted")
				assert(python_adapter.command ~= "python", "Python DAP still uses the ambiguous `python` command")
				local args_config = assert(vim.iter(dap.configurations.python):find(function(config)
					return config.name == "file:args"
				end))
				local original_input = vim.fn.input
				vim.fn.input = function()
					return [[one "two words" escaped\ space]]
				end
				local parsed_args = args_config.args()
				vim.fn.input = original_input
				assert(
					vim.deep_equal(parsed_args, { "one", "two words", "escaped space" }),
					"Python DAP quoted argv parsing drifted"
				)

				local codelldb_adapter
				dap.adapters.codelldb(function(adapter)
					codelldb_adapter = adapter
				end, { request = "launch" })
				assert(codelldb_adapter, "codelldb adapter callback did not return an adapter")
				assert(codelldb_adapter.executable.command == "/verified/codelldb", "codelldb path drifted")
				assert(
					vim.deep_equal(codelldb_adapter.executable.args, { "--port", "${port}" }),
					"codelldb adapter argv drifted"
				)
				assert(dap.adapters.lldb == dap.adapters.codelldb, "lldb was not aliased to codelldb")
				assert(dap.adapters.cppdbg == nil, "cppdbg still aliases the incompatible codelldb adapter")
				local original_dap_notify = vim.notify
				local dap_notifications = {}
				vim.notify = function(message, level)
					dap_notifications[#dap_notifications + 1] = { message = tostring(message), level = level }
				end
				local cppdbg_source = { type = "cppdbg", request = "launch", MIMode = "gdb" }
				local rejected = dap.listeners.on_config.nvim_config_cppdbg(cppdbg_source)
				vim.notify = original_dap_notify
				assert(rejected ~= cppdbg_source and rejected.type == dap.ABORT, "cppdbg did not abort before spawn")
				assert(cppdbg_source.type == "cppdbg", "cppdbg rejection mutated launch.json input")
				assert(
					dap_notifications[1]
						and dap_notifications[1].level == vim.log.levels.WARN
						and dap_notifications[1].message:find("Microsoft C/C++ adapter", 1, true),
					"cppdbg rejection was not reported"
				)
				assert(
					dap.listeners.on_config.nvim_config_python(rejected) == rejected,
					"Python DAP processing copied away another listener's abort sentinel"
				)
				local expanded_ok, expanded_err = pcall(dap.listeners.on_config["dap.expand_variable"], rejected)
				assert(
					not expanded_ok and tostring(expanded_err):find("configuration aborted", 1, true),
					"nvim-dap variable expansion did not stop an aborted restart"
				)
				assert(dap.configurations.rust == nil, "Rust DAP configuration remains")
				assert(dap.configurations.go == nil, "Go DAP configuration remains")
				assert(package.loaded["config.tool_bootstrap"] == nil, "DAP setup loaded tool bootstrap")
				assert(package.loaded.verified_tools == nil, "DAP setup loaded verified-tools")
				assert(
					not vim.tbl_contains(require("plugins.dap")[1].dependencies, "leoluz/nvim-dap-go"),
					"nvim-dap-go dependency remains"
				)
				assert(
					require("plugins.cmake-tools")[1].opts().cmake_regenerate_on_save == false,
					"CMake regeneration on save must default to off"
				)

				assert(vim.g.conform_format_on_save == false, "global autoformat must default to off")
				local original_notify = vim.notify
				local notifications = {}
				vim.notify = function(message)
					notifications[#notifications + 1] = tostring(message)
				end

				local format_ok, format_err = xpcall(function()
					vim.b.conform_format_on_save = nil
					vim.g.conform_format_on_save = false
					vim.cmd("FormatToggle!")
					assert(vim.b.conform_format_on_save == true, "global-off buffer override did not enable formatting")

					assert(
						notifications[#notifications]:find("buffer override", 1, true),
						"buffer notification is unclear"
					)
					assert(notifications[#notifications]:find("effective", 1, true), "effective state is missing")

					vim.b.conform_format_on_save = nil
					vim.g.conform_format_on_save = true
					vim.cmd("FormatToggle!")
					assert(
						vim.b.conform_format_on_save == false,
						"global-on buffer override did not disable formatting"
					)
				end, debug.traceback)
				vim.notify = original_notify
				vim.g.conform_format_on_save = false
				vim.b.conform_format_on_save = nil
				assert(format_ok, format_err)

				local formatting_spec = require("plugins.formatting")[1]
				local formatters = formatting_spec.opts.formatters_by_ft
				assert(formatters.go == nil, "Go formatter remains configured")
				assert(formatters.rust == nil, "rustfmt remains configured without a manifest contract")
				assert(vim.deep_equal(formatters.python, { "ruff_format" }), "Python is not ruff-format only")
				assert(vim.deep_equal(formatters.toml, { "tombi" }), "TOML is not Tombi-only")
				assert(
					formatting_spec.opts.formatters.tombi.env.XDG_CONFIG_HOME == vim.fn.stdpath("config"),
					"Tombi formatter does not use the versioned default config"
				)
				for _, ft in ipairs({
					"javascript",
					"typescript",
					"javascriptreact",
					"typescriptreact",
					"json",
					"jsonc",
					"yaml",
					"markdown",
				}) do
					assert(vim.deep_equal(formatters[ft], { "prettierd" }), ft .. " formatter chain drifted")
				end

				local actual_conform = package.loaded.conform
				local format_calls = {}
				package.loaded.conform = {
					format = function(options)
						format_calls[#format_calls + 1] = vim.deepcopy(options)
						return true
					end,
				}
				package.loaded["config.formatting"] = nil
				local formatting = require("config.formatting")
				vim.g.conform_format_on_save = true
				local save_options = assert(formatting_spec.opts.format_on_save(0))
				assert(save_options.lsp_format == "never", "format-on-save permits LSP fallback")
				formatting.format({ async = true })
				vim.cmd("FormatFile")
				require("config.menu.actions").execute("format.buffer")
				require("config.menu.actions").execute("lsp.format")
				assert(#format_calls == 4, "format entry points did not share the external formatter helper")
				for _, options in ipairs(format_calls) do
					assert(options.lsp_format == "never", "format entry point permits LSP fallback")
					assert(options.lsp_fallback == false, "format entry point permits legacy LSP fallback")
				end
				vim.g.conform_format_on_save = false
				package.loaded.conform = actual_conform
				package.loaded["config.formatting"] = nil

				local smart_splits = require("plugins.smart-splits")
				assert(smart_splits.lazy ~= false, "smart-splits still loads eagerly before its key handlers")
				assert(
					smart_splits.opts.multiplexer_integration == nil,
					"smart-splits still forces a multiplexer backend"
				)
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			print("tooling_ui_spec: 3 tests passed")
			vim.cmd("quitall!")
		end)
	end,
})
