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

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local original_notify = vim.notify
			vim.notify = function() end

			local ok, err = xpcall(function()
				require("lazy").load({
					plugins = {
						"SchemaStore.nvim",
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
					"rainbow_csv.nvim",
					"remote-nvim.nvim",
					"sqlite.lua",
					"telescope-smart-history.nvim",
					"telescope.nvim",
					"zk-nvim",
				}) do
					assert(plugins[name] == nil, "removed plugin remains in the full profile: " .. name)
				end
				for _, name in ipairs({ "diffview.nvim", "gitsigns.nvim", "toggleterm.nvim" }) do
					assert(plugins[name] ~= nil, "retained Git workflow is missing: " .. name)
				end
				assert(vim.fn.exists(":LazyGit") == 2, "LazyGit command is missing")
				assert(vim.fn.exists(":DevcontainerShell") == 2, "focused devcontainer shell is missing")
				assert(vim.fn.exists(":DevcontainerWorkspace") == 2, "devcontainer workspace selector is missing")
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
