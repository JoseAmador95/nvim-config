local function set_spaces(width)
	vim.opt_local.expandtab = true
	vim.opt_local.tabstop = width
	vim.opt_local.shiftwidth = width
	vim.opt_local.softtabstop = width
end

local function set_tabs(width)
	local w = width or 4
	vim.opt_local.expandtab = false
	vim.opt_local.tabstop = w
	vim.opt_local.shiftwidth = w
	vim.opt_local.softtabstop = 0
end

local function on_filetype(pattern, callback)
	vim.api.nvim_create_autocmd("FileType", {
		pattern = pattern,
		callback = callback,
	})
end

on_filetype({
	"lua",
	"json",
	"jsonc",
	"yaml",
	"toml",
	"markdown",
	"sh",
	"bash",
	"zsh",
	"vim",
	"vimdoc",
	"javascript",
}, function()
	set_spaces(2)
end)

on_filetype({ "c", "cpp", "python", "cmake" }, function()
	set_spaces(4)
end)

on_filetype({ "make" }, function()
	set_tabs(4)
end)
