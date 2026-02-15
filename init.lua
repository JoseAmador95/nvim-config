-- Core Settings ------------------------------------------------------------

-- Disable netrw
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- Enable built-in regex syntax highlight immediately on file open
vim.cmd("syntax enable")

-- Leader Key
vim.g.mapleader = "," -- Change to any preferred leader key
vim.g.maplocalleader = "," -- Set a local leader key

-- Enable persistent undo and set undo file directory
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("config") .. "/.undodir"

local function prepend_path(path)
	if not path or path == "" then
		return
	end
	local current = vim.env.PATH or ""
	if not string.find(current, path, 1, true) then
		vim.env.PATH = path .. ":" .. current
	end
end

local mason_root = vim.fn.stdpath("data") .. "/mason"
prepend_path(mason_root .. "/bin")
prepend_path(mason_root .. "/build")

-- Command Pallete -----------------------------------------------------------

vim.opt.wildmode = { "longest:full" }
vim.opt.wildoptions = { "pum", "tagfile" }

-- Unused providers ---------------------------------------------------------

vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0

-- Clipboard -----------------------------------------------------------------

-- Enable system clipboard integration
vim.opt.clipboard = "unnamedplus"

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
--
-- use custom tab names
require("config.tabnames")
vim.opt.showtabline = 2
vim.opt.tabline = "%!v:lua.require'config.tabnames_tabline'.tabline()"

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
	command = "checktime",
})

-- Auto-reload configuration on save
vim.api.nvim_create_autocmd("BufWritePost", {
	pattern = "init.lua",
	command = "source $MYVIMRC",
})

-- Automatically remove trailing whitespace on save for specific file types
function CleanExtraSpaces()
	local save_cursor = vim.fn.getpos(".")
	local old_query = vim.fn.getreg("/")
	vim.cmd([[silent! %s/\s\+$//e]])
	vim.fn.setpos(".", save_cursor)
	vim.fn.setreg("/", old_query)
end

vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = { "*.txt", "*.js", "*.py", "*.wiki", "*.sh", "*.coffee" },
	callback = CleanExtraSpaces,
})

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

-- Terminal Configuration ----------------------------------------------------

-- Enable mouse support in all modes
vim.opt.mouse = "a"

-- Enhancements -------------------------------------------------------------

-- Custom command to reload configuration
vim.api.nvim_create_user_command("ReloadConfig", function()
	vim.cmd("source $MYVIMRC")
	pcall(vim.cmd, "Lazy reload")
	vim.notify("Neovim config reloaded", vim.log.levels.INFO, { title = "Config" })
end, { desc = "Reload config and plugin specs" })

-- Plugins --------------------------------------------------------------------

require("config.diagnostics")
require("config.devcontainer_tools").setup()
require("config.indent")
require("config.lsp_helpers")
require("config.lsp_commands")
require("config.lazy")

if vim.g.vscode then
	require("editor.vscode")
else
	require("editor.terminal")
end

require("config.clangd_commands")
