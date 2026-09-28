local local_config = require("config.local_config")

local M = {}

local FULL = "full"
local LOW_BANDWIDTH = "low-bandwidth"
local CURRENT_LINE = "current-line"
local SETTLED_LINE = "settled-line"
local OFF = "off"
local GROUP = "NvimConfigRedrawProfileLifecycle"

local selected_configured
local selected_effective
local selected_inline_configured
local selected_inline_effective
local selected_remote
local selected_refresh_ms
local selected_noice_progress_throttle_ms
local selected_bufferline_diagnostics
local selected_bufferline_hover
local lifecycle = {
	configured = false,
	generation = 0,
	seen_ui = false,
	detached = false,
	pending = nil,
	last_error = nil,
}
local dependencies = {}
local repaint_hooks = {}

local function nonempty_env(name)
	local value = vim.env[name]
	return type(value) == "string" and value ~= ""
end

local function freeze()
	if selected_effective then
		return
	end
	local ui = local_config.get("ui", {})
	selected_configured = ui.redraw_profile or FULL
	selected_inline_configured = ui.inline_diagnostics
	selected_remote = nonempty_env("SSH_TTY") or nonempty_env("SSH_CONNECTION")
	if vim.g.vscode == true or vim.g.vscode == 1 or vim.env.NVIM_APPNAME == "nvimpager" then
		selected_effective = FULL
	else
		selected_effective = selected_configured
	end
	if vim.g.vscode == true or vim.g.vscode == 1 or vim.env.NVIM_APPNAME == "nvimpager" then
		selected_inline_effective = OFF
	elseif selected_inline_configured then
		selected_inline_effective = selected_inline_configured
	elseif selected_effective == LOW_BANDWIDTH then
		selected_inline_effective = OFF
	elseif selected_remote then
		-- SSH does not change the redraw profile. It only chooses the less chatty
		-- inline-diagnostic presenter inside the still-full profile.
		selected_inline_effective = SETTLED_LINE
	else
		selected_inline_effective = CURRENT_LINE
	end
	selected_refresh_ms = selected_effective == LOW_BANDWIDTH and 100
		or ui.full_refresh_ms
		or (selected_remote and 50 or 16)
	selected_noice_progress_throttle_ms = ui.noice_progress_throttle_ms
		or ((selected_effective == LOW_BANDWIDTH or selected_remote) and 100 or 1000 / 30)
	selected_bufferline_diagnostics = ui.bufferline_diagnostics
	if selected_bufferline_diagnostics == nil then
		selected_bufferline_diagnostics = selected_effective ~= LOW_BANDWIDTH and not selected_remote
	end
	selected_bufferline_hover = ui.bufferline_hover
	if selected_bufferline_hover == nil then
		selected_bufferline_hover = selected_effective ~= LOW_BANDWIDTH and not selected_remote
	end
end

function M.configured()
	freeze()
	return selected_configured
end

function M.current()
	freeze()
	return selected_effective
end

function M.low_bandwidth()
	return M.current() == LOW_BANDWIDTH
end

function M.inline_diagnostics_configured()
	freeze()
	return selected_inline_configured
end

function M.inline_diagnostics()
	freeze()
	return selected_inline_effective
end

function M.remote_transport()
	freeze()
	return selected_remote
end

function M.refresh_ms()
	freeze()
	return selected_refresh_ms
end

function M.noice_progress_throttle_ms()
	freeze()
	return selected_noice_progress_throttle_ms
end

function M.bufferline_diagnostics()
	freeze()
	return selected_bufferline_diagnostics
end

function M.bufferline_hover()
	freeze()
	return selected_bufferline_hover
end

local function ui_count()
	return dependencies.ui_count()
end

