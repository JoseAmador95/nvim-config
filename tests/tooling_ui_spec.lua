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

				local mason_bin = require("config.tool_paths").mason_bin() .. "/"
				local expected_debugpy = vim.fn.exepath("debugpy-adapter")
				if expected_debugpy == "" then
					expected_debugpy = mason_bin .. "debugpy-adapter"
				end
				assert(python_adapter.command == expected_debugpy, "Python DAP did not resolve debugpy-adapter")
				assert(python_adapter.command ~= "python", "Python DAP still uses the ambiguous `python` command")

				local expected_codelldb = vim.fn.exepath("codelldb")
				if expected_codelldb == "" then
					expected_codelldb = mason_bin .. "codelldb"
				end
				assert(dap.adapters.codelldb ~= nil, "codelldb adapter was not registered")
				assert(
					dap.adapters.codelldb.executable.command == expected_codelldb,
					"codelldb did not use the resolved or deterministic Mason path"
				)
				assert(dap.adapters.lldb == dap.adapters.codelldb, "lldb was not aliased to codelldb")
				assert(dap.adapters.cppdbg == dap.adapters.codelldb, "cppdbg was not aliased to codelldb")
				assert(dap.configurations.rust == nil, "Rust DAP configuration remains")
				assert(dap.configurations.go == nil, "Go DAP configuration remains")
				assert(
					not vim.tbl_contains(require("plugins.dap")[1].dependencies, "leoluz/nvim-dap-go"),
					"nvim-dap-go dependency remains"
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
					assert(
						vim.deep_equal(formatters[ft], { "prettierd", "prettier", stop_after_first = true }),
						ft .. " formatter chain drifted"
					)
				end

				local actual_conform = package.loaded.conform
				local formatter_available = true
				local format_calls = {}
				package.loaded.conform = {
					list_formatters = function()
						return formatter_available and { { name = "test", available = true } } or {}
					end,
					format = function(options)
						format_calls[#format_calls + 1] = vim.deepcopy(options)
						return true
					end,
				}
				package.loaded["config.formatting"] = nil
				local formatting = require("config.formatting")
				local missing_notifications = {}
				formatting._notify = function(message, level)
					missing_notifications[#missing_notifications + 1] = { message = message, level = level }
				end
				vim.g.conform_format_on_save = true
				local save_options = assert(formatting_spec.opts.format_on_save(0))
				assert(save_options.lsp_format == "never", "format-on-save permits LSP fallback")
				formatting.format({ async = true })
				vim.cmd("FormatFile")
				require("config.menu.actions").run("format.buffer")
				require("config.menu.actions").run("lsp.format")
				assert(#format_calls == 4, "format entry points did not share the external formatter helper")
				for _, options in ipairs(format_calls) do
					assert(options.lsp_format == "never", "format entry point permits LSP fallback")
				end
				formatter_available = false
				assert(formatting.format({ async = true }) == false, "missing formatter reported success")
				assert(#format_calls == 4, "missing formatter fell through to formatting")
				assert(#missing_notifications == 1, "missing formatter notification was not emitted once")
				assert(
					missing_notifications[1].message:find("LSP formatting is disabled", 1, true),
					"missing formatter notification omitted the no-LSP contract"
				)
				vim.g.conform_format_on_save = false
				package.loaded.conform = actual_conform
				package.loaded["config.formatting"] = nil

				local smart_splits = require("plugins.smart-splits")
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
