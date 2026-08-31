-- nvim-treesitter's locked `main` branch requires the Neovim 0.12 runtime
-- contract.
if vim.fn.has("nvim-0.12") ~= 1 then
	local version = vim.version()
	error(
		("This config requires Neovim 0.12 or newer (found %d.%d.%d)"):format(
			version.major,
			version.minor,
			version.patch
		)
	)
end

-- `-u /absolute/path/init.lua` does not add that directory to 'runtimepath',
-- and NVIM_APPNAME=nvimpager points it at a different config directory. Make
-- this checkout authoritative so isolated bootstrap/CI and the pager profile
-- can resolve lua/config and lua/plugins without a home-directory symlink.
local init_source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve init.lua")
local config_root = vim.fs.dirname(vim.uv.fs_realpath(init_source) or vim.fs.normalize(init_source))
vim.opt.runtimepath:prepend(config_root)

-- Local products are ordinary runtimepath entries, not remotely managed Lazy
-- plugins. Register every boundary before host configuration can require one.
require("config.local_plugins").setup()

-- Core Settings ------------------------------------------------------------

-- Disable netrw
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- Leader Key
vim.g.mapleader = " " -- Change to any preferred leader key
vim.g.maplocalleader = " " -- Set a local leader key

-- Enable persistent undo and set undo file directory
vim.opt.undofile = true
local undodir = vim.fn.stdpath("state") .. "/undo"
vim.fn.mkdir(undodir, "p", tonumber("700", 8))
local chmod_ok, chmod_err = vim.uv.fs_chmod(undodir, tonumber("700", 8))
if not chmod_ok then
	vim.notify("Could not secure undo directory: " .. tostring(chmod_err), vim.log.levels.ERROR, { title = "Config" })
end
vim.opt.undodir = undodir .. "//"

-- Apply per-host $PATH and environment overrides from ~/.nvim-local.lua early,
-- before plugins and mason rely on them.
require("config.local_config").apply_env()

-- Command Pallete -----------------------------------------------------------

vim.opt.wildmode = { "longest:full" }
vim.opt.wildoptions = { "pum", "tagfile" }

-- Unused providers ---------------------------------------------------------

vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0

-- Clipboard -----------------------------------------------------------------

-- Enable system clipboard integration
vim.opt.clipboard = "unnamedplus"

-- Over ssh the host clipboard is not the local machine's. OSC52 (built into
-- Neovim 0.10+) writes to the local clipboard through the terminal, so a yank
-- on the remote host lands in your local clipboard. Only enabled in remote
-- sessions; locally the native provider (pbcopy/wl-copy/xclip) is kept.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
	local osc52 = require("vim.ui.clipboard.osc52")
	-- Copy goes through OSC52. Paste returns the last yank (unnamed register)
	-- instead of querying the terminal, which most emulators refuse or lag on
	-- for security.
	local function paste()
		return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
	end
	vim.g.clipboard = {
		name = "OSC52",
		copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
		paste = { ["+"] = paste, ["*"] = paste },
	}
end

-- Interface and Display Options ---------------------------------------------

-- Display settings
vim.opt.cursorline = true -- Highlight the cursor line
vim.opt.foldcolumn = "1" -- Show a small column for folding
vim.opt.number = true -- Show line numbers
vim.opt.relativenumber = false -- Show relative line numbers
vim.opt.ruler = true -- Show the cursor position in the status line
vim.opt.showmatch = true -- Highlight matching brackets
vim.opt.wildmenu = true -- Enhanced command-line completion
vim.opt.signcolumn = "yes" -- Keep sign column visible
vim.opt.updatetime = 250 -- Faster CursorHold events

-- Search settings
vim.opt.ignorecase = true -- Ignore case in search
vim.opt.smartcase = true -- Smart case for search
vim.opt.incsearch = true -- Show matches as you type
vim.opt.hlsearch = true -- Highlight search results

-- Scroll off
vim.opt.scrolloff = 10

-- Tab and Indent Settings ---------------------------------------------------

vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.tabstop = 4 -- Number of spaces per tab
vim.opt.shiftwidth = 4 -- Indentation width
vim.opt.smarttab = true -- Smart indentation
vim.opt.smartindent = true
vim.opt.showtabline = 2

-- File Management and Auto-commands -----------------------------------------

-- General file settings
vim.opt.history = 500 -- Command history length
vim.opt.autoread = true -- Auto-read when a file changes outside Neovim
vim.opt.encoding = "utf-8" -- Set default encoding
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.swapfile = false

