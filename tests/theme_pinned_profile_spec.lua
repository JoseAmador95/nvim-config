vim.o.shadafile = "NONE"
vim.o.swapfile = false

local background = assert(vim.env.NVIM_CONFIG_THEME_BACKGROUND, "pinned theme background fixture is missing")
assert(background == "light" or background == "dark", "invalid pinned theme background fixture")
local opposite = background == "light" and "dark" or "light"
vim.o.background = opposite

local active_state = vim.fs.normalize(vim.fn.stdpath("state"))
local state_path = vim.fs.joinpath(vim.fs.dirname(active_state), "nvim", "theme.yaml")
assert(vim.fn.mkdir(vim.fs.dirname(state_path), "p", 448) == 1)
assert(vim.fn.writefile({ "version: 1", 'colorscheme: "catppuccin"' }, state_path) == 0)
assert(vim.uv.fs_chmod(state_path, 384))

local applied = 0
vim.api.nvim_create_autocmd("User", {
	pattern = "NvimThemeRouter",
	callback = function(event)
		if type(event.data) == "table" and event.data.kind == "applied" then
			applied = applied + 1
		end
	end,
})

local function fail(message)
	vim.api.nvim_err_writeln("theme_pinned_profile_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		local expected = "catppuccin-" .. (background == "light" and "latte" or "mocha")
		local ok, err = xpcall(function()
			assert(vim.o.background == background, "host background was not applied before VimEnter")
			assert(vim.g.colors_name == expected, "pinned background did not paint synchronously")
			assert(applied > 0, "startup emitted no applied theme event")
		end, debug.traceback)
		if not ok then
			fail(err)
			return
		end
		local startup_applied = applied
		vim.defer_fn(function()
			if applied ~= startup_applied then
				fail("pinned background produced a delayed duplicate repaint")
				return
			end
			if vim.fn.delete(state_path) ~= 0 then
				fail("could not remove the pinned theme fixture state")
				return
			end
			print("theme_pinned_profile_spec: " .. background .. " painted once before VimEnter")
			vim.cmd("quitall!")
		end, 250)
	end,
})
