vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/devcontainer-editor.nvim")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture .. "/.git", "p") == 1)
local root = assert(vim.uv.fs_realpath(fixture))
local original = {
	NVIM_DEVCONTAINER = vim.env.NVIM_DEVCONTAINER,
	NVIM_CONFIG_OFFLINE = vim.env.NVIM_CONFIG_OFFLINE,
	TMUX_PANE = vim.env.TMUX_PANE,
}
vim.env.NVIM_DEVCONTAINER = nil
vim.env.TMUX_PANE = "%7"

local old_repo = package.loaded["config.repo"]
package.loaded["config.repo"] = {
	current_root = function()
		return root
	end,
}

local devcontainer = require("config.devcontainer")

test("host adapter injects plugin callbacks and no config dependency crosses the boundary", function()
	local options = devcontainer._options()
	assert(type(options.state_root) == "function")
	assert(type(options.open) == "function")
	assert(type(options.notify) == "function")
	local plugin_source = table.concat(
		vim.fn.readfile(repo .. "/local-plugins/devcontainer-editor.nvim/lua/devcontainer_editor/init.lua"),
		"\n"
	)
	assert(not plugin_source:find('require%("config%.'))
	assert(not plugin_source:find("nvim_create_user_command", 1, true))
end)

test("editor replacement validates the exact pane before lifecycle start", function()
	local old_system = vim.system
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		return {
			wait = function()
				return { code = 0, stdout = "agent\t1\n", stderr = "" }
			end,
		}
	end
	local ok, err = devcontainer._replace_editor(false, false)
	assert(ok == nil and err:find("single%-pane editor window"))
	assert(#calls == 1 and calls[1][2] == "display-message")
	vim.system = old_system
end)

test("recreate and network authorization are explicit launcher argv", function()
	local old_system = vim.system
	local calls = {}
	vim.system = function(argv)
		calls[#calls + 1] = vim.deepcopy(argv)
		local stdout = argv[2] == "display-message" and "editor\t1\n" or ""
		return {
			wait = function()
				return { code = 0, stdout = stdout, stderr = "" }
			end,
		}
	end
	assert(devcontainer._replace_editor(true, true))
	assert(#calls == 3 and calls[2][2] == "set-option" and calls[3][2] == "respawn-pane")
	local command = calls[3][#calls[3]]
	assert(command:find("scripts/devcontainer%-editor"))
	assert(command:find("--recreate", 1, true) and command:find("--allow-network", 1, true))
	vim.system = old_system
end)

test("only final DevContainer commands are registered", function()
	devcontainer.setup()
	for _, name in ipairs({
		"DevContainerUp",
		"DevContainerRecreate",
		"DevContainerStatus",
		"DevContainerLog",
		"DevContainerHostEditor",
	}) do
		assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
	end
	assert(vim.fn.exists(":HostEditor") == 0, "legacy host command remains")
end)

test("network denial is exactly the verified-tools offline signal", function()
	local previous = vim.env.NVIM_CONFIG_OFFLINE
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	assert(not devcontainer.network_authorized())
	vim.env.NVIM_CONFIG_OFFLINE = "0"
	assert(devcontainer.network_authorized())
	vim.env.NVIM_CONFIG_OFFLINE = previous
end)

package.loaded["config.repo"] = old_repo
for name, value in pairs(original) do
	vim.env[name] = value
end
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("devcontainer_editor_host_spec: %d tests passed", count))
vim.cmd("quitall!")
