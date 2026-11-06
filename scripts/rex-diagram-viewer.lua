-- Private, minimal Neovim profile launched by config.diagram_rex.
vim.o.loadplugins = false
vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.modeline = false
local path = assert(vim.env.NVIM_REX_PROFILE, "missing Rex diagram profile")
vim.env.NVIM_REX_PROFILE = nil
local stat = assert(vim.uv.fs_lstat(path))
assert(stat.type == "file" and stat.uid == vim.uv.getuid() and stat.mode % 512 == 384, "unsafe Rex diagram profile")
assert(stat.size < 65536, "oversized Rex diagram profile")
local profile = vim.json.decode(table.concat(vim.fn.readfile(path, "b"), "\n"))
vim.opt.runtimepath:prepend(profile.root)
for _, directory in ipairs(profile.runtime) do
	vim.opt.runtimepath:prepend(directory)
end
local local_plugins = require("config.local_plugins")
local_plugins.setup()
local viewer = require("config.diagram_rex_viewer")
viewer.setup(profile)
