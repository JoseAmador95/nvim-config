local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

local original_editor = package.loaded["config.editor"]
local original_dap_view = package.loaded["dap-view"]
local original_ui = package.loaded["config.dap_ui"]
local calls, dap, ui

hooks.pre_case = function()
	calls = { open = 0, close = {}, toggle = {}, hover = {}, setup = 0 }
	package.loaded["dap-view"] = {
		setup = function(options)
			calls.setup = calls.setup + 1
			calls.options = options
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
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path)
			calls.opened = path
		end,
	}
	package.loaded["config.dap_ui"] = nil
	ui = require("config.dap_ui")
	dap = {
		defaults = { fallback = {} },
		listeners = { after = { event_initialized = {} }, on_session = {} },
		session = function()
			return dap.current_session
		end,
	}
	ui.setup(dap)
end

hooks.post_once = function()
	package.loaded["config.editor"] = original_editor
	package.loaded["dap-view"] = original_dap_view
	package.loaded["config.dap_ui"] = original_ui
end

T["DAP controls preserve terminal closure, evaluation and tab-first navigation"] = function()
	ui.setup(dap)
	assert(calls.setup == 1, "DAP setup was duplicated")
	assert(calls.options.auto_toggle == false and calls.options.follow_tab == true)
	assert(dap.defaults.fallback.switchbuf == "usevisible,usetab,newtab")

	local buf = vim.api.nvim_create_buf(true, false)
	MiniTest.finally(function()
		vim.api.nvim_buf_delete(buf, { force = true })
	end)
	assert(calls.options.switchbuf(buf) == nil, "unnamed source opened a tab")
	assert(calls.opened == nil)
	vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".py")
	local win = calls.options.switchbuf(buf)
	assert(calls.opened == vim.api.nvim_buf_get_name(buf))
	assert(win == vim.api.nvim_get_current_win())

	dap.listeners.after.event_initialized.nvim_config_dap_ui()
	ui.close()
	ui.toggle()
	ui.eval()
	assert(calls.open == 1)
	assert(vim.deep_equal(calls.close, { true }))
	assert(vim.deep_equal(calls.toggle, { true }))
	assert(vim.deep_equal(calls.hover, { { enter = true, options = { context = "repl" } } }))
end

T["DAP closes only after the final session and checks for a scheduled replacement"] = function()
	local listener = dap.listeners.on_session.nvim_config_dap_ui
	local active, replacement = { id = 1 }, { id = 2 }
	dap.current_session = active
	listener(nil, active)
	dap.current_session = replacement
	listener(active, replacement)
	vim.wait(20)
	assert(#calls.close == 0, "UI closed while a debug session remained")

	dap.current_session = nil
	listener(replacement, nil)
	dap.current_session = active
	vim.wait(20)
	assert(#calls.close == 0, "scheduled close hid a newly started session")

	dap.current_session = nil
	listener(active, nil)
	assert(
		vim.wait(1000, function()
			return #calls.close == 1
		end),
		"UI did not close after the final debug session"
	)
	assert(calls.close[1] == true, "session cleanup left the debug terminal visible")
end

return T
