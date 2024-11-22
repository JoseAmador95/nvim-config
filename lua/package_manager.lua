-- Automatically install Packer if not already installed
local fn = vim.fn
local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({"git", "clone", "--depth", "1", "https://github.com/wbthomason/packer.nvim", install_path})
    vim.cmd([[packadd packer.nvim]])
end

-- Use a protected call to avoid errors on first use
local status_ok, packer = pcall(require, "packer")
if not status_ok then
    return
end

-- Initialize Packer and define plugins
packer.startup(function(use)
    -- Packer can manage itself
    use "wbthomason/packer.nvim"

    -- Add plugins here
    use "nvim-lua/plenary.nvim" -- Utility functions used by many plugins
    use "nvim-telescope/telescope.nvim" -- Fuzzy finder
    use "vscode-neovim/vscode-multi-cursor.nvim" -- Multi-cursor support in VSCode
    use 'nvim-tree/nvim-web-devicons'
    use {
        'willothy/nvim-cokeline',
        requires = {"nvim-lua/plenary.nvim", -- Required for v0.4.0+
        "nvim-tree/nvim-web-devicons", -- If you want devicons
        "stevearc/resession.nvim" -- Optional, for persistent history
        }
    }
    use {
        "nvim-tree/nvim-tree.lua",
        requires = {"nvim-tree/nvim-web-devicons"}
    }

    -- Automatically set up configuration after cloning packer.nvim
    if packer_bootstrap then
        require("packer").sync()
    end
end)
