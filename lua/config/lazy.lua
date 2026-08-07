-- lua/config/lazy.lua
-- Bootstrap lazy.nvim and load plugin specs from lua/plugins/

local fn = vim.fn
local uv = vim.uv
local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"

local lazy_stat = uv.fs_stat(lazypath)
if not lazy_stat then
	local output = fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim",
		"--branch=stable",
		lazypath,
	})
	local exit_code = vim.v.shell_error
	lazy_stat = uv.fs_stat(lazypath)
	if exit_code ~= 0 or not lazy_stat then
		local detail = vim.trim(tostring(output or ""))
		if detail == "" then
			detail = "git produced no command output"
		end
		error(
			("Failed to bootstrap lazy.nvim at %s (git exit %d): %s\nCheck Git/network access, then retry."):format(
				lazypath,
				exit_code,
				detail
			)
		)
	end
end
if lazy_stat.type ~= "directory" then
	error("Cannot use lazy.nvim path " .. lazypath .. ": destination is not a directory")
end
vim.opt.rtp:prepend(lazypath)

local pager = require("config.pager")
local lazy_argv = require("config.lazy_argv")

-- In pager mode (nvimpager) load only the minimal allowlist; skip the full
-- `{ import = "plugins" }` set and any external ~/.nvim-local.lua plugin dirs.
local specs
if pager.active then
	specs = pager.specs()
else
	-- Native specs from lua/plugins, plus any external dirs from ~/.nvim-local.lua.
	specs = { { import = "plugins" } }
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
						vim.notify(
							"Failed to load plugin spec " .. file,
							vim.log.levels.WARN,
							{ title = "nvim.config" }
						)
					end
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

-- Neovim 0.12 can read argv buffers before lazy.nvim installs event handlers.
-- Recover only the missed Lazy/plugin groups; existing FileType observers are
-- deliberately not replayed.
lazy_argv.setup(pager)
