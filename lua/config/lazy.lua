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

local pager = require("config.pager")

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

-- lazy.nvim's `ft` handlers don't fire for files opened as command-line
-- arguments: their FileType event is emitted during startup, before lazy has
-- wired up the handlers, so `ft`-lazy plugins (render-markdown, obsidian, ...)
-- never load for `nvim some/file.md`. Re-emit FileType for every buffer that
-- is already loaded once VimEnter fires, which loads those plugins and lets
-- them attach to the argument buffers (also covers session-restored buffers).
vim.api.nvim_create_autocmd("VimEnter", {
	group = vim.api.nvim_create_augroup("lazy_ft_argv_fix", { clear = true }),
	callback = function()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) then
				-- Pager stdin has no filename, so nvimpager leaves the filetype
				-- empty; honor an explicit NVIMPAGER_FILETYPE before re-emitting
				-- so render-markdown (and friends) can attach.
				if pager.active then
					pager.apply_stdin_filetype(buf)
				end
				if vim.bo[buf].filetype ~= "" then
					vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
				end
			end
		end
	end,
})
