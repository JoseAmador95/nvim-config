-- Core Settings ------------------------------------------------------------

-- Disable netrw
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- Leader Key
vim.g.mapleader = "," -- Change to any preferred leader key
vim.g.maplocalleader = "," -- Set a local leader key

-- Enable persistent undo and set undo file directory
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("config") .. "/.undodir"

-- Command Pallete -----------------------------------------------------------

vim.opt.wildmode = { "longest:full" }
vim.opt.wildmenu = true
vim.opt.wildoptions = { "pum", "tagfile" }

-- Unused providers ---------------------------------------------------------

vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0

-- Clipboard -----------------------------------------------------------------

-- Enable system clipboard integration
vim.opt.clipboard = "unnamedplus"

-- Interface and Display Options ---------------------------------------------

-- Display settings
vim.opt.cmdheight = 1 -- Command line height
vim.opt.cursorline = true -- Highlight the cursor line
vim.opt.foldcolumn = "1" -- Show a small column for folding
vim.opt.number = true -- Show line numbers
vim.opt.relativenumber = false -- Show relative line numbers
vim.opt.ruler = true -- Show the cursor position in the status line
vim.opt.showmatch = true -- Highlight matching brackets
vim.opt.wildmenu = true -- Enhanced command-line completion

-- Status line setup
vim.opt.laststatus = 2
vim.opt.statusline = "%F%m%r%h %w %=%{getcwd()} Line:%l Column:%c"

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
vim.o.cindent = false
vim.o.smartindent = true
vim.o.autoindent = true

-- File Management and Auto-commands -----------------------------------------

-- General file settings
vim.opt.history = 500 -- Command history length
vim.opt.autoread = true -- Auto-read when a file changes outside Neovim
vim.opt.encoding = "utf-8" -- Set default encoding
vim.opt.fileformats = "unix,dos,mac"
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

-- Map 'jj' to exit Insert mode
vim.api.nvim_set_keymap("i", "jj", "<Esc>", {
	noremap = true,
	silent = true,
})

vim.api.nvim_set_keymap("n", "<leader>q", ":q<CR>", {
	noremap = true,
	silent = true,
})
vim.api.nvim_set_keymap("n", "<leader>Q", ":q!<CR>", {
	noremap = true,
	silent = true,
})
vim.api.nvim_set_keymap("n", "<leader>x", ":x<CR>", {
	noremap = true,
	silent = true,
})

-- Custom command to save with sudo
vim.api.nvim_create_user_command("W", "w !sudo tee % > /dev/null", {})

-- Toggle paste mode with leader+pp
vim.api.nvim_set_keymap("n", "<leader>pp", ":setlocal paste!<CR>", {
	noremap = true,
	silent = true,
})

-- Clear search highlights with leader+Enter
vim.api.nvim_set_keymap("n", "<leader><CR>", ":nohlsearch<CR>", {
	noremap = true,
	silent = true,
})

-- Toggle spell checking
vim.api.nvim_set_keymap("n", "<leader>ss", ":setlocal spell!<CR>", {
	noremap = true,
	silent = true,
})

-- Map 0 to go to the first character of the line
vim.api.nvim_set_keymap("n", "0", "^", {
	noremap = true,
	silent = true,
})

-- Terminal Configuration ----------------------------------------------------

-- Enable mouse support in all modes
vim.opt.mouse = "a"

-- Terminal settings
vim.api.nvim_create_autocmd("TermOpen", {
	callback = function()
		-- Disable line numbers in terminal
		vim.opt_local.number = false
		vim.opt_local.relativenumber = false
		-- Start in insert mode
		vim.cmd("startinsert")
	end,
})

-- Window Navigation --------------------------------------------------------

-- Navigate tabs with JK
vim.cmd([[
nnoremap J <Cmd>tabprevious<CR>
nnoremap K <Cmd>tabnext<CR>
]])

-- Enhancements -------------------------------------------------------------

-- Visual mode enhancements for searching with *
vim.api.nvim_set_keymap("v", "*", [[:<C-u>call VisualSelection('', '')<CR>/<C-R>=@/<CR><CR>]], {
	noremap = true,
	silent = true,
})

vim.api.nvim_set_keymap("v", "#", [[:<C-u>call VisualSelection('', '')<CR>?<C-R>=@/<CR><CR>]], {
	noremap = true,
	silent = true,
})

-- Custom command to reload configuration
vim.api.nvim_create_user_command("ReloadConfig", "source $MYVIMRC", {})

-- Plugins --------------------------------------------------------------------

require("config.lazy")

if vim.g.vscode then
	require("editor.vscode")
else
	require("editor.terminal")
end
