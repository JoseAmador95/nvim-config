vim.o.shadafile = "NONE"
vim.o.swapfile = false

local expected = assert(vim.env.NVIM_CONFIG_EXPECTED_REDRAW_PROFILE, "expected redraw profile is missing")

local function fail(message)
	vim.api.nvim_err_writeln("redraw_profile_spec: " .. message)
	vim.cmd("cquit")
end

local function plugin(specs, name)
	for _, spec in ipairs(specs) do
		if spec[1] == name then
			return spec
		end
	end
	error("plugin spec is missing: " .. name)
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				local low_bandwidth = expected == "low-bandwidth"
				local redraw_profile = require("config.redraw_profile")
				assert(redraw_profile.current() == expected, "effective redraw profile changed")
				assert(vim.wo.cursorline == not low_bandwidth, "cursorline policy changed")
				assert(vim.wo.scrolloff == (low_bandwidth and 0 or 10), "scrolloff policy changed")
				assert(vim.o.showmatch == not low_bandwidth, "showmatch policy changed")

				local diagnostics = vim.diagnostic.config()
				if low_bandwidth then
					assert(diagnostics.virtual_lines == false, "diagnostic virtual lines remained enabled")
				else
					assert(
						vim.deep_equal(diagnostics.virtual_lines, { current_line = true }),
						"full diagnostic virtual lines changed"
					)
				end

				local navic = require("plugins.navic")
				assert(navic.opts.lazy_update_context == low_bandwidth, "navic redraw policy changed")

				local illuminate = require("plugins.illuminate")
				assert(illuminate.opts.delay == (low_bandwidth and 300 or 100), "illuminate delay changed")
				assert(
					vim.deep_equal(
						illuminate.opts.providers,
						low_bandwidth and { "lsp" } or { "lsp", "treesitter", "regex" }
					),
					"illuminate providers changed"
				)

				local indent = require("plugins.indent")
				assert(indent.opts.debounce == (low_bandwidth and 500 or 200), "IBL debounce changed")
				assert(indent.opts.scope.enabled == not low_bandwidth, "IBL scope policy changed")

				local context = plugin(require("plugins.treesitter"), "nvim-treesitter/nvim-treesitter-context")
				assert(context.opts.enable == not low_bandwidth, "Tree-sitter Context policy changed")
				assert(context.opts.max_lines == 3, "Tree-sitter Context line limit changed")

				local render = require("plugins.render-markdown")
				if low_bandwidth then
					assert(vim.deep_equal(render.opts.render_modes, { "n" }), "render-markdown modes changed")
					assert(render.opts.anti_conceal.enabled == false, "render-markdown anti-conceal remained enabled")
				else
					assert(render.opts.render_modes == true, "full render-markdown modes changed")
					assert(render.opts.anti_conceal == nil, "full render-markdown anti-conceal changed")
				end

				local noice = require("plugins.noice")
				assert(
					noice.opts.lsp.progress.throttle == (low_bandwidth and 100 or 1000 / 30),
					"Noice LSP progress throttle changed"
				)

				local lualine = require("lualine").get_config()
				assert(
					lualine.options.refresh.refresh_time == (low_bandwidth and 100 or 16),
					"Lualine event refresh throttle changed"
				)
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end
			print("redraw_profile_spec: " .. expected .. " matrix passed")
			vim.cmd("quitall!")
		end)
	end,
})
