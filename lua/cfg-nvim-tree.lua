
-- Configure nvim-tree
require("nvim-tree").setup({
    sync_root_with_cwd = true,       -- Sync the file tree with the current working directory
  respect_buf_cwd = true,          -- Respect the current buffer's working directory
  update_focused_file = {
    enable = true,                 -- Update the tree to focus on the file in the current buffer
    update_cwd = true,             -- Change `nvim-tree` root to the current file's directory
  },

    sort = {
        sorter = "case_sensitive",
    },
    view = {
        width = 30,
    },
    renderer = {
        group_empty = true,
    },
    filters = {
        dotfiles = true,
    },
})

-- Load nvim-web-devicons
require('nvim-web-devicons').setup {}

-- Keybinding to toggle nvim-tree
vim.api.nvim_set_keymap('n', '<leader>e', ':NvimTreeToggle<CR>', { noremap = true, silent = true })


local api = require("nvim-tree.api")

local function edit_or_open()
    local node = api.tree.get_node_under_cursor()

    if node.nodes ~= nil then
        -- expand or collapse folder
        api.node.open.edit()
    else
        -- open file
        api.node.open.edit()
        -- Close the tree if file was opened
        api.tree.close()
    end
end

-- open as vsplit on current node
local function vsplit_preview()
    local node = api.tree.get_node_under_cursor()

    if node.nodes ~= nil then
        -- expand or collapse folder
        api.node.open.edit()
    else
        -- open file as vsplit
        api.node.open.vertical()
    end

    -- Finally refocus on tree if it was lost
    api.tree.focus()
end

local function my_on_attach(bufnr)
    local api = require "nvim-tree.api"

    local function opts(desc)
        return { desc = "nvim-tree: " .. desc, buffer = bufnr, noremap = true, silent = true, nowait = true }
    end

    -- default mappings
    api.config.mappings.default_on_attach(bufnr)

    -- custom mappings
    vim.keymap.set('n', '<C-t>', api.tree.change_root_to_parent,        opts('Up'))
    vim.keymap.set('n', '?',     api.tree.toggle_help,                  opts('Help'))
    -- on_attach
    vim.keymap.set("n", "l", edit_or_open,          opts("Edit Or Open"))
    vim.keymap.set("n", "L", vsplit_preview,        opts("Vsplit Preview"))
    vim.keymap.set("n", "h", api.tree.close,        opts("Close"))
    vim.keymap.set("n", "H", api.tree.collapse_all, opts("Collapse All"))
end

-- pass to setup along with your other options
require("nvim-tree").setup {
    ---
    on_attach = my_on_attach,
    ---
}
