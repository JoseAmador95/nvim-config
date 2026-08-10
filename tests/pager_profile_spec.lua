vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("pager_profile_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				local pager = require("config.pager")
				assert(pager.active, "pager profile was not selected")
				assert(require("config.theme").selection().colorscheme == "vscode", "pager default theme changed")
				assert(vim.g.colors_name == "vscode", "pager did not apply the VSCode default")
				assert(vim.bo.filetype == "markdown", "forced pager filetype was not applied")

				for _, command in ipairs({
					"MenuOpen",
					"CloseTab",
					"ClangdSetCompileCommands",
					"ClangdSwitchSourceHeader",
					"CoverageLoad",
					"CoverageSummary",
					"CoverageClear",
					"DevPodUp",
					"DevPodRecreate",
					"DevPodStatus",
					"DevPodLog",
					"HostEditor",
					"JustRun",
					"JustImportLast",
					"MermaidPreview",
					"NvimConfigToolsInstall",
					"Mason",
					"PlantumlAscii",
					"PlantumlPreview",
					"ReviewRoundStart",
					"Scratch",
					"TuicrReview",
					"AgentContext",
					"AgentResultsImport",
				}) do
					assert(vim.fn.exists(":" .. command) == 0, command .. " leaked into the pager profile")
				end
				assert(package.loaded["config.editor_rpc"] == nil, "editor RPC module loaded in the pager")
				assert(_G.NvimReviewOpenRequest == nil, "editor RPC function leaked into the pager")
				assert(
					vim.fn.exists(":NvimConfigParsersInstall") == 2,
					"explicit parser installer is missing from the pager"
				)
				assert(vim.fn.exists(":SetFileType") == 2, "pager SetFileType command is missing")
				assert(vim.fn.exists(":DiagramShow") == 2, "pager diagram command is missing")

				local runtime_paths = vim.api.nvim_list_runtime_paths()
				local function has_plugin(name)
					for _, path in ipairs(runtime_paths) do
						if vim.fn.fnamemodify(path, ":t") == name then
							return true
						end
					end
					return false
				end
				for _, plugin in ipairs({
					"blink.cmp",
					"mason.nvim",
					"mermaid-nvim",
					"noice.nvim",
					"nvim-lspconfig",
					"nvim-lint",
					"nvim-coverage",
					"nvim-navic",
					"remote-nvim.nvim",
					"venv-selector.nvim",
				}) do
					assert(not has_plugin(plugin), plugin .. " is present in the pager runtime")
				end
				assert(has_plugin("render-markdown.nvim"), "render-markdown is missing from the pager")
				assert(has_plugin("nvim-treesitter"), "Tree-sitter is missing from the pager")
				assert(has_plugin("catppuccin"), "Catppuccin alternative is missing from the pager")
				assert(Snacks.config.dashboard.enabled == false, "editor dashboard leaked into the pager")
				assert(Snacks.config.notifier.enabled == false, "notifier leaked into the pager")
				assert(Snacks.config.terminal.enabled == false, "terminal service leaked into the pager")
				assert(Snacks.config.scratch.enabled == false, "scratch service leaked into the pager")

				local installed = {}
				for _, parser in ipairs(require("nvim-treesitter").get_installed("parsers")) do
					installed[parser] = true
				end
				for _, parser in ipairs(pager.parsers) do
					assert(installed[parser], "configured pager parser is missing: " .. parser)
				end

				local menu_map = vim.fn.maparg("<leader><leader>", "n", false, true)
				assert(vim.tbl_isempty(menu_map), "menu mapping leaked into the pager")
				local close_map = vim.fn.maparg("<leader>q", "n", false, true)
				assert(close_map.rhs == ":q<CR>", "pager close mapping was replaced by tab ownership")
				for _, lhs in ipairs({ "[b", "]b" }) do
					assert(
						not vim.tbl_isempty(vim.fn.maparg(lhs, "n", false, true)),
						lhs .. " was removed from the pager"
					)
				end
				local diagram_map = vim.fn.maparg("<leader>md", "n", false, true)
				assert(not vim.tbl_isempty(diagram_map), "global pager diagram mapping is missing")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end
			print("pager_profile_spec: profile allowlist and commands are isolated")
			vim.cmd("quitall!")
		end)
	end,
})