local function run_repaint_hooks(profile, failures)
	local names = vim.tbl_keys(repaint_hooks)
	table.sort(names)
	for _, name in ipairs(names) do
		local ok, result, err = pcall(repaint_hooks[name], profile)
		if not ok or result == false then
			failures[#failures + 1] = ("repaint hook %s failed: %s"):format(name, tostring(ok and err or result))
		end
	end
end

local function default_recover(profile)
	local failures = {}
	run_repaint_hooks(profile, failures)
	local event_ok, event_err = pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "NvimConfigUiReattached",
		modeline = false,
		data = { redraw_profile = profile },
	})
	if not event_ok then
		failures[#failures + 1] = "reattach event failed: " .. tostring(event_err)
	end
	-- A failing hook or subscriber must never prevent the terminal frame from
	-- being redrawn. Keep the lifecycle retryable if any part was incomplete.
	local redraw_ok, redraw_err = pcall(vim.cmd, "redraw!")
	if not redraw_ok then
		failures[#failures + 1] = "redraw failed: " .. tostring(redraw_err)
	end
	if #failures > 0 then
		return false, table.concat(failures, "; ")
	end
	return true
end

local function queue_recovery()
	if lifecycle.pending then
		return
	end
	local ticket = { generation = lifecycle.generation }
	lifecycle.pending = ticket
	dependencies.schedule(function()
		if lifecycle.pending ~= ticket then
			return
		end
		lifecycle.pending = nil
		if
			lifecycle.configured
			and lifecycle.generation == ticket.generation
			and lifecycle.detached
			and ui_count() > 0
		then
			local ok, recovered, recover_err = pcall(dependencies.recover, M.current())
			if ok and recovered ~= false then
				lifecycle.detached = false
				lifecycle.last_error = nil
			else
				lifecycle.last_error = tostring(ok and (recover_err or "recovery was rejected") or recovered)
			end
		end
	end)
end

local function on_ui_enter()
	if not lifecycle.configured or ui_count() == 0 then
		return
	end
	if not lifecycle.seen_ui then
		lifecycle.seen_ui = true
		lifecycle.detached = false
		return
	end
	if not lifecycle.detached then
		return
	end
	queue_recovery()
end

local function on_ui_leave()
	if not lifecycle.configured or ui_count() > 0 then
		return
	end
	lifecycle.generation = lifecycle.generation + 1
	lifecycle.detached = lifecycle.seen_ui
	lifecycle.pending = nil
	lifecycle.last_error = nil
end

function M.register_repaint(name, callback)
	assert(type(name) == "string" and name:match("^[%w_.-]+$"), "redraw repaint hook name is invalid")
	assert(type(callback) == "function", "redraw repaint hook must be a function")
	repaint_hooks[name] = callback
	return function()
		if repaint_hooks[name] == callback then
			repaint_hooks[name] = nil
		end
	end
end

function M.retry()
	if not lifecycle.configured or not lifecycle.detached or ui_count() == 0 then
		return false
	end
	queue_recovery()
	return true
end

function M.setup(opts)
	opts = opts or {}
	for key in pairs(opts) do
		if key ~= "recover" and key ~= "schedule" and key ~= "ui_count" then
			error("redraw profile setup contains unknown key: " .. tostring(key))
		end
	end
	for _, key in ipairs({ "recover", "schedule", "ui_count" }) do
		if opts[key] ~= nil and type(opts[key]) ~= "function" then
			error("redraw profile " .. key .. " must be a function")
		end
	end
	M.teardown()
	dependencies = {
		recover = opts.recover or default_recover,
		schedule = opts.schedule or vim.schedule,
		ui_count = opts.ui_count or function()
			return #vim.api.nvim_list_uis()
		end,
	}
	lifecycle.configured = true
	lifecycle.generation = lifecycle.generation + 1
	lifecycle.seen_ui = ui_count() > 0
	lifecycle.detached = false
	lifecycle.pending = nil
	lifecycle.last_error = nil
	local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
	vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = on_ui_enter })
	vim.api.nvim_create_autocmd("UILeave", { group = group, callback = on_ui_leave })
	return M
end

function M.teardown()
	lifecycle.generation = lifecycle.generation + 1
	lifecycle.configured = false
	lifecycle.detached = false
	lifecycle.pending = nil
	lifecycle.last_error = nil
	dependencies = {}
	pcall(vim.api.nvim_del_augroup_by_name, GROUP)
	return true
end

function M.status()
	return vim.deepcopy({
		configured = lifecycle.configured,
		generation = lifecycle.generation,
		seen_ui = lifecycle.seen_ui,
		detached = lifecycle.detached,
		pending = lifecycle.pending ~= nil,
		last_error = lifecycle.last_error,
		profile = M.current(),
		inline_diagnostics = M.inline_diagnostics(),
		remote_transport = M.remote_transport(),
		refresh_ms = M.refresh_ms(),
		noice_progress_throttle_ms = M.noice_progress_throttle_ms(),
		bufferline_diagnostics = M.bufferline_diagnostics(),
		bufferline_hover = M.bufferline_hover(),
	})
end

function M._reset_for_tests()
	M.teardown()
	selected_configured = nil
	selected_effective = nil
	selected_inline_configured = nil
	selected_inline_effective = nil
	selected_remote = nil
	selected_refresh_ms = nil
	selected_noice_progress_throttle_ms = nil
	selected_bufferline_diagnostics = nil
	selected_bufferline_hover = nil
	lifecycle.seen_ui = false
	repaint_hooks = {}
end

return M
