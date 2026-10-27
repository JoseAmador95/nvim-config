local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local background = assert(vim.env.NVIM_CONFIG_THEME_BACKGROUND, "pinned theme background fixture is missing")
assert(background == "light" or background == "dark", "invalid pinned theme background fixture")
vim.o.background = background == "light" and "dark" or "light"

local applied = 0
vim.api.nvim_create_autocmd("ColorScheme", {
	pattern = "vscode",
	callback = function()
		applied = applied + 1
	end,
})

local startup
vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		startup = { background = vim.o.background, colors_name = vim.g.colors_name, applied = applied }
	end,
})
T["pinned theme paints once before VimEnter and ignores terminal detection"] = function()
	assert(startup.background == background, "host background was not applied before VimEnter")
	assert(startup.colors_name == "vscode", "pinned background did not paint synchronously")
	assert(startup.applied == 1, "startup did not apply VSCode exactly once")
	vim.api.nvim_exec_autocmds("TermResponse", {
		data = { sequence = background == "light" and "\27]11;rgb:00/00/00" or "\27]11;rgb:ffff/ffff/ffff" },
	})
	vim.wait(250, function()
		return applied ~= startup.applied
	end, 10)
	assert(vim.o.background == background, "terminal detection overrode the pinned background")
	assert(applied == startup.applied, "pinned background produced a delayed duplicate repaint")
end
return T
