local local_config = require("config.local_config")
local palette = require("config.palette")
local vscode = require("vscode")
local M = {}

local configured
local last_style

function M.repaint()
	local style = vim.o.background == "light" and "light" or "dark"
	if style ~= last_style or vim.g.colors_name ~= "vscode" then
		-- Light mode inherits the terminal's native white. Popup surfaces need
		-- their own override because vscode.nvim only clears the buffer fill.
		local transparent = style == "light" or configured.transparent
		vscode.setup({
			style = style,
			transparent = transparent,
			italic_comments = configured.italic_comments,
			color_overrides = transparent and { vscPopupBack = "NONE" } or nil,
		})
		vim.cmd.colorscheme("vscode")
		last_style = style
	end
	palette.apply()
	return true
end

local function color_component(component)
	if #component == 0 or #component > 4 then
		return nil
	end
	local value = tonumber(component, 16)
	return value and value / tonumber(string.rep("f", #component), 16) or nil
end

local function follow_background(event)
	local sequence = type(event.data) == "table" and event.data.sequence or event.data
	if type(sequence) ~= "string" then
		return
	end
	local r, g, b = sequence:match("^\27%]11;rgb:(%x+)/(%x+)/(%x+)$")
	if not r then
		r, g, b = sequence:match("^\27%]11;rgba:(%x+)/(%x+)/(%x+)/%x+$")
	end
	if not r then
		return
	end
	local red, green, blue = color_component(r), color_component(g), color_component(b)
	if not (red and green and blue) then
		return
	end
	local luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
	vim.o.background = luminance < 0.5 and "dark" or "light"
	M.repaint()
end

local function query_background()
	vim.api.nvim_ui_send("\27]11;?\7")
end

function M.setup()
	configured = local_config.get("theme", {
		background = "auto",
		transparent = false,
		italic_comments = true,
	})
	local automatic = configured.background == "auto"
	local group = vim.api.nvim_create_augroup("NvimConfigTheme", { clear = true })
	if not automatic then
		vim.o.background = configured.background
	end
	last_style = nil
	M.repaint()
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "background",
		callback = function()
			M.repaint()
		end,
	})
	if not automatic then
		return
	end

	vim.api.nvim_create_autocmd("TermResponse", {
		group = group,
		nested = true,
		callback = follow_background,
	})
	-- Lazy's install UI can consume Neovim's startup detection window.
	-- Re-query after startup and plugin operations to recover that response.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "VeryLazy",
		once = true,
		callback = function()
			vim.schedule(query_background)
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "LazyInstall", "LazyUpdate", "LazySync", "LazyCheck", "LazyDone" },
		callback = function()
			vim.schedule(query_background)
		end,
	})
end

return M