-- Auto-command to check for changes in files when refocusing Neovim
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
	group = vim.api.nvim_create_augroup("config_checktime", { clear = true }),
	command = "checktime",
})

-- Remove incidental trailing whitespace while preserving formats where it has
-- meaning. Set `vim.b.trim_trailing_whitespace = false` for any other buffer
-- that must retain it.
require("config.whitespace").setup()

-- Key Mappings -------------------------------------------------------------

-- Toggle paste mode with <leader>pp
vim.keymap.set("n", "<leader>pp", ":setlocal paste!<CR>", {
	noremap = true,
	silent = true,
	desc = "Toggle paste mode",
})

-- Clear search highlight
vim.keymap.set("n", "<leader><CR>", ":nohlsearch<CR>", {
	noremap = true,
	silent = true,
	desc = "Clear search highlight",
})

-- Toggle spell checking
vim.keymap.set("n", "<leader>ss", ":setlocal spell!<CR>", {
	noremap = true,
	silent = true,
	desc = "Toggle spell checking",
})

-- Map 0 to go to the first non-blank character on the line
vim.keymap.set("n", "H", "^", {
	noremap = true,
	silent = true,
	desc = "Beginning of indentation",
})

-- Open file under cursor in new tab
vim.keymap.set("n", "gf", require("config.editor_actions").open_file_under_cursor, {
	desc = "Open file under cursor in new tab",
})

-- Neovim 0.11+ ships gr-prefixed LSP maps (grr/grn/gri/gra/grt). This config
-- defines its own equivalents (gr, gi, <leader>lr, <leader>ca in lsp.lua);
-- the built-ins only add a timeoutlen delay to `gr`. Remove them.
for _, lhs in ipairs({ "grr", "grn", "gri", "grt" }) do
	pcall(vim.keymap.del, "n", lhs)
end
pcall(vim.keymap.del, { "n", "x" }, "gra")

-- Terminal Configuration ----------------------------------------------------

-- Enable mouse support in all modes
vim.opt.mouse = "a"

-- Enhancements -------------------------------------------------------------

-- Restarting gives plugins and module state a clean lifecycle; sourcing this
-- file into a running process cannot safely undo every plugin side effect.
vim.api.nvim_create_user_command("ReloadConfig", function()
	vim.cmd("restart")
end, { desc = "Restart Neovim to reload config" })

-- Plugins --------------------------------------------------------------------

require("config.local_config").setup()
require("config.cheatsheet")
require("config.diagnostics")

local pager = require("config.pager")
local is_vscode = vim.g.vscode == 1 or vim.g.vscode == true
local is_editor = not is_vscode and not pager.active

-- Tabs are the navigation unit in the full terminal editor. Keep Neovim's
-- native buffer-cycle maps in VSCode and nvimpager, where this tab workflow
-- does not own navigation.
if is_editor then
	for _, lhs in ipairs({ "[b", "]b" }) do
		pcall(vim.keymap.del, "n", lhs)
	end
end

-- Register profile-owned commands and FileType observers before Lazy and
-- filetype detection see the first argv buffer. VSCode deliberately keeps only
-- its action bridge; the pager gets viewer/diagram commands but no IDE tools.
if is_editor then
	local devcontainer = require("config.devcontainer")
	devcontainer.setup()
	require("config.navigation_history").setup()
	require("config.code_review").setup()
	-- exact-editor registers the runtime-specific WorkspaceKey. Container roots
	-- use their host repository identity and remain separate from host records.
	require("config.exact_editor").setup_deferred()
	require("config.indent")
	require("config.lsp_helpers")
	require("config.lsp_commands")
	require("config.viewer_commands")
	require("config.diagram").setup()
	require("config.clangd_commands")
elseif pager.active then
	require("config.viewer_commands")
	require("config.diagram").setup()
end

require("config.theme").setup()
require("config.lazy")

-- `:syntax enable` also enables filetype detection and replays it for buffers
-- that already exist. Lazy must register its documented event handlers first
-- so argv buffers follow the normal lifecycle without private event replay.
if pager.active then
	pager.apply_stdin_filetype(vim.api.nvim_get_current_buf())
end
vim.cmd("syntax enable")

-- Pager-only commands/keymaps (nvimpager); no-op in normal/vscode nvim.
pager.setup()

if is_vscode then
	require("editor.vscode")
else
	require("editor.terminal")
end

-- External bootstrap/check scripts use this sentinel because Neovim can report
-- an init.lua error yet still return a successful process status.
vim.g.nvim_config_initialized = true
