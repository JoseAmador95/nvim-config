vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
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

local original_env = vim.env.NVIM_DAP_UI
local original_notify = vim.notify
local original_local_config = package.loaded["config.local_config"]
local original_editor = package.loaded["config.editor"]
local original_dapui = package.loaded.dapui
local original_dap_view = package.loaded["dap-view"]

local function fresh(selected, override)
	package.loaded["config.dap_ui"] = nil
	package.loaded["config.local_config"] = {
		get = function(key)
			assert(key == "dap")
			return { ui = selected or "dap-ui" }
		end,
	}
	vim.env.NVIM_DAP_UI = override
	return require("config.dap_ui")
end

local function fake_dap()
	return {
		defaults = { fallback = {} },
		listeners = {
			after = { event_initialized = {} },
			before = { event_terminated = {}, event_exited = {} },
		},
	}
end

test("local config accepts the versioned DAP UI selection", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	local host = root .. "/host.lua"
	vim.fn.writefile({ "return { dap = { ui = 'dap-view' } }" }, host)

	local cwd = vim.fn.getcwd()
	local config_file = vim.env.NVIM_CONFIG_FILE
	vim.env.NVIM_CONFIG_FILE = host
	vim.cmd.cd(root)
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	assert(local_config.read().dap.ui == "dap-view")
	assert(#local_config.errors() == 0)

	vim.cmd.cd(cwd)
	vim.env.NVIM_CONFIG_FILE = config_file
	vim.fn.delete(root, "rf")
end)

test("selection defaults to dap-ui and a valid environment value wins", function()
	assert(fresh("dap-ui", nil).selected() == "dap-ui")
	assert(fresh("dap-ui", "dap-view").selected() == "dap-view")
	assert(fresh("dap-view", "dap-ui").selected() == "dap-ui")
end)

test("invalid environment override fails safely to local config", function()
	local notifications = {}
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	local ui = fresh("dap-view", "unknown")
	assert(ui.selected() == "dap-view")
	assert(#notifications == 1 and notifications[1]:find("must be dap-ui or dap-view", 1, true))
	vim.notify = original_notify
end)

test("dap-ui is the only implementation loaded and owns the shared lifecycle", function()
	local calls = { open = 0, close = 0, toggle = 0, eval = 0, setup = 0 }
	package.loaded.dapui = {
		setup = function()
			calls.setup = calls.setup + 1
		end,
		open = function()
			calls.open = calls.open + 1
		end,
		close = function()
			calls.close = calls.close + 1
		end,
		toggle = function()
			calls.toggle = calls.toggle + 1
		end,
		eval = function()
			calls.eval = calls.eval + 1
		end,
	}
	package.loaded["dap-view"] = nil
	local ui = fresh("dap-ui", nil)
	local dap = fake_dap()
	ui.setup(dap)
	assert(calls.setup == 1)
	assert(package.loaded["dap-view"] == nil, "dap-view loaded for dap-ui selection")
	assert(dap.defaults.fallback.switchbuf == "usevisible,usetab,newtab")

	dap.listeners.after.event_initialized.nvim_config_dap_ui()
	dap.listeners.before.event_terminated.nvim_config_dap_ui()
	dap.listeners.before.event_exited.nvim_config_dap_ui()
	ui.toggle()
	ui.eval()
	assert(vim.deep_equal(calls, { open = 1, close = 2, toggle = 1, eval = 1, setup = 1 }))
end)

test("dap-view is exclusive, closes its terminal and routes jumps through editor tabs", function()
	local calls = { open = 0, close = {}, toggle = {}, hover = {}, setup = nil }
	package.loaded.dapui = nil
	package.loaded["dap-view"] = {
		setup = function(options)
			calls.setup = options
		end,
		open = function()
			calls.open = calls.open + 1
		end,
		close = function(hide_terminal)
			calls.close[#calls.close + 1] = hide_terminal
		end,
		toggle = function(hide_terminal)
			calls.toggle[#calls.toggle + 1] = hide_terminal
		end,
		hover = function(expr, enter, options)
			calls.hover[#calls.hover + 1] = { expr = expr, enter = enter, options = options }
		end,
	}

	local opened
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path)
			opened = path
		end,
	}
	local ui = fresh("dap-view", nil)
	local dap = fake_dap()
	ui.setup(dap)
	assert(type(calls.setup) == "table" and calls.setup.auto_toggle == false and calls.setup.follow_tab == true)
	assert(package.loaded.dapui == nil, "dap-ui loaded for dap-view selection")

	local buf = vim.api.nvim_create_buf(true, false)
	local path = vim.fn.tempname() .. ".py"
	vim.api.nvim_buf_set_name(buf, path)
	local buffer_path = vim.api.nvim_buf_get_name(buf)
	local win = calls.setup.switchbuf(buf)
	assert(opened == buffer_path)
	assert(win == vim.api.nvim_get_current_win())

	dap.listeners.after.event_initialized.nvim_config_dap_ui()
	dap.listeners.before.event_terminated.nvim_config_dap_ui()
	dap.listeners.before.event_exited.nvim_config_dap_ui()
	ui.toggle()
	ui.eval()
	assert(calls.open == 1)
	assert(vim.deep_equal(calls.close, { true, true }))
	assert(vim.deep_equal(calls.toggle, { true }))
	assert(calls.hover[1].enter == true and calls.hover[1].options.context == "repl")
end)

test("plugin spec pins dap-view 1.2.0 and makes both UIs conditional", function()
	local specs = require("plugins.dap")
	local plugins = {}
	for _, spec in ipairs(specs) do
		plugins[spec[1]] = spec
	end
	assert(type(plugins["rcarriga/nvim-dap-ui"].cond) == "function")
	assert(plugins["rcarriga/nvim-dap-ui"].lazy == true)
	assert(plugins["igorlfs/nvim-dap-view"].commit == "ba5c838e731003abefb8bc1c403c59aa5b3aa194")
	assert(type(plugins["igorlfs/nvim-dap-view"].cond) == "function")
	assert(plugins["igorlfs/nvim-dap-view"].lazy == true)
end)

vim.env.NVIM_DAP_UI = original_env
vim.notify = original_notify
package.loaded["config.local_config"] = original_local_config
package.loaded["config.editor"] = original_editor
package.loaded.dapui = original_dapui
package.loaded["dap-view"] = original_dap_view
package.loaded["config.dap_ui"] = nil

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("dap_ui_spec: %d tests passed", count))
vim.cmd("quitall!")
