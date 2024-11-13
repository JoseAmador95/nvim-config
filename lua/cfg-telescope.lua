-- Bindings -------------------------------------------------------------------

-- Open file finder
vim.api.nvim_set_keymap('n', '<leader>ff', '<cmd>Telescope find_files<cr>', { noremap = true, silent = true })

-- Search for a string in the current working directory
vim.api.nvim_set_keymap( 'n', '<leader>fg', '<cmd>Telescope live_grep<cr>', { noremap = true, silent = true })

-- List open buffers
vim.api.nvim_set_keymap( 'n', '<leader>fb', '<cmd>Telescope buffers<cr>', { noremap = true, silent = true })

-- Search help tags
vim.api.nvim_set_keymap( 'n', '<leader>fh', '<cmd>Telescope help_tags<cr>', { noremap = true, silent = true })

-- Setup ----------------------------------------------------------------------

require('telescope').setup {
    defaults = {
        cwd = vim.fn.getcwd(),
        mappings = {
            i = {  -- Insert mode mappings
                ["<C-j>"] = "move_selection_next",
                ["<C-k>"] = "move_selection_previous",
                ["<C-h>"] = "move_selection_previous",  -- Optional if you want h/l for other navigation
                ["<C-l>"] = "move_selection_next",
                ["<C-q>"] = "close",  -- Close with Ctrl+q (optional)
            },
            n = {  -- Normal mode mappings
                ["j"] = "move_selection_next",
                ["k"] = "move_selection_previous",
                ["h"] = "move_selection_previous",  -- Optional, for visual consistency
                ["l"] = "move_selection_next",
                ["q"] = "close",  -- Close with q
            },
        },
    },
}
