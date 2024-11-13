-- Enable Treesitter syntax highlighting
require'nvim-treesitter.configs'.setup {
    highlight = {
        enable = true,  -- Enable syntax highlighting
        additional_vim_regex_highlighting = false,
    },
    incremental_selection = {
        enable = true,
        keymaps = {
            init_selection = "gnn",    -- Start incremental selection
            node_incremental = "grn",  -- Increment to the next node
            scope_incremental = "grc", -- Increment to the next scope
            node_decremental = "grm",  -- Decrement selection
        },
    },
}
