-- Core Settings ------------------------------------------------------------
-- Disable netrw at the very start of your init.lua
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- optionally enable 24-bit colour
vim.opt.termguicolors = true

-- Disable compatibility mode (for Vim compatibility clarity)
vim.opt.compatible = false

-- Leader Key
vim.g.mapleader = "," -- Change to any preferred leader key

-- Enable persistent undo and set undo file directory
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("config") .. "/undodir"

-- Clipboard -----------------------------------------------------------------

-- Enable system clipboard integration
vim.opt.clipboard = "unnamedplus"

-- Delete without affecting the clipboard
vim.api.nvim_set_keymap('n', 'd', '"_d', { noremap = true, silent = true })
vim.api.nvim_set_keymap('v', 'd', '"_d', { noremap = true, silent = true })

-- Cut (delete and yank) behavior explicitly set to the clipboard
vim.api.nvim_set_keymap('n', 'c', '"_c', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', 'x', '"_x', { noremap = true, silent = true })

-- Interface and Display Options ---------------------------------------------

-- Display settings
vim.opt.cmdheight = 1 -- Command line height
vim.opt.cursorline = true -- Highlight the cursor line
vim.opt.foldcolumn = "1" -- Show a small column for folding
vim.opt.number = true -- Show line numbers
vim.opt.relativenumber = true -- Show relative line numbers
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

-- Tab and Indent Settings ---------------------------------------------------

vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.tabstop = 4 -- Number of spaces per tab
vim.opt.shiftwidth = 4 -- Indentation width
vim.opt.smarttab = true -- Smart indentation

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
vim.api.nvim_create_autocmd({"FocusGained", "BufEnter"}, {
    command = "checktime"
})

-- Auto-reload configuration on save
vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "init.lua",
    command = "source $MYVIMRC"
})

-- Automatically remove trailing whitespace on save for specific file types
function CleanExtraSpaces()
    local save_cursor = vim.fn.getpos(".")
    local old_query = vim.fn.getreg('/')
    vim.cmd([[silent! %s/\s\+$//e]])
    vim.fn.setpos('.', save_cursor)
    vim.fn.setreg('/', old_query)
end

vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = {"*.txt", "*.js", "*.py", "*.wiki", "*.sh", "*.coffee"},
    callback = CleanExtraSpaces
})

-- Key Mappings -------------------------------------------------------------

-- Map 'jj' to exit Insert mode
vim.api.nvim_set_keymap('i', 'jj', '<Esc>', {
    noremap = true,
    silent = true
})

-- Fast saving and quitting
vim.api.nvim_set_keymap('n', '<leader>w', ':w!<CR>', {
    noremap = true,
    silent = true
})
vim.api.nvim_set_keymap('n', '<leader>q', ':q<CR>', {
    noremap = true,
    silent = true
})
vim.api.nvim_set_keymap('n', '<leader>Q', ':q!<CR>', {
    noremap = true,
    silent = true
})
vim.api.nvim_set_keymap('n', '<leader>x', ':x<CR>', {
    noremap = true,
    silent = true
})

-- Custom command to save with sudo
vim.api.nvim_create_user_command('W', 'w !sudo tee % > /dev/null', {})

-- Copy and paste with Command keys in Visual mode
vim.api.nvim_set_keymap('v', '<D-c>', '"+y', {
    noremap = true,
    silent = true
})

-- Toggle paste mode with leader+pp
vim.api.nvim_set_keymap('n', '<leader>pp', ':setlocal paste!<CR>', {
    noremap = true,
    silent = true
})

-- Undo and redo with Command keys
vim.api.nvim_set_keymap('n', '<D-z>', 'u', {
    noremap = true,
    silent = true
})
vim.api.nvim_set_keymap('n', '<D-Z>', '<C-r>', {
    noremap = true,
    silent = true
})

-- Clear search highlights with leader+Enter
vim.api.nvim_set_keymap('n', '<leader><CR>', ':nohlsearch<CR>', {
    noremap = true,
    silent = true
})

-- Toggle spell checking
vim.api.nvim_set_keymap('n', '<leader>ss', ':setlocal spell!<CR>', {
    noremap = true,
    silent = true
})

-- Map 0 to go to the first character of the line
vim.api.nvim_set_keymap('n', '0', '^', { noremap = true, silent = true })

-- Window Navigation --------------------------------------------------------

-- Navigate tabs with JK
vim.cmd([[
nnoremap J <Cmd>Tabprevious<CR>
nnoremap K <Cmd>Tabnext<CR>
]])

-- Enhancements -------------------------------------------------------------

-- Visual mode enhancements for searching with *
vim.api.nvim_set_keymap('v', '*', [[:<C-u>call VisualSelection('', '')<CR>/<C-R>=@/<CR><CR>]], {
    noremap = true,
    silent = true
})

vim.api.nvim_set_keymap('v', '#', [[:<C-u>call VisualSelection('', '')<CR>?<C-R>=@/<CR><CR>]], {
    noremap = true,
    silent = true
})

-- Custom command to reload configuration
vim.api.nvim_create_user_command('ReloadConfig', 'source $MYVIMRC', {})

-- Plugins --------------------------------------------------------------------

require('package_manager')
require('cfg-vscode-multi-cursor')
require('cfg-telescope')
require('cfg-nvim-tree')
require('cfg-nvim-cokeline')

