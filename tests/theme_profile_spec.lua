vim.o.shadafile = "NONE"
vim.o.swapfile = false

local background = assert(vim.env.NVIM_CONFIG_THEME_BACKGROUND, "theme background fixture is missing")
assert(background == "light" or background == "dark", "invalid theme background fixture")
vim.o.background = background

package.preload["localconfig.theme"] = function()
	return { colorscheme = "catppuccin" }
end

local function fail(message)
	vim.api.nvim_err_writeln("theme_profile_spec: " .. message)
	vim.cmd("cquit")
end

local function expected(flavour_background)
	return "catppuccin-" .. (flavour_background == "light" and "latte" or "mocha")
end

local function has_plugin(name)
	for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
		if vim.fn.fnamemodify(path, ":t") == name then
			return true
		end
	end
	return false
end

local function assert_review_band_visible()
	local band = vim.api.nvim_get_hl(0, { name = "NvimReviewNativeHunkBand", link = false })
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local statusline = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
	assert(band.bg == statusline.bg, "native review band did not inherit the active StatusLine background")
	assert(band.bg ~= normal.bg, "native review band is indistinguishable from the editor background")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				local pager = require("config.pager")
				local theme = require("config.theme")
				local lazy_plugin = nil
				for _, plugin in pairs(require("lazy").plugins()) do
					if plugin.name == "catppuccin" then
						lazy_plugin = plugin
						break
					end
				end

				assert(theme.selection().colorscheme == "catppuccin", "Catppuccin selection was not loaded")
				assert(vim.g.colors_name == expected(background), "wrong Catppuccin startup flavour")
				assert(has_plugin("catppuccin"), "Catppuccin is absent from the active profile")
				assert(has_plugin("vscode.nvim"), "VSCode fallback is absent from the active profile")
				assert(lazy_plugin and package.loaded.catppuccin, "Catppuccin was not loaded eagerly")
				assert(lazy_plugin.commit == "605b4603797de970e9f3a4238c199c850da03186", "Catppuccin commit drifted")
				assert(pager.active == (vim.env.NVIM_APPNAME == "nvimpager"), "wrong profile reached the fixture")

				local other = background == "light" and "dark" or "light"
				vim.o.background = other
				assert(vim.g.colors_name == expected(other), "background change did not switch Catppuccin flavour")

				vim.cmd("Theme vscode")
				assert(theme.selection().colorscheme == "vscode", ":Theme vscode did not update selection")
				assert(vim.g.colors_name == "vscode", ":Theme vscode did not repaint")
				if not pager.active then
					assert_review_band_visible()
				end

				vim.cmd("Theme catppuccin")
				assert(theme.selection().colorscheme == "catppuccin", ":Theme catppuccin did not persist selection")
				assert(vim.g.colors_name == expected(other), ":Theme catppuccin did not repaint")
				local state_path = vim.fs.joinpath(vim.fn.stdpath("config"), "lua", "localconfig", "theme.lua")
				local persisted = assert(loadfile(state_path))()
				assert(persisted.colorscheme == "catppuccin", "machine-local Catppuccin choice was not written")

				package.preload["localconfig.theme"] = nil
				package.loaded["localconfig.theme"] = nil
				vim.cmd("ThemeReset")
				assert(vim.fn.filereadable(state_path) == 0, ":ThemeReset left machine-local state behind")
				assert(theme.selection().colorscheme == "vscode", ":ThemeReset did not restore the versioned default")
				assert(vim.g.colors_name == "vscode", ":ThemeReset did not repaint VSCode")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end
			print(
				("theme_profile_spec: %s/%s selection and persistence passed"):format(
					vim.env.NVIM_APPNAME == "nvimpager" and "pager" or "editor",
					background
				)
			)
			vim.cmd("quitall!")
		end)
	end,
})
