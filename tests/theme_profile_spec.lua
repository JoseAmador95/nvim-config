local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local background = assert(vim.env.NVIM_CONFIG_THEME_BACKGROUND, "theme background fixture is missing")
assert(background == "light" or background == "dark", "invalid theme background fixture")
vim.o.background = background

local function assert_appearance(expected)
	assert(vim.g.colors_name == "vscode", "active colorscheme changed")
	assert(vim.o.background == expected, "theme uses the wrong background")
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local popup = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
	local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
	assert(comment.italic == true, "italic comment preference was lost")
	if expected == "light" then
		assert(normal.bg == nil and popup.bg == nil, "light theme did not inherit the terminal background")
	else
		assert(normal.bg ~= nil and popup.bg ~= nil, "opaque dark theme lost its backgrounds")
	end
	local palette = require("config.palette").current()
	local indent = vim.api.nvim_get_hl(0, { name = "IblIndent", link = false })
	assert(indent.fg == palette.indent, "shared palette was not repainted")
	local code = vim.api.nvim_get_hl(0, { name = "MdRenderInlineCode", link = false })
	assert(code.fg ~= nil and code.bg ~= palette.background, "Markdown code lost its contrast")
end

local function assert_review_band_visible()
	local band = vim.api.nvim_get_hl(0, { name = "NvimReviewNativeHunkBand", link = false })
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local statusline = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
	assert(band.bg == statusline.bg, "native review band did not inherit the active StatusLine background")
	assert(band.bg ~= normal.bg, "native review band is indistinguishable from the editor background")
end

local function activate_review()
	local original_notify = vim.notify
	vim.notify = function() end
	local ok, err = pcall(vim.cmd, "ReviewClose")
	vim.notify = original_notify
	assert(ok, err)
	assert(package.loaded["config.native_review"] ~= nil, "Review action did not activate its host adapter")
	assert(package.loaded.native_review ~= nil, "Review action did not activate native-review")
end

T["fixed theme follows background changes in editor and pager"] = function()
	local pager = require("config.pager")
	assert(pager.active == (vim.env.NVIM_APPNAME == "nvimpager"), "wrong profile reached the fixture")
	assert_appearance(background)
	assert(vim.fn.exists(":Theme") == 0 and vim.fn.exists(":ThemeReset") == 0)
	if not pager.active then
		assert(package.loaded["config.native_review"] == nil, "theme activated review at startup")
		activate_review()
		assert_review_band_visible()
	end

	local other = background == "light" and "dark" or "light"
	vim.o.background = other
	assert_appearance(other)
	if not pager.active then
		assert_review_band_visible()
	end

	vim.o.background = background
	assert_appearance(background)
	vim.api.nvim_exec_autocmds("TermResponse", {
		data = { sequence = other == "light" and "\27]11;rgb:ffff/ffff/ffff" or "\27]11;rgb:00/00/00" },
	})
	assert_appearance(other)
	if not pager.active then
		assert_review_band_visible()
	end
end
return T
