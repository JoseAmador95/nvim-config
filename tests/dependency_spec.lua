vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("dependency_spec: " .. message)
	vim.cmd("cquit")
end

local function require_table(name)
	local ok, module = pcall(require, name)
	assert(ok, ("cannot require %s: %s"):format(name, tostring(module)))
	assert(type(module) == "table", name .. " did not return a table")
	return module
end

local function function_upvalue(callback, name)
	for index = 1, 32 do
		local found, value = debug.getupvalue(callback, index)
		if not found then
			break
		end
		if found == name then
			return value
		end
	end
	return nil
end

local function find_mapping(mappings, lhs)
	local matches = {}
	for _, mapping in ipairs(mappings) do
		if mapping[1] == "n" and mapping[2] == lhs then
			matches[#matches + 1] = mapping
		end
	end
	assert(#matches == 1, ("expected one normal %s mapping, got %d"):format(lhs, #matches))
	return matches[1]
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local original_notify = vim.notify
			vim.notify = function() end

			local ok, err = xpcall(function()
				for _, module in ipairs({ "coverage", "nvim-navic", "venv-selector" }) do
					assert(package.loaded[module] == nil, "Phase 2 plugin loaded eagerly: " .. module)
				end
				require("lazy").load({
					plugins = {
						"SchemaStore.nvim",
						"diffview-plus.nvim",
						"grug-far.nvim",
						"mason-lspconfig.nvim",
						"neoconf.nvim",
						"neotest",
						"nvim-lint",
						"nvim-surround",
						"nvim-treesitter-context",
						"nvim-treesitter-textobjects",
						"nvim-web-devicons",
						"rainbow-delimiters.nvim",
						"smart-splits.nvim",
					},
				})

				local schemastore = require_table("schemastore")
				assert(#schemastore.json.schemas() > 0, "SchemaStore JSON catalog is empty")
				assert(not vim.tbl_isempty(schemastore.yaml.schemas()), "SchemaStore YAML catalog is empty")

				local grug = require_table("grug-far")
				assert(type(grug.open) == "function", "grug-far open API is missing")
				assert(type(grug.toggle_instance) == "function", "grug-far toggle API is missing")
				local results = require_table("grug-far.render.resultsList")
				assert(
					type(results.getResultLocationAtCursor) == "function",
					"the encapsulated grug-far result-location seam changed"
				)

				local mason_lsp = require_table("mason-lspconfig")
				assert(type(mason_lsp.setup) == "function", "mason-lspconfig setup API is missing")
				assert(type(require_table("neoconf").get) == "function", "neoconf public get API is missing")

				local neotest = require_table("neotest")
				assert(type(neotest.run.run) == "function", "Neotest run API is missing")
				assert(type(neotest.summary.toggle) == "function", "Neotest summary API is missing")

				local treesitter = require_table("nvim-treesitter")
				assert(type(treesitter.install) == "function", "Tree-sitter install Task API is missing")
				assert(type(require_table("nvim-treesitter-textobjects.select").select_textobject) == "function")
				assert(type(require_table("treesitter-context").setup) == "function")

				local devicons = require_table("nvim-web-devicons")
				local icon = devicons.get_icon("photo.heic", "heic", { default = false })
				assert(icon ~= nil, "updated devicons HEIC entry is unavailable")

				assert(type(require_table("rainbow-delimiters").strategy) == "table")
				local diffview_actions = require_table("diffview.actions")
				assert(type(diffview_actions.cycle_layout) == "function", "Diffview layout cycle API is missing")
				assert(type(diffview_actions.focus_entry) == "function", "Diffview focus-entry API is missing")
				assert(type(diffview_actions.set_layout) == "function", "Diffview layout selection API is missing")
				local diffview_config = require_table("diffview.config").get_config()
				assert(diffview_config.view.default.layout == "diff2_horizontal", "Diffview default layout drifted")
				assert(diffview_config.view.inline.style == "unified", "Diffview inline layout style drifted")
				assert(
					vim.deep_equal(diffview_config.view.cycle_layouts.default, {
						"diff2_horizontal",
						"diff2_vertical",
					}),
					"ordinary Diffview layout cycle was changed"
				)
				local layout_mapping
				for _, mapping in ipairs(diffview_config.keymaps.view) do
					if mapping[2] == "g<C-x>" then
						layout_mapping = mapping[3]
					end
				end
				assert(
					type(layout_mapping) == "function" and layout_mapping ~= diffview_actions.cycle_layout,
					"review-aware layout mapping is missing"
				)
				for _, panel in ipairs({ "file_panel", "file_history_panel" }) do
					local entry_mappings = {}
					for _, mapping in ipairs(diffview_config.keymaps[panel]) do
						if mapping[2] == "<cr>" then
							entry_mappings[#entry_mappings + 1] = mapping[3]
						end
					end
					assert(#entry_mappings == 1, panel .. " must have exactly one lowercase <cr> mapping")
					assert(
						type(entry_mappings[1]) == "function"
							and entry_mappings[1] ~= diffview_actions.select_entry
							and entry_mappings[1] ~= diffview_actions.focus_entry,
						panel .. " is missing its review-aware entry mapping"
					)
				end
				local inline_diffget
				for _, mapping in ipairs(diffview_config.keymaps.diff1_inline) do
					if mapping[2] == "do" then
						inline_diffget = mapping[3]
					end
				end
				assert(
					type(inline_diffget) == "function" and inline_diffget ~= diffview_actions.diffget_inline,
					"inline diffget is not protected by the review guard"
				)

				local review_commands = require_table("config.code_review")
				local review_groups = review_commands.help_groups()
				assert(review_groups.common == "review" and review_groups.diff_line == "review_diff")
				local common_help = diffview_config.keymaps[review_groups.common]
				local diff_line_help = diffview_config.keymaps[review_groups.diff_line]
				assert(type(common_help) == "table" and #common_help == 13, "common review help group is missing")
				assert(
					type(diff_line_help) == "table" and #diff_line_help == 3,
					"diff-line review help group is missing"
				)
				for _, mapping in ipairs(vim.list_extend(vim.deepcopy(common_help), diff_line_help)) do
					assert(mapping[1] == "n", "review help contains a non-normal mapping")
					assert(type(mapping[2]) == "string" and mapping[2] ~= "", "review help mapping is missing its LHS")
					assert(type(mapping[3]) == "string" and mapping[3] ~= "", "review help mapping is missing its RHS")
					assert(
						type(mapping[4]) == "table" and type(mapping[4].desc) == "string" and mapping[4].desc ~= "",
						"review help mapping is missing its description"
					)
				end
				assert(vim.deep_equal(
					vim.tbl_map(function(mapping)
						return mapping[2]
					end, diff_line_help),
					{ "<leader>Ra", "<leader>Rc", "<leader>Rd" }
				))

				local original_help_groups = {
					diff1 = { "view", "diff1" },
					diff1_inline = { "view", "diff1", "diff1_inline" },
					diff2 = { "view", "diff2" },
					diff3 = { "view", "diff3" },
					diff4 = { "view", "diff4" },
					file_panel = { "file_panel" },
					file_history_panel = { "file_history_panel" },
				}
				for group, original_groups in pairs(original_help_groups) do
					local mapping = find_mapping(diffview_config.keymaps[group], "g?")
					assert(mapping[4].desc == "Open the help panel", group .. " help description drifted")
					local fallback = function_upvalue(mapping[3], "fallback")
					local review_help = function_upvalue(mapping[3], "review_help")
					assert(
						type(fallback) == "function" and type(review_help) == "function",
						group .. " help router is missing"
					)
					assert(
						vim.deep_equal(function_upvalue(fallback, "keymap_groups"), original_groups),
						group .. " changed ordinary Diffview help groups"
					)
					local expected_review_groups = vim.deepcopy(original_groups)
					expected_review_groups[#expected_review_groups + 1] = review_groups.common
					if group ~= "file_panel" and group ~= "file_history_panel" then
						expected_review_groups[#expected_review_groups + 1] = review_groups.diff_line
					end
					assert(
						vim.deep_equal(function_upvalue(review_help, "keymap_groups"), expected_review_groups),
						group .. " review help groups are incomplete"
					)
				end

				local splits = require_table("smart-splits")
				assert(type(splits.resize_left) == "function", "smart-splits resize API is missing")
				assert(type(splits.move_cursor_left) == "function", "smart-splits move API is missing")

				local split_config = require_table("smart-splits.config")
				local saved = {
					term_program = vim.env.TERM_PROGRAM,
					herdr = vim.env.HERDR_ENV,
					zellij = vim.env.ZELLIJ,
					override = vim.g.smart_splits_multiplexer_integration,
				}
				local function detect(term, herdr, zellij, override)
					vim.env.TERM_PROGRAM = term
					vim.env.HERDR_ENV = herdr
					vim.env.ZELLIJ = zellij
					vim.g.smart_splits_multiplexer_integration = override
					split_config.multiplexer_integration = nil
					split_config.set_default_multiplexer()
					return split_config.multiplexer_integration
				end
				assert(detect(nil, nil, nil, nil) == nil, "clean environment selected a multiplexer")
				assert(detect("tmux", nil, nil, nil) == "tmux", "tmux was not detected")
				assert(detect(nil, nil, "1", nil) == "zellij", "Zellij was not detected")
				assert(detect("tmux", "1", nil, nil) == "herdr", "Herdr did not take precedence over tmux")
				assert(detect("tmux", "1", nil, 0) == false, "explicit mux disable was ignored")
				vim.env.TERM_PROGRAM = saved.term_program
				vim.env.HERDR_ENV = saved.herdr
				vim.env.ZELLIJ = saved.zellij
				vim.g.smart_splits_multiplexer_integration = saved.override
				split_config.multiplexer_integration = nil

				local lint = require_table("lint")
				assert(vim.deep_equal(lint.linters_by_ft.dockerfile, { "hadolint" }), "Docker lint mapping drifted")
				assert(
					vim.deep_equal(lint.linters_by_ft.markdown, { "markdownlint-cli2" }),
					"Markdown lint mapping drifted"
				)
				assert(type(require_table("nvim-surround").setup) == "function", "nvim-surround setup API is missing")
				assert(require("plugins.surround").version == "^4.0.0", "nvim-surround major constraint drifted")

				local plugins = {}
				for _, plugin in ipairs(require("lazy").plugins()) do
					plugins[plugin.name] = plugin
				end
				for _, name in ipairs({
					"bookmarks.nvim",
					"codecompanion.nvim",
					"dressing.nvim",
					"git-conflict.nvim",
					"mermaid-nvim",
					"neogen",
					"neogit",
					"obsidian.nvim",
					"octo.nvim",
					"outline.nvim",
					"overseer.nvim",
					"nvim-notify",
					"rainbow_csv.nvim",
					"remote-nvim.nvim",
					"sqlite.lua",
					"telescope-smart-history.nvim",
					"telescope.nvim",
					"toggleterm.nvim",
					"zk-nvim",
				}) do
					assert(plugins[name] == nil, "removed plugin remains in the full profile: " .. name)
				end
				for _, name in ipairs({ "diffview-plus.nvim", "gitsigns.nvim", "snacks.nvim" }) do
					assert(plugins[name] ~= nil, "retained Git workflow is missing: " .. name)
				end
				assert(plugins["diffview.nvim"] == nil, "retired Diffview source remains in the full profile")
				assert(plugins["diffview-plus.nvim"].version == "v0.37", "diffview-plus version constraint drifted")
				for _, name in ipairs({ "nvim-coverage", "nvim-navic", "venv-selector.nvim" }) do
					assert(plugins[name] ~= nil, "Phase 2 dependency is missing: " .. name)
				end
				assert(package.loaded["nvim-navic"] == nil, "nvim-navic loaded before LspAttach")
				assert(package.loaded.coverage == nil, "nvim-coverage loaded without a coverage command")
				assert(vim.fn.exists(":LazyGit") == 2, "LazyGit command is missing")
				for _, name in ipairs({ "DevPodUp", "DevPodRecreate", "DevPodStatus", "DevPodLog", "HostEditor" }) do
					assert(vim.fn.exists(":" .. name) == 2, "DevPod command is missing: " .. name)
				end
				assert(vim.fn.exists(":DevcontainerShell") == 0, "retired devcontainer shell remains")
				for _, name in ipairs({
					"ClangdSwitchSourceHeader",
					"CoverageClear",
					"CoverageLoad",
					"CoverageSummary",
					"JustImportLast",
					"JustRun",
					"Scratch",
				}) do
					assert(vim.fn.exists(":" .. name) == 2, "Phase 2 command is missing: " .. name)
				end
				for _, name in ipairs({
					"BookmarksMark",
					"CodeCompanion",
					"MermaidPreview",
					"Neogen",
					"Neogit",
					"Obsidian",
					"Octo",
					"Outline",
					"OverseerRun",
					"PlantumlAscii",
					"PlantumlPreview",
					"RemoteStart",
					"Telescope",
					"ZkNew",
				}) do
					assert(vim.fn.exists(":" .. name) == 0, "removed command remains: " .. name)
				end
			end, debug.traceback)

			vim.notify = original_notify
			if not ok then
				fail(err)
				return
			end

			print("dependency_spec: updated plugin APIs are compatible")
			vim.cmd("quitall!")
		end)
	end,
})
