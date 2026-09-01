local M = {}

local DEFAULT_UI = "dap-ui"
local VALID_UI = {
	["dap-ui"] = true,
	["dap-view"] = true,
}
local LISTENER_ID = "nvim_config_dap_ui"

local selected_ui
local initialized = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "DAP UI" })
end

local function configured_ui()
	local configured = require("config.local_config").get("dap", {}).ui
	return VALID_UI[configured] and configured or DEFAULT_UI
end

function M.selected()
	if selected_ui then
		return selected_ui
	end

	selected_ui = configured_ui()
	local override = vim.env.NVIM_DAP_UI
	if override and override ~= "" then
		if VALID_UI[override] then
			selected_ui = override
		else
			notify("NVIM_DAP_UI must be dap-ui or dap-view; using " .. selected_ui)
		end
	end

	return selected_ui
end

local function implementation()
	if M.selected() == "dap-view" then
		return require("dap-view")
	end
	return require("dapui")
end

local function dap_view_switchbuf(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end
	require("config.editor").open_file_in_tab(path)
	return vim.api.nvim_get_current_win()
end

function M.open()
	implementation().open()
end

function M.close()
	if M.selected() == "dap-view" then
		implementation().close(true)
	else
		implementation().close()
	end
end

function M.toggle()
	if M.selected() == "dap-view" then
		implementation().toggle(true)
	else
		implementation().toggle()
	end
end

function M.eval()
	if M.selected() == "dap-view" then
		implementation().hover(nil, true, { context = "repl" })
	else
		implementation().eval()
	end
end

function M.setup(dap)
	if initialized then
		return
	end
	initialized = true

	if M.selected() == "dap-view" then
		implementation().setup({
			auto_toggle = false,
			follow_tab = true,
			switchbuf = dap_view_switchbuf,
			winbar = {
				sections = { "watches", "scopes", "exceptions", "breakpoints", "threads", "repl", "console" },
			},
		})
	else
		implementation().setup()
	end

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
