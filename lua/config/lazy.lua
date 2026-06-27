-- lua/config/lazy.lua
-- Bootstrap lazy.nvim and load plugin specs from lua/plugins/

local fn = vim.fn
local uv = vim.uv
local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"

if not uv.fs_stat(lazypath) then
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

-- Native specs from lua/plugins, plus any external dirs from ~/.nvim-local.lua.
local specs = { { import = "plugins" } }
for _, dir in ipairs(require("config.local_config").get("plugins_dir", {})) do
	dir = fn.expand(dir)
	if fn.isdirectory(dir) == 1 then
		for _, file in ipairs(fn.glob(dir .. "/*.lua", true, true)) do
			-- External specs are arbitrary code that also installs plugins, so
			-- gate each file on a trust prompt (vim.secure.read).
			local contents = vim.secure.read(file)
			if contents then
				local chunk = load(contents, "@" .. file)
				local ok, spec
				if chunk then
					ok, spec = pcall(chunk)
				end
				if ok and type(spec) == "table" then
					specs[#specs + 1] = spec -- lazy flattens nested spec lists
				else
					vim.notify("Failed to load plugin spec " .. file, vim.log.levels.WARN, { title = "nvim.config" })
				end
			end
		end
	end
end

require("lazy").setup(specs, {
	defaults = { lazy = true }, -- lazy-load by default
	ui = { border = "rounded" },
	change_detection = { notify = false },
	performance = {
		rtp = { disabled_plugins = { "gzip", "tarPlugin", "zipPlugin", "netrwPlugin" } },
	},
})
