-- Loaded with --cmd before init.lua. Extend argv here; the VimEnter assertions
-- then prove there is no delayed configuration-level lifecycle replay.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local existing_path = vim.fn.tempname() .. ".md"
local new_path = vim.fn.tempname() .. ".md"
assert(vim.fn.writefile({ "# second argument", "", "startup fixture" }, existing_path) == 0)
vim.fn.delete(new_path)
vim.cmd.argadd({ args = { existing_path, new_path } })

local filetype_events = {}
local observer = vim.api.nvim_create_augroup("StartupSpecObserver", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
	group = observer,
	callback = function(args)
		filetype_events[args.buf] = (filetype_events[args.buf] or 0) + 1
	end,
})

local function cleanup()
	vim.fn.delete(existing_path)
	vim.fn.delete(new_path)
end

local function fail(message)
	cleanup()
	vim.api.nvim_err_writeln("startup_spec: " .. message)
	vim.cmd("cquit")
end

local function same_path(left, right)
	local function canonical(path)
		return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
	end
	return canonical(left) == canonical(right)
end

local function assert_markdown_argument(label)
	local buf = vim.api.nvim_get_current_buf()
	assert(vim.bo[buf].filetype == "markdown", label .. " did not detect markdown")
	assert(
		filetype_events[buf] == 1,
		string.format("%s emitted FileType %d times (expected 1)", label, filetype_events[buf] or 0)
	)
	assert(require("render-markdown.core.manager").attached(buf), label .. " did not attach render-markdown")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(require("config.theme_default").colorscheme == "vscode", "versioned theme default changed")
				assert(require("config.theme").selection().colorscheme == "vscode", "startup theme is not VSCode")
				assert(vim.g.colors_name == "vscode", "VSCode colorscheme was not applied at startup")
				assert(require("config.dap_ui").selected() == "dap-ui", "startup did not select the default DAP UI")
				assert(package.loaded.dapui == nil, "dap-ui loaded eagerly during startup")
				assert(package.loaded["dap-view"] == nil, "dap-view loaded eagerly during startup")
				assert(vim.fn.exists(":CloseTab") == 2, "full editor CloseTab command is missing")
				for _, command in ipairs({
					"NavigationBack",
					"NavigationForward",
					"NavigationHistory",
					"ReviewRoundStart",
					"TuicrReview",
					"AgentContext",
					"AgentResultsImport",
					"ClangdSwitchSourceHeader",
					"CoverageLoad",
					"CoverageSummary",
					"CoverageClear",
					"JustRun",
					"JustImportLast",
					"Scratch",
				}) do
					assert(vim.fn.exists(":" .. command) == 2, "full editor " .. command .. " command is missing")
				end
				assert(not vim.tbl_isempty(vim.fn.maparg("<leader>t", "n", false, true)), "terminal toggle is missing")
				assert(
					not vim.tbl_isempty(vim.fn.maparg("<leader>rr", "n", false, true)),
					"nearest-test mapping is missing"
				)
				assert(
					not vim.tbl_isempty(vim.fn.maparg("<leader>rd", "n", false, true)),
					"debug-test mapping is missing"
				)
				local diagnostics = vim.diagnostic.config()
				assert(diagnostics.virtual_text == false, "diagnostic virtual text is enabled")
				assert(
					type(diagnostics.virtual_lines) == "table" and diagnostics.virtual_lines.current_line == true,
					"current-line diagnostic virtual lines are not enabled"
				)
				local close_map = vim.fn.maparg("<leader>q", "n", false, true)
				assert(close_map.rhs == "<cmd>CloseTab<cr>", "full editor close mapping bypasses CloseTab")
				local close_all_map = vim.fn.maparg("<leader>Q", "n", false, true)
				assert(close_all_map.rhs == "<cmd>CloseAll<cr>", "CloseAll mapping drifted")
				for _, lhs in ipairs({ "[b", "]b", "<leader>bd", "gF" }) do
					assert(
						vim.fn.maparg(lhs, "n", false, true).lhs == nil,
						lhs .. " duplicate buffer/file mapping remains"
					)
				end
				local menu_map = vim.fn.maparg("<leader><leader>", "n", false, true)
				assert(menu_map.rhs == "<cmd>MenuOpen<cr>", "action palette mapping drifted")
				local visual_menu_map = vim.fn.maparg("<leader><leader>", "x", false, true)
				assert(visual_menu_map.rhs == "<cmd>MenuOpen<cr>", "visual action palette mapping is missing")
				assert(
					vim.fn.maparg("<C-o>", "n", false, true).desc == "Navigation back",
					"semantic back mapping is missing"
				)
				assert(
					vim.fn.maparg("<C-i>", "n", false, true).desc == "Navigation forward",
					"semantic forward mapping is missing"
				)
				assert(
					vim.fn.maparg("<leader>nh", "n", false, true).desc == "Show navigation history",
					"navigation-history mapping is missing"
				)
				assert(not vim.lsp.inlay_hint.is_enabled({ bufnr = 0 }), "inlay hints must default off")
				require("lazy").load({ plugins = { "bufferline.nvim" } })
				local tabpage = vim.api.nvim_get_current_tabpage()
				local normal_buf = vim.api.nvim_get_current_buf()
				local normal_path = vim.api.nvim_buf_get_name(normal_buf)
				assert(normal_path ~= "", "startup float-label fixture is not a named normal buffer")
				local expected_tab_name = vim.fn.fnamemodify(normal_path, ":t")
				local float_buf = vim.api.nvim_create_buf(false, true)
				local float_win = vim.api.nvim_open_win(float_buf, true, {
					relative = "editor",
					width = 20,
					height = 1,
					row = 1,
					col = 1,
					style = "minimal",
				})
				_G.nvim_bufferline()
				local active_tab
				for _, element in ipairs(require("bufferline").get_elements().elements) do
					if element.id == tabpage then
						active_tab = element
						break
					end
				end
				assert(active_tab, "bufferline did not expose the active tab")
				assert(active_tab.name == expected_tab_name, "focused float replaced the real bufferline tab label")
				vim.api.nvim_win_close(float_win, true)
				vim.api.nvim_buf_delete(float_buf, { force = true })

				local original_visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
				local original_pmenu = vim.api.nvim_get_hl(0, { name = "PmenuSel", link = false })
				local selected_groups = {
					"BufferLineTabSelected",
					"BufferLineBufferSelected",
					"BufferLineSeparatorSelected",
					"BufferLineIndicatorSelected",
				}
				vim.api.nvim_set_hl(0, "Visual", { bg = 0x123456 })
				for _, group in ipairs(selected_groups) do
					vim.cmd("highlight clear " .. group)
				end
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_visual" })
				for _, group in ipairs(selected_groups) do
					assert(
						vim.api.nvim_get_hl(0, { name = group, link = false }).bg == 0x123456,
						group .. " did not repaint from Visual on ColorScheme"
					)
				end
				for _, group in ipairs({ "BufferLineTabSelected", "BufferLineBufferSelected" }) do
					local selected_label = vim.api.nvim_get_hl(0, { name = group, link = false })
					assert(selected_label.bold and not selected_label.italic, group .. " emphasis drifted")
				end
				assert(
					vim.api.nvim_get_hl(0, { name = "BufferLineIndicatorSelected", link = false }).fg
						== vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg,
					"selected tab indicator does not use DiagnosticInfo"
				)

				vim.api.nvim_set_hl(0, "Visual", {})
				vim.api.nvim_set_hl(0, "PmenuSel", { bg = 0x654321 })
				for _, group in ipairs(selected_groups) do
					vim.cmd("highlight clear " .. group)
				end
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_fallback" })
				assert(
					vim.api.nvim_get_hl(0, { name = "BufferLineTabSelected", link = false }).bg == 0x654321,
					"selected tab did not repaint from the PmenuSel fallback"
				)
				vim.api.nvim_set_hl(0, "Visual", original_visual)
				vim.api.nvim_set_hl(0, "PmenuSel", original_pmenu)
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_restore" })

				assert(#vim.fn.argv() == 3, "startup fixture did not create a three-file argument list")
				assert_markdown_argument("first existing argv buffer")
				assert(package.loaded.gitsigns, "BufReadPre plugin did not load for the first argv buffer")
				assert(package.loaded["todo-comments"], "BufReadPost plugin did not load for the first argv buffer")

				vim.cmd("next")
				assert(
					same_path(vim.api.nvim_buf_get_name(0), existing_path),
					"second argv buffer was not selected: " .. vim.api.nvim_buf_get_name(0)
				)
				assert_markdown_argument("second existing argv buffer")

				vim.cmd("next")
				assert(
					same_path(vim.api.nvim_buf_get_name(0), new_path),
					"new argv buffer was not selected: " .. vim.api.nvim_buf_get_name(0)
				)
				assert(vim.fn.filereadable(new_path) == 0, "new argv fixture unexpectedly exists on disk")
				assert_markdown_argument("new argv buffer")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			cleanup()
			print("startup_spec: 3 tests passed")
			vim.cmd("quitall!")
		end)
	end,
})
