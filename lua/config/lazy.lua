-- lua/config/lazy.lua
-- Bootstrap lazy.nvim and load plugin specs from lua/plugins/

local fn = vim.fn
local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"

if not vim.loop.fs_stat(lazypath) then
	fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup("plugins", {
	defaults = { lazy = true }, -- lazy-load by default
	ui = { border = "rounded" },
	change_detection = { notify = false },
	performance = {
		rtp = { disabled_plugins = { "gzip", "tarPlugin", "zipPlugin", "netrwPlugin" } },
	},
})
