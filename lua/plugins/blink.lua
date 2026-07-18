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
			-- Same behavior as cmdline below: show the menu with nothing selected
			-- so a stray <CR> just inserts a newline; the first <Tab> selects (and
			-- previews via auto_insert) the first item.
			list = { selection = { preselect = false, auto_insert = true } },
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
			completion = {
				menu = { auto_show = true },
				-- Don't pre-highlight the first item. Because the menu auto-shows
				-- while typing, blink's default `preselect = true` would leave item 1
				-- already selected, so the first <Tab> (which is `select_next`) would
				-- jump to the SECOND item. With `preselect = false` the menu shows with
				-- nothing selected and the first <Tab> selects the first item, like
				-- Vim's classic wildmenu.
				list = { selection = { preselect = false, auto_insert = true } },
			},
		},

		fuzzy = { implementation = "prefer_rust_with_warning" },
	},
	opts_extend = { "sources.default" },
}
