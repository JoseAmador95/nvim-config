local dap_view = require("dap-view")
local editor = require("config.editor")
local M = {}

local LISTENER_ID = "nvim_config_dap_ui"
local initialized = false

local function dap_view_switchbuf(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	editor.open_file_in_tab(path)
	return vim.api.nvim_get_current_win()
end

function M.open()
	dap_view.open()
end

function M.close()
	dap_view.close(true)
end

function M.toggle()
	dap_view.toggle(true)
end

function M.eval()
	dap_view.hover(nil, true, { context = "repl" })
end

function M.setup(dap)
	if initialized then
		return
	end
	initialized = true

	dap_view.setup({
		auto_toggle = false,
		follow_tab = true,
		switchbuf = dap_view_switchbuf,
		winbar = {
			sections = { "watches", "scopes", "exceptions", "breakpoints", "threads", "repl", "console" },
		},
	})

	-- Keep source navigation out of debug panels and reuse existing tabs before
	-- creating a new one. dap-view additionally routes its own jumps through
	-- config.editor above.
	dap.defaults.fallback.switchbuf = "usevisible,usetab,newtab"
	dap.listeners.after.event_initialized[LISTENER_ID] = M.open
	dap.listeners.on_session[LISTENER_ID] = function(old_session, new_session)
		if old_session == nil or new_session ~= nil then
			return
		end
		vim.schedule(function()
			if dap.session() == nil then
				M.close()
			end
		end)
	end
end

return M
