-- lua/plugins/lsp.lua (Neovim 0.11+ style)
return {
	-- Mason core: install/manage LSP servers & tools
	{
		"williamboman/mason.nvim",
		lazy = false, -- start at boot so :Mason is available
		build = ":MasonUpdate",
		config = function()
			require("mason").setup()
		end,
	},

	-- Mason bridge for Neovim LSP
	{
		"williamboman/mason-lspconfig.nvim",
		event = { "BufReadPre", "BufNewFile" }, -- load when editing files
		dependencies = {
			"hrsh7th/cmp-nvim-lsp", -- capabilities for nvim-cmp
			"b0o/SchemaStore.nvim",
			-- NOTE: we no longer depend on "neovim/nvim-lspconfig" framework calls.
			-- nvim-lspconfig is still useful because it ships the server configs in `lsp/`,
			-- which Neovim 0.11+ auto-merges when you call vim.lsp.config().
			"neovim/nvim-lspconfig",
		},
		config = function()
			local mlsp = require("mason-lspconfig")
			local devcontainer_tools = require("config.devcontainer_tools")
			local has_cmake_language_server = vim.fn.executable("cmake-language-server") == 1

			local ensure_servers = {
				"bashls",
				"clangd",
				"jsonls",
				"lua_ls",
				"marksman",
				"pyright",
				"ruff",
				"taplo",
				"yamlls",
			}

			if not has_cmake_language_server then
				table.insert(ensure_servers, "cmake")
			end

			-- Ensure the servers exist; Mason will install them if missing
			mlsp.setup({
				ensure_installed = ensure_servers,
			})

			--------------------------------------------------------------------------
			-- nvim-cmp capabilities
			--------------------------------------------------------------------------
			local capabilities = require("cmp_nvim_lsp").default_capabilities()
			local has_schemastore, schemastore = pcall(require, "schemastore")

			-- Global on_attach-style keymaps (recommended with new API)
			-- Use LspAttach so it applies to any server that attaches later.
			vim.api.nvim_create_autocmd("LspAttach", {
				group = vim.api.nvim_create_augroup("LspKeymaps", { clear = true }),
				callback = function(ev)
					-- SYMBOL NAVIGATION
					vim.keymap.set(
						"n",
						"gd",
						vim.lsp.buf.definition,
						{ buffer = ev.buff, silent = true, desc = "Go to definition" }
					)
					vim.keymap.set(
						"n",
						"gD",
						vim.lsp.buf.declaration,
						{ buffer = ev.buff, silent = true, desc = "Go to declaration" }
					)
					vim.keymap.set(
						"n",
						"gi",
						vim.lsp.buf.implementation,
						{ buffer = ev.buff, silent = true, desc = "Go to implementation" }
					)
					vim.keymap.set(
						"n",
						"gr",
						vim.lsp.buf.references,
						{ buffer = ev.buff, silent = true, desc = "References" }
					)

					-- DOCUMENTATION (HOVER)
					vim.keymap.set(
						"n",
						"<leader>.",
						vim.lsp.buf.hover,
						{ buffer = ev.buff, silent = true, desc = "Hover symbol documentation" }
					) --

					-- SIGNATURE HELP
					vim.keymap.set(
						"n",
						"<C-k>",
						vim.lsp.buf.signature_help,
						{ buffer = ev.buff, silent = true, desc = "Signature help" }
					)

					-- SYMBOL RENAME
					vim.keymap.set(
						"n",
						"<leader>rn",
						vim.lsp.buf.rename,
						{ buffer = ev.buff, silent = true, desc = "Rename" }
					)
				end,
			})

			--------------------------------------------------------------------------
			-- Register server configurations (vim.lsp.config) and enable them
			-- Neovim 0.11+ will merge these with the canonical configs shipped by
			-- nvim-lspconfig in its `lsp/` directory.
			--------------------------------------------------------------------------

			-- C/C++: clangd
			vim.lsp.config("clangd", {
				capabilities = capabilities,
				cmd = devcontainer_tools.clangd_cmd({
					"--background-index",
					"--clang-tidy",
					"--cross-file-rename",
					"--completion-style=detailed",
					"--header-insertion=never",
				}),
				-- filetypes/root_markers are provided by lspconfig's clangd config; we can
				-- override here if needed.
			})

			-- Python: pyright
			vim.lsp.config("pyright", {
				capabilities = capabilities,
				settings = {
					pyright = {
						disableOrganizeImports = true,
					},
				},
			})

			vim.lsp.config("ruff", {
				capabilities = capabilities,
			})

			local cmake_cmd = vim.fn.exepath("cmake-language-server")
			vim.lsp.config("cmake", {
				capabilities = capabilities,
				cmd = cmake_cmd ~= "" and { cmake_cmd } or nil,
			})

			vim.lsp.config("yamlls", {
				capabilities = capabilities,
				settings = {
					yaml = {
						keyOrdering = false,
						schemaStore = has_schemastore and { enable = false, url = "" } or { enable = true },
						schemas = has_schemastore and schemastore.yaml.schemas() or {},
					},
				},
			})

			vim.lsp.config("jsonls", {
				capabilities = capabilities,
				settings = {
					json = {
						validate = { enable = true },
						schemas = has_schemastore and schemastore.json.schemas() or {},
					},
				},
			})

			vim.lsp.config("taplo", {
				capabilities = capabilities,
			})

			vim.lsp.config("bashls", {
				capabilities = capabilities,
			})

			vim.lsp.config("marksman", {
				capabilities = capabilities,
			})

			vim.lsp.config("lua_ls", {
				capabilities = capabilities,
				settings = {
					Lua = {
						runtime = { version = "LuaJIT" },
						diagnostics = { globals = { "vim" } },
						telemetry = { enable = false },
						workspace = {
							checkThirdParty = false,
							library = vim.api.nvim_get_runtime_file("", true),
						},
					},
				},
			})

			-- Finally, enable (start) the clients for these configs
			vim.lsp.enable({
				"bashls",
				"clangd",
				"cmake",
				"jsonls",
				"lua_ls",
				"marksman",
				"pyright",
				"ruff",
				"taplo",
				"yamlls",
			})
		end,
	},

	{
		"WhoIsSethDaniel/mason-tool-installer.nvim",
		event = { "BufReadPre", "BufNewFile" },
		dependencies = { "williamboman/mason.nvim" },
		config = function()
			local has_cmake_language_server = vim.fn.executable("cmake-language-server") == 1
			local ensure_tools = {
				"bashls",
				"clangd",
				"clang-format",
				"jsonls",
				"lua_ls",
				"marksman",
				"markdownlint-cli2",
				"pyright",
				"ruff",
				"shellcheck",
				"shfmt",
				"stylua",
				"taplo",
				"yamlls",
			}

			if not has_cmake_language_server then
				table.insert(ensure_tools, "cmake")
			end

			require("mason-tool-installer").setup({
				ensure_installed = ensure_tools,
				run_on_start = true,
			})
		end,
	},
}
