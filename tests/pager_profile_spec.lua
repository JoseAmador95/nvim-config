local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = assert(vim.env.NVIM_CONFIG_ROOT, "NVIM_CONFIG_ROOT is missing")
vim.opt.runtimepath:prepend(vim.fs.joinpath(repo, "local-plugins", "tab-first.nvim"))

T["pager profile"] = function()
	local pager = require("config.pager")
	assert(pager.active, "pager profile was not selected")
	assert(require("config.redraw_profile").current() == "full", "pager accepted host redraw throttling")
	assert(require("config.redraw_profile").inline_diagnostics() == "off", "pager enabled inline diagnostics")
	assert(require("config.inline_diagnostics").status().mode == "off", "pager inline controller is active")
	assert(vim.diagnostic.config().virtual_lines == false, "pager left diagnostic virtual lines enabled")
	assert(vim.g.colors_name == "vscode", "pager did not apply the VSCode default")
	assert(
		vim.wait(1000, function()
			return vim.b.md_render == true
		end),
		"Markdown did not render automatically in the pager"
	)
	local state = vim.w.md_render_state
	assert(state and vim.bo[state.source_buf].filetype == "markdown", "forced pager filetype missed its source")
	assert(not vim.bo.modifiable and vim.bo.readonly, "pager reading view is editable")

	for _, command in ipairs({
		"MenuOpen",
		"NavigationBack",
		"NavigationForward",
		"NavigationHistory",
		"CloseTab",
		"ClangdSetCompileCommands",
		"ClangdSwitchSourceHeader",
		"DevContainerUp",
		"DevContainerRecreate",
		"DevContainerStatus",
		"DevContainerLog",
		"DevContainerHostEditor",
		"HexDump",
		"HexAssemble",
		"HexToggle",
		"MermaidPreview",
		"NvimConfigToolsInstall",
		"Mason",
		"PlantumlAscii",
		"PlantumlPreview",
		"ReviewOpen",
		"ReviewPanel",
		"ReviewExport",
		"ReviewRoundStart",
		"TuicrReview",
		"AgentContext",
		"AgentResultsImport",
	}) do
		assert(vim.fn.exists(":" .. command) == 0, command .. " leaked into the pager profile")
	end
	assert(package.loaded["config.exact_editor"] == nil, "exact editor adapter loaded in the pager")
	assert(package.loaded["config.editor_actions"] == nil, "editor actions loaded in the pager")
	assert(package.loaded["config.project_settings"] == nil, "project settings adapter loaded in the pager")
	assert(package.loaded.tab_first == nil, "tab-first runtime loaded in the pager")
	assert(package.loaded.treesitter_runtime ~= nil, "treesitter_runtime is missing from the pager's early allowlist")
	assert(package.loaded.trusted_workspace == nil, "removed trusted_workspace was loaded")
	for _, name in ipairs({
		"exact_editor",
		"devcontainer_editor",
		"terminal_lifecycle",
		"project_python",
		"action_palette",
		"diagram_view",
		"log_workbench.matches",
		"log_workbench.follow",
		"clangd_compile_db",
		"verified_tools",
		"native_review",
	}) do
		assert(package.loaded[name] == nil, name .. " crossed the pager load boundary")
	end
	assert(_G.ExactEditorRequest == nil, "exact editor RPC function leaked into the pager")
	assert(vim.fn.exists(":NvimConfigParsersInstall") == 2, "explicit parser installer is missing from the pager")
	assert(vim.fn.exists(":SetFileType") == 2, "pager SetFileType command is missing")
	assert(vim.fn.exists(":MarkdownView") == 2, "pager MarkdownView command is missing")
	assert(vim.fn.exists(":DiagramShow") == 2, "pager diagram command is missing")
	assert(vim.fn.exists(":JsonTree") == 0, "JsonTree leaked into the pager")
	assert(vim.fn.exists(":JqxList") == 0, "JqxList leaked into the pager")

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
		"bufferline.nvim",
		"hex.nvim",
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
	assert(has_plugin("md-render.nvim"), "md-render is missing from the pager")
	assert(not has_plugin("render-markdown.nvim"), "inline renderer leaked into the pager")
	assert(has_plugin("nvim-treesitter"), "Tree-sitter is missing from the pager")
	assert(has_plugin("vscode.nvim"), "VSCode theme is missing from the pager")
	assert(Snacks.config.dashboard.enabled == false, "editor dashboard leaked into the pager")
	assert(Snacks.config.notifier.enabled == false, "notifier leaked into the pager")
	assert(Snacks.config.terminal.enabled == false, "terminal service leaked into the pager")

	local installed = {}
	for _, parser in ipairs(require("nvim-treesitter").get_installed("parsers")) do
		installed[parser] = true
	end
	for _, parser in ipairs(pager.parsers) do
		assert(installed[parser], "configured pager parser is missing: " .. parser)
	end

	local menu_map = vim.fn.maparg("<leader><leader>", "n", false, true)
	assert(vim.tbl_isempty(menu_map), "menu mapping leaked into the pager")
	assert(vim.tbl_isempty(vim.fn.maparg("gf", "n", false, true)), "editor gf mapping leaked into the pager")
	assert(
		vim.tbl_isempty(vim.fn.maparg("<leader><leader>", "x", false, true)),
		"visual menu mapping leaked into the pager"
	)
	local close_map = vim.fn.maparg("<leader>q", "n", false, true)
	assert(close_map.rhs == ":q<CR>", "pager close mapping was replaced by tab ownership")
	for _, lhs in ipairs({ "[b", "]b" }) do
		assert(not vim.tbl_isempty(vim.fn.maparg(lhs, "n", false, true)), lhs .. " was removed from the pager")
	end
	local diagram_map = vim.fn.maparg("<leader>md", "n", false, true)
	assert(not vim.tbl_isempty(diagram_map), "global pager diagram mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>mv", "n", false, true)), "pager Markdown view mapping is missing")
end
return T
