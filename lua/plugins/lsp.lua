-- lua/plugins/lsp.lua (Neovim 0.11+ style)
return {
	-- Mason core: install/manage LSP servers & tools
	{
		"williamboman/mason.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "Mason", "MasonUpdate" },
		build = ":MasonUpdate",
		config = function()
			require("mason").setup()
		end,
	},

	-- Mason bridge for Neovim LSP
	{
		"williamboman/mason-lspconfig.nvim",
		cond = function()
			return not vim.g.vscode
		end,
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

			local function safe_lsp_jump(method, title)
				return function()
					local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
					if not clients or #clients == 0 then
						vim.notify((title or "LSP") .. ": no active client for method", vim.log.levels.INFO)
						return
					end

					local position_encoding = clients[1].offset_encoding or "utf-16"
					local params = vim.lsp.util.make_position_params(0, position_encoding)
					vim.lsp.buf_request(0, method, params, function(err, result, ctx)
						local function is_list(value)
							if vim.islist then
								return vim.islist(value)
							end
							return type(value) == "table" and value[1] ~= nil
						end

						if err then
							vim.notify((title or "LSP") .. ": " .. (err.message or "request failed"), vim.log.levels.ERROR)
							return
						end

						if not result or (is_list(result) and vim.tbl_isempty(result)) then
							vim.notify((title or "LSP") .. ": no location found", vim.log.levels.INFO)
							return
						end

						local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id) or nil
						local response_encoding = client and client.offset_encoding or position_encoding

						local location = is_list(result) and result[1] or result
						local uri = location.uri or location.targetUri
						if not uri then
							vim.notify((title or "LSP") .. ": invalid location from server", vim.log.levels.WARN)
							return
						end

						if vim.startswith(uri, "file://") then
							local file = vim.uri_to_fname(uri)
							local current = vim.api.nvim_buf_get_name(0)
							local start_dir = current ~= "" and vim.fs.dirname(current) or vim.loop.cwd()
							local mapped = devcontainer_tools.container_path_to_host(file, start_dir)
							local mapped_uri = vim.uri_from_fname(mapped)
							if location.uri then
								location.uri = mapped_uri
							end
							if location.targetUri then
								location.targetUri = mapped_uri
							end
						end

						vim.lsp.util.show_document(location, response_encoding, { reuse_win = true, focus = true })
					end)
				end
			end

			local has_cmake_language_server = vim.fn.executable("cmake-language-server") == 1

			local ensure_servers = {
				"bashls",
				"clangd",
				"jsonls",
				"lemminx",
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
						safe_lsp_jump("textDocument/definition", "Go to definition"),
						{ buffer = ev.buff, silent = true, desc = "Go to definition" }
					)
					vim.keymap.set(
						"n",
						"gD",
						safe_lsp_jump("textDocument/declaration", "Go to declaration"),
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

			vim.lsp.config("lemminx", {
				capabilities = capabilities,
			})

			-- Finally, enable (start) the clients for these configs
			vim.lsp.enable({
				"bashls",
				"clangd",
				"cmake",
				"jsonls",
				"lemminx",
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
		cond = function()
			return not vim.g.vscode
		end,
		event = "VeryLazy",
		dependencies = { "williamboman/mason.nvim" },
		config = function()
			local has_cmake_language_server = vim.fn.executable("cmake-language-server") == 1
			local ensure_tools = {
				"bashls",
				"clangd",
				"clang-format",
				"jsonls",
				"jq",
				"lemminx",
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
