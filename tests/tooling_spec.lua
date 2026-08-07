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
				assert(vim.lsp.is_enabled("docker_language_server"), "Docker LSP is not explicitly enabled")
				assert(not vim.lsp.is_enabled("stylua"), "Stylua was unexpectedly enabled as an LSP")
				assert(vim.lsp.config["*"].before_init == nil, "wildcard before_init hook is still configured")

				local neoconf_lsp = require("neoconf.plugins.lspconfig")
				local original_on_new_config = neoconf_lsp.on_new_config
				local merge_calls = 0
				neoconf_lsp.on_new_config = function(config)
					merge_calls = merge_calls + 1
					config.original_settings = vim.deepcopy(config.settings or {})
					config.settings = config.settings or {}
					config.settings["rust-analyzer"] = config.settings["rust-analyzer"] or {}
					config.settings["rust-analyzer"].neoconf_probe = "merged"
				end

				local rust_config = vim.lsp.config.rust_analyzer
				local runtime_config = vim.deepcopy(rust_config)
				runtime_config.name = "rust_analyzer"
				runtime_config.root_dir = vim.fn.getcwd()
				local init_params = {}
				local hook_ok, hook_err = xpcall(function()
					rust_config.before_init(init_params, runtime_config)
				end, debug.traceback)
				neoconf_lsp.on_new_config = original_on_new_config

				assert(hook_ok, hook_err)
				assert(merge_calls == 1, string.format("neoconf merge ran %d times", merge_calls))
				assert(runtime_config.original_settings ~= nil, "neoconf stage did not run")
				assert(init_params.initializationOptions ~= nil, "Rust upstream before_init did not run")
				assert(
					init_params.initializationOptions.neoconf_probe == "merged",
					"Rust upstream hook ran before neoconf settings were merged"
				)

				local unicode_buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(unicode_buf, 0, -1, false, { "a🙂b" })
				local byte_col =
					vim.lsp.util._get_line_byte_from_position(unicode_buf, { line = 0, character = 3 }, "utf-16")
				assert(byte_col == 5, string.format("UTF-16 column converted to byte %d instead of 5", byte_col))
				vim.api.nvim_buf_delete(unicode_buf, { force = true })
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
