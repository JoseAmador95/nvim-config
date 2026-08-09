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
assert(dashboard_keys.s and dashboard_keys.s.action == ":AutoSession search", "dashboard restore is not explicit")
assert(dashboard_keys.p and dashboard_keys.p.action == ":MenuOpen", "dashboard palette action is missing")
local projects
for _, section in ipairs(snacks_opts.dashboard.sections) do
	if section.section == "projects" then
		projects = section
	end
end
assert(projects and projects.session == false, "dashboard projects still restore sessions implicitly")
assert(snacks_opts.scroll == nil, "smooth scrolling was enabled")
assert(snacks_opts.terminal.enabled == true, "Snacks terminal is disabled")
assert(snacks_opts.notifier.enabled == true, "Snacks notifier is disabled in the editor")
assert(snacks_opts.scratch.enabled == true, "Snacks scratch is disabled")

local context_spec
for _, entry in ipairs(require("plugins.treesitter")) do
	if entry[1] == "nvim-treesitter/nvim-treesitter-context" then
		context_spec = entry
	end
end
assert(context_spec and context_spec.opts.max_lines == 3, "Treesitter Context is not limited to three lines")
local navic_spec = require("plugins.navic")
assert(navic_spec.commit == "f5eba192f39b453675d115351808bd51276d9de5", "nvim-navic pin drifted")
local original_navic = package.loaded["nvim-navic"]
package.loaded["nvim-navic"] = {
	is_available = function()
		return true
	end,
	get_data = function()
		return { { icon = "C", name = "Outer" }, { icon = "F", name = "inner" } }
	end,
}
local statusline = require("config.statusline")
assert(statusline.navic() == "Finner", "statusline shows more than the innermost symbol")
package.loaded["nvim-navic"] = original_navic
statusline.update_root(0)
assert(vim.b.nvim_config_root == vim.uv.fs_realpath(repo), "statusline did not cache the filesystem project root")

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

print("ux_spec: sessions, dashboard, and semantic palette passed")
vim.cmd("quitall!")
