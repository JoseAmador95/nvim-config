local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

local original_theme = package.loaded["config.theme"]
local original_config = package.loaded["config.local_config"]
local original_palette = package.loaded["config.palette"]
local original_vscode = package.loaded.vscode
local original_colorscheme = vim.cmd.colorscheme
local original_ui_send = vim.api.nvim_ui_send
local original_background = vim.o.background
local original_colors_name = vim.g.colors_name
local configured, calls, theme

local function response(sequence)
	vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = sequence } })
end

hooks.pre_case = function()
	configured = { background = "auto", transparent = false, italic_comments = true }
	calls = { paints = 0, palette = 0, queries = {} }
	package.loaded["config.local_config"] = {
		get = function(key, defaults)
			assert(key == "theme")
			return vim.tbl_extend("force", defaults, configured)
		end,
	}
	package.loaded["config.palette"] = {
		apply = function()
			calls.palette = calls.palette + 1
		end,
	}
	package.loaded.vscode = {
		setup = function(options)
			calls.options = options
		end,
	}
	vim.cmd.colorscheme = function(name)
		calls.paints = calls.paints + 1
		vim.g.colors_name = name
	end
	vim.api.nvim_ui_send = function(sequence)
		calls.queries[#calls.queries + 1] = sequence
	end
	vim.o.background = "dark"
	vim.g.colors_name = nil
	package.loaded["config.theme"] = nil
	theme = require("config.theme")
end

hooks.post_case = function()
	pcall(vim.api.nvim_del_augroup_by_name, "NvimConfigTheme")
	package.loaded["config.theme"] = original_theme
	package.loaded["config.local_config"] = original_config
	package.loaded["config.palette"] = original_palette
	package.loaded.vscode = original_vscode
	vim.cmd.colorscheme = original_colorscheme
	vim.api.nvim_ui_send = original_ui_send
	vim.o.background = original_background
	vim.g.colors_name = original_colors_name
end

T["fixed VSCode keeps host appearance preferences and reapplies the semantic palette"] = function()
	configured.transparent = true
	configured.italic_comments = false
	theme.setup()
	assert(vim.g.colors_name == "vscode")
	assert(calls.options.style == "dark" and calls.options.transparent == true)
	assert(calls.options.italic_comments == false)
	assert(calls.options.color_overrides.vscPopupBack == "NONE")
	assert(calls.palette == 1)
	theme.repaint()
	assert(calls.paints == 1, "unchanged style repainted the colorscheme")
	assert(calls.palette == 2, "explicit redraw did not restore the shared palette")
end

T["terminal responses follow light and dark backgrounds without changing theme"] = function()
	theme.setup()
	assert(calls.options.transparent == false and calls.options.italic_comments == true)
	assert(calls.options.color_overrides == nil)
	response("\27]11;rgb:ffff/ffff/ffff")
	assert(vim.o.background == "light" and vim.g.colors_name == "vscode")
	assert(calls.options.style == "light" and calls.options.transparent == true)
	assert(calls.options.color_overrides.vscPopupBack == "NONE")
	response("\27]11;rgba:0/00/000/ffff")
	assert(vim.o.background == "dark" and calls.options.style == "dark")
	assert(calls.options.transparent == false and calls.options.color_overrides == nil)
	response("\27]11;rgb:ff/ff/ff")
	assert(vim.o.background == "light" and calls.options.style == "light")
	local paints = calls.paints
	for _, sequence in ipairs({ "\27]10;rgb:0/0/0", "\27]11;rgb:00000/00000/00000", "malformed" }) do
		response(sequence)
	end
	assert(vim.o.background == "light" and calls.paints == paints, "invalid response repainted the theme")
end

T["pinned backgrounds paint immediately and ignore terminal detection"] = function()
	for _, background in ipairs({ "light", "dark" }) do
		configured.background = background
		theme.setup()
		assert(vim.o.background == background and calls.options.style == background)
		response(background == "light" and "\27]11;rgb:00/00/00" or "\27]11;rgb:ff/ff/ff")
		assert(vim.o.background == background and calls.options.style == background)
	end
end

T["automatic detection re-queries after startup and Lazy operations"] = function()
	theme.setup()
	vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
	vim.api.nvim_exec_autocmds("User", { pattern = "LazyDone" })
	assert(
		vim.wait(1000, function()
			return #calls.queries == 2
		end),
		"background detection was not requested"
	)
	assert(vim.deep_equal(calls.queries, { "\27]11;?\7", "\27]11;?\7" }))
end

return T
