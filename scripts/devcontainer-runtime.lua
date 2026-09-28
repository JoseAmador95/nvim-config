local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "could not resolve helper source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))

vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.env.NVIM_CONFIG_OFFLINE = "1"
vim.opt.runtimepath:prepend(config_root)
package.path = table.concat({ config_root .. "/lua/?.lua", config_root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local arguments = {}
for index = 1, #arg do
	arguments[index] = arg[index]
end

local output, err = require("config.devcontainer_runtime_cli").execute(arguments, require("config.devcontainer"))
if not output then
	local message = tostring(err or "Dev Container runtime preparation failed")
	message = message:gsub("[%c]+", " "):sub(1, 2048)
	io.stderr:write("devcontainer-runtime: ", message, "\n")
	io.stderr:flush()
	vim.cmd("cquit")
end
if output ~= "" then
	io.stdout:write(output)
	io.stdout:flush()
end
vim.cmd("quitall!")
