local M = {}

local function highlight(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

local function channel(color, shift)
	return math.floor(color / (2 ^ shift)) % 256
end

local function rgb(red, green, blue)
	return (red * 65536) + (green * 256) + blue
end

local function blend(left, right, amount)
	local inverse = 1 - amount
	return rgb(
		math.floor((channel(left, 16) * inverse) + (channel(right, 16) * amount) + 0.5),
		math.floor((channel(left, 8) * inverse) + (channel(right, 8) * amount) + 0.5),
		math.floor((channel(left, 0) * inverse) + (channel(right, 0) * amount) + 0.5)
	)
end

local function value(group, attribute, fallback)
	return highlight(group)[attribute] or fallback
end

---@param color integer
---@return string
function M.hex(color)
	return string.format("#%06x", color)
end

---@param left integer
---@param right integer
---@param amount number
---@return integer
function M.blend(left, right, amount)
	return blend(left, right, amount)
end

---Return semantic colors derived from the active colorscheme.
---@return table
function M.current()
	local light = vim.o.background == "light"
	local fallback_bg = light and 0xffffff or 0x1e1e1e
	local fallback_fg = light and 0x1f2328 or 0xd4d4d4
	local normal = highlight("Normal")
	local bg = normal.bg or fallback_bg
	local fg = normal.fg or fallback_fg
	local accent = value("DiagnosticInfo", "fg", value("Function", "fg", light and 0x005fb8 or 0x4fc1ff))
	local visual = value("Visual", "bg", value("PmenuSel", "bg", blend(bg, accent, light and 0.18 or 0.28)))
	local selected_fg = value("PmenuSel", "fg", fg)

	return {
		background = bg,
		foreground = fg,
		transparent = normal.bg == nil,
		muted = value("Comment", "fg", blend(bg, fg, light and 0.45 or 0.55)),
		accent = accent,
		selected_bg = visual,
		selected_fg = selected_fg,
		indent = blend(bg, fg, light and 0.16 or 0.2),
		warning = value("DiagnosticWarn", "fg", value("Constant", "fg", fg)),
		rainbow = {
			value("DiagnosticWarn", "fg", fg),
			accent,
			value("Constant", "fg", fg),
			value("Statement", "fg", fg),
			value("Type", "fg", fg),
			value("Function", "fg", fg),
			value("String", "fg", fg),
		},
	}
end

local MARKDOWN_PRESETS = {
	minimal = true,
	semantic = true,
	subtle = true,
}

local function markdown_background(colors, target, amount)
	if colors.transparent then
		return {}
	end
	return { bg = blend(colors.background, target, amount) }
end

---Build render-markdown highlight groups from the active colorscheme.
---@param preset? "subtle"|"minimal"|"semantic"
---@return table<string, table>
function M.markdown_highlights(preset)
	preset = MARKDOWN_PRESETS[preset] and preset or "subtle"
	local colors = M.current()
	local light = vim.o.background == "light"
	local neutral_amount = light and 0.07 or 0.10
	local inline_amount = light and 0.08 or 0.12
	local groups = {
		RenderMarkdownBullet = { fg = colors.accent },
		RenderMarkdownCodeBorder = { link = "RenderMarkdownCode" },
		RenderMarkdownInlineHighlight = { link = "RenderMarkdownCodeInline" },
		RenderMarkdownLink = { fg = colors.accent },
		RenderMarkdownLinkTitle = { fg = colors.accent },
		RenderMarkdownQuote = { fg = colors.muted },
		RenderMarkdownTableHead = { fg = colors.foreground, bold = true },
		RenderMarkdownTableRow = { fg = colors.foreground },
	}
	for level = 1, 6 do
		groups["RenderMarkdownQuote" .. level] = { fg = colors.muted }
	end

	if preset == "minimal" then
		groups.RenderMarkdownCode = {}
		groups.RenderMarkdownCodeInline = {}
	else
		groups.RenderMarkdownCode = markdown_background(colors, colors.foreground, neutral_amount)
		groups.RenderMarkdownCodeInline = markdown_background(colors, colors.accent, inline_amount)
	end

	for level = 1, 6 do
		local foreground = "RenderMarkdownH" .. level
		local background = foreground .. "Bg"
		if preset == "semantic" then
			groups[foreground] = { fg = colors.rainbow[level] }
			groups[background] = markdown_background(colors, colors.rainbow[level], light and 0.10 or 0.14)
		else
			groups[foreground] = { link = "@markup.heading." .. level .. ".markdown" }
			if preset == "minimal" then
				groups[background] = {}
			elseif level == 1 then
				groups[background] = markdown_background(colors, colors.accent, light and 0.12 or 0.16)
			elseif level == 2 then
				groups[background] = markdown_background(colors, colors.accent, light and 0.09 or 0.12)
			else
				groups[background] = markdown_background(colors, colors.foreground, neutral_amount)
			end
		end
	end

	return groups
end

---Paint render-markdown's public highlight groups without assuming a theme.
---@param preset? "subtle"|"minimal"|"semantic"
function M.apply_markdown(preset)
	for name, attributes in pairs(M.markdown_highlights(preset)) do
		vim.api.nvim_set_hl(0, name, attributes)
	end
end

---Paint the shared indent and delimiter roles from one semantic palette.
function M.apply()
	local colors = M.current()
	vim.api.nvim_set_hl(0, "IblIndent", { fg = colors.indent, nocombine = true })
	local delimiter_groups = {
		"RainbowDelimiterYellow",
		"RainbowDelimiterBlue",
		"RainbowDelimiterOrange",
		"RainbowDelimiterViolet",
		"RainbowDelimiterCyan",
		"RainbowDelimiterRed",
		"RainbowDelimiterGreen",
	}
	for index, color in ipairs(colors.rainbow) do
		vim.api.nvim_set_hl(0, "IblRainbow" .. index, { fg = color, nocombine = true })
		vim.api.nvim_set_hl(0, delimiter_groups[index], { fg = color, nocombine = true })
	end
end

return M
