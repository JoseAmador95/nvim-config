vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local session = require("plugins.auto-session")
assert(session.opts.auto_save == true, "session auto-save is disabled")
assert(session.opts.auto_create == true, "session auto-create is disabled")
assert(session.opts.auto_restore == false, "sessions still auto-restore")
assert(session.opts.auto_restore_last_session == false, "last session still auto-restores")
assert(session.opts.auto_delete_empty_sessions == false, "empty home deletes saved sessions")

do
	local original_auto_session = package.loaded["auto-session"]
	local original_create_autocmd = vim.api.nvim_create_autocmd
	local original_notify = vim.notify
	local original_restore = vim.env.NVIM_TMUX_REFRESH_RESTORE
	local autocmd
	local setups = 0
	local restores = 0
	local notifications = {}
	local ok, err = xpcall(function()
		package.loaded["auto-session"] = {
			setup = function(options)
				setups = setups + 1
				assert(options.auto_restore == false, "one-shot restore enabled normal auto-restore")
			end,
			restore_session = function(name, options)
				restores = restores + 1
				assert(name == nil and options.show_message == false, "one-shot restore arguments changed")
				return false
			end,
		}
		vim.api.nvim_create_autocmd = function(event, options)
			autocmd = { event = event, options = options }
			return 1
		end
		vim.notify = function(message)
			notifications[#notifications + 1] = message
		end
		vim.env.NVIM_TMUX_REFRESH_RESTORE = "1"
		session.config(nil, session.opts)
		assert(setups == 1 and restores == 0, "session restored before VimEnter")
		assert(vim.env.NVIM_TMUX_REFRESH_RESTORE == nil, "one-shot restore environment was not consumed")
		assert(autocmd.event == "VimEnter" and autocmd.options.once == true, "one-shot restore autocmd is not once")
		autocmd.options.callback()
		assert(restores == 1, "one-shot restore did not run on VimEnter")
		assert(
			notifications[#notifications]:find("declined to restore", 1, true),
			"false one-shot restore result was hidden"
		)

		autocmd = nil
		session.config(nil, session.opts)
		assert(setups == 2 and autocmd == nil, "one-shot restore repeated without its environment flag")
	end, debug.traceback)

	package.loaded["auto-session"] = original_auto_session
	vim.api.nvim_create_autocmd = original_create_autocmd
	vim.notify = original_notify
	vim.env.NVIM_TMUX_REFRESH_RESTORE = original_restore
	assert(ok, err)
end

local expected_session_keys = {
	["<leader>Ss"] = true,
	["<leader>Sr"] = true,
	["<leader>Sp"] = true,
	["<leader>Sd"] = true,
}
for _, mapping in ipairs(session.keys) do
	expected_session_keys[mapping[1]] = nil
end
assert(vim.tbl_isempty(expected_session_keys), "session mapping family is incomplete")

local dashboard_keys = {}
local snacks_opts = require("plugins.snacks").opts
for _, item in ipairs(snacks_opts.dashboard.preset.keys) do
	dashboard_keys[item.key] = item
end
assert(
	dashboard_keys.n and dashboard_keys.n.desc == "New file" and type(dashboard_keys.n.action) == "function",
	"dashboard new-file action is missing"
)
assert(dashboard_keys.s and dashboard_keys.s.action == ":AutoSession search", "dashboard restore is not explicit")
assert(dashboard_keys.p and dashboard_keys.p.action == ":MenuOpen", "dashboard palette action is missing")
local expected_dashboard_icons = {
	n = " ",
	f = " ",
	g = " ",
	s = " ",
	p = "󰘳 ",
	c = " ",
	l = "󰊢 ",
	q = " ",
}
for key, icon in pairs(expected_dashboard_icons) do
	assert(dashboard_keys[key] and dashboard_keys[key].icon == icon, "dashboard icon is missing: " .. key)
end
local projects, recent
for _, section in ipairs(snacks_opts.dashboard.sections) do
	if section.section == "projects" then
		projects = section
	elseif section.section == "recent_files" then
		recent = section
	end
end
assert(projects and projects.session == false and projects.icon == " ", "dashboard projects are misconfigured")
assert(recent and recent.icon == " ", "dashboard recent-files icon is missing")
assert(snacks_opts.scroll == nil, "smooth scrolling was enabled")
assert(snacks_opts.terminal.enabled == true, "Snacks terminal is disabled")
assert(snacks_opts.notifier.enabled == false, "Snacks still replaces broker-owned vim.notify")
assert(snacks_opts.scratch.enabled == true, "Snacks scratch is disabled")

local context_spec
for _, entry in ipairs(require("plugins.treesitter")) do
	if entry[1] == "nvim-treesitter/nvim-treesitter-context" then
		context_spec = entry
	end
end
assert(context_spec and context_spec.opts.max_lines == 3, "Treesitter Context is not limited to three lines")
assert(context_spec.opts.enable == true, "Treesitter Context is disabled in the full profile")
local navic_spec = require("plugins.navic")
assert(navic_spec.commit == "f5eba192f39b453675d115351808bd51276d9de5", "nvim-navic pin drifted")
assert(navic_spec.opts.lazy_update_context == false, "navic full-profile refresh changed")
local original_navic = package.loaded["nvim-navic"]
local original_python = package.loaded["config.python"]
local original_cmake = package.loaded["config.cmake"]
local original_clangd = package.loaded["config.clangd"]
local original_review = package.loaded["config.code_review"]
local review_status = {
	active = true,
	mode_on = false,
	scope_kind = "range",
	scope_label = "base..head",
	layout = "split",
	context = "full",
	inline_comments = false,
	entry = { identity = "entry", path = "lua/example.lua", layer = "history", side = "OLD" },
}
package.loaded["nvim-navic"] = {
	is_available = function()
		return true
	end,
	get_data = function()
		return { { icon = "C", name = "Outer" }, { icon = "F", name = "inner" } }
	end,
}
package.loaded["config.python"] = {
	root = function()
		return repo
	end,
	venv_name = function()
		return ".venv"
	end,
}
package.loaded["config.cmake"] = { status = function() end }
package.loaded["config.clangd"] = {
	profile = function()
		return "full"
	end,
}
package.loaded["config.code_review"] = {
	status = function()
		return vim.deepcopy(review_status)
	end,
}
local statusline = require("config.statusline")
statusline.refresh_buffer(0)
assert(statusline.navic() == "Finner", "statusline shows more than the innermost symbol")
assert(vim.b.nvim_config_root == vim.uv.fs_realpath(repo), "statusline did not cache the filesystem project root")
assert(
	statusline.review()
		== "REV OFF · range:base..head · history · split/full · comments:off · OLD · lua/example.lua",
	"review statusline lost the native review state"
)
review_status.active = false
statusline.refresh_buffer(0)
assert(statusline.review() == "", "inactive review statusline stayed visible")

local original_lualine = package.loaded.lualine
local lualine_options
local lualine_refreshes = 0
package.loaded.lualine = {
	setup = function(options)
		lualine_options = options
	end,
	refresh = function(options)
		assert(vim.deep_equal(options, { place = { "statusline" } }))
		lualine_refreshes = lualine_refreshes + 1
	end,
}
require("plugins.lualine").config()
assert(lualine_options.sections.lualine_x[1] == statusline.review, "lualine omitted the review component")
assert(lualine_options.options.refresh.refresh_time == 16, "lualine full-profile refresh changed")
vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigReviewChanged", modeline = false })
assert(lualine_refreshes == 1, "review state changes did not refresh lualine")
package.loaded.lualine = original_lualine
package.loaded["nvim-navic"] = original_navic
package.loaded["config.python"] = original_python
package.loaded["config.cmake"] = original_cmake
package.loaded["config.clangd"] = original_clangd
package.loaded["config.code_review"] = original_review

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { bg = 0x101010, fg = 0xf0f0f0 })
vim.api.nvim_set_hl(0, "Visual", { bg = 0x223344 })
vim.api.nvim_set_hl(0, "PmenuSel", { fg = 0xfefefe })
vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x4488cc })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xddaa33 })
local palette = require("config.palette")
local colors = palette.current()
assert(colors.background == 0x101010 and colors.foreground == 0xf0f0f0, "palette ignored Normal")
assert(colors.selected_bg == 0x223344 and colors.selected_fg == 0xfefefe, "selected colors ignored theme")
assert(colors.accent == 0x4488cc, "semantic accent ignored diagnostics theme")
palette.apply()
assert(
	vim.api.nvim_get_hl(0, { name = "IblRainbow1", link = false }).fg
		== vim.api.nvim_get_hl(0, { name = "RainbowDelimiterYellow", link = false }).fg,
	"indent scope and delimiters do not share the semantic rainbow"
)

