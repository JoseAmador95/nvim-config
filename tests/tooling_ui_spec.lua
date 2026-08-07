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
				local python_adapter
				dap.adapters.python(function(adapter)
					python_adapter = adapter
				end, { request = "launch" })
				assert(python_adapter, "Python adapter callback did not return an adapter")

				local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
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

					local formatting_spec = require("plugins.formatting")[1]
					assert(formatting_spec.opts.format_on_save(0) ~= nil, "local-on override was not effective")
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
					assert(formatting_spec.opts.format_on_save(0) == nil, "local-off override was not effective")
				end, debug.traceback)
				vim.notify = original_notify
				vim.g.conform_format_on_save = false
				vim.b.conform_format_on_save = nil
				assert(format_ok, format_err)

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
