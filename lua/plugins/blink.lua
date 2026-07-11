-- Completion engine: blink.cmp (modern successor to nvim-cmp).
-- Rust fuzzy matcher, native LSP/path/buffer/snippet/cmdline sources.
-- Snippets are native and read VSCode-format snippets from friendly-snippets,
-- so LuaSnip / cmp_luasnip are no longer needed.
return {
	"saghen/blink.cmp",
	cond = function()
		return not vim.g.vscode
	end,
	event = { "InsertEnter", "CmdlineEnter" },
	-- Use a release tag so lazy.nvim downloads the prebuilt Rust binary
	-- (no `cargo` toolchain required).
	version = "1.*",
	dependencies = {
		"rafamadriz/friendly-snippets",
	},
	---@module "blink.cmp"
	---@type blink.cmp.Config
	opts = {
		-- <CR> accepts, <Tab>/<S-Tab> navigate the list and jump snippet
		-- placeholders, <C-Space> toggles the docs/menu (matches old cmp maps).
		keymap = {
			preset = "enter",
			["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
			["<Tab>"] = { "select_next", "snippet_forward", "fallback" },
			["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
		},

		-- Native snippet engine; loads friendly-snippets from the runtimepath.
		snippets = { preset = "default" },

		completion = {
			-- Preselect the first item so <CR> confirms it (old select = true).
			list = { selection = { preselect = true, auto_insert = false } },
			documentation = { auto_show = true },
		},

		-- LSP -> snippets -> buffer/path, same priority as the old cmp sources.
		sources = {
			default = { "lsp", "snippets", "buffer", "path" },
		},

		-- blink's default cmdline sources already mirror the old setup:
		-- ":" -> cmdline + path, "/" and "?" -> buffer.
		cmdline = {
			keymap = { preset = "cmdline" },
			completion = { menu = { auto_show = true } },
		},

		fuzzy = { implementation = "prefer_rust_with_warning" },
	},
	opts_extend = { "sources.default" },
}