local function luminance(color)
	local function linear(channel)
		local value = channel / 255
		return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
	end
	return 0.2126 * linear(math.floor(color / 65536) % 256)
		+ 0.7152 * linear(math.floor(color / 256) % 256)
		+ 0.0722 * linear(color % 256)
end

local function contrast(foreground, background)
	local first, second = luminance(foreground), luminance(background)
	return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05)
end

vim.o.background = "light"
vim.api.nvim_set_hl(0, "Normal", { fg = 0x1f2328 })
vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0x1f2328 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x008000 })
vim.api.nvim_set_hl(0, "String", { fg = 0xa31515 })
palette.apply()
local light_code = vim.api.nvim_get_hl(0, { name = "MdRenderInlineCode", link = false })
assert(light_code.fg == 0xa31515, "light inline code lost the theme's String color")
assert(light_code.bg and contrast(light_code.fg, light_code.bg) >= 4.5, "light inline code has poor contrast")
local light_block = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlock", link = false })
local light_block_bg = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlockBackground", link = false }).bg
assert(light_block.fg == 0xa31515 and not light_block.bg, "light code text must retain foreground-only mapping")
assert(light_block_bg and luminance(light_block_bg) < luminance(0xffffff), "light code background is not shaded")
assert(contrast(light_block.fg, light_block_bg) >= 4.5, "light code block has poor contrast")
assert(
	vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlockLabel", link = false }).bg == light_block_bg,
	"code language label differs from code region"
)
vim.api.nvim_set_hl(0, "IblIndent", { fg = 0x123456 })
palette.apply_markdown()
assert(
	vim.api.nvim_get_hl(0, { name = "IblIndent", link = false }).fg == 0x123456,
	"Markdown-only palette update changed indent highlights"
)

vim.api.nvim_set_hl(0, "Normal", { fg = 0x4c4f69, bg = 0xeff1f5 })
vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0x4c4f69, bg = 0xeff1f5 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x9ca0b0 })
vim.api.nvim_set_hl(0, "String", { fg = 0x40a02b })
palette.apply()
local latte_code = vim.api.nvim_get_hl(0, { name = "MdRenderInlineCode", link = false })
assert(latte_code.fg == 0x4c4f69, "low-contrast String color was not replaced with Normal text")
assert(latte_code.bg and contrast(latte_code.fg, latte_code.bg) >= 4.5, "Latte inline code has poor contrast")
local latte_block = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlock", link = false })
local latte_block_bg = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlockBackground", link = false }).bg
assert(latte_block.fg == 0x4c4f69 and not latte_block.bg, "Latte code block did not replace low-contrast String")
assert(luminance(latte_block_bg) < luminance(0xeff1f5), "Latte code background is not shaded")
assert(contrast(latte_block.fg, latte_block_bg) >= 4.5, "Latte code block has poor contrast")

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "Normal", { fg = 0xd4d4d4 })
vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xd4d4d4 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x888888 })
vim.api.nvim_set_hl(0, "String", { fg = 0xce9178 })
palette.apply()
local dark_code = vim.api.nvim_get_hl(0, { name = "MdRenderInlineCode", link = false })
assert(dark_code.fg == 0xce9178, "dark inline code retained the light theme color")
assert(dark_code.bg and contrast(dark_code.fg, dark_code.bg) >= 4.5, "dark inline code has poor contrast")
assert(luminance(dark_code.bg) < luminance(light_code.bg), "inline code did not follow the background")
local dark_block = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlock", link = false })
local dark_block_bg = vim.api.nvim_get_hl(0, { name = "MdRenderCodeBlockBackground", link = false }).bg
assert(dark_block.fg == 0xce9178 and not dark_block.bg, "dark code block lost the theme's String color")
assert(contrast(dark_block.fg, dark_block_bg) >= 4.5, "dark code block has poor contrast")
assert(luminance(dark_block_bg) < luminance(light_block_bg), "code background did not follow the theme")

print("ux_spec: sessions, dashboard, and semantic palette passed")
vim.cmd("quitall!")
