-- Host adapter for theme-router.nvim. Theme definitions, palette repainting,
-- commands, and the interactive picker remain configuration-owned.

local router = require("theme_router")
local M = {}

local TITLE = "nvim.theme"
local FALLBACK = "habamax"
local REFRESH_COALESCE_MS = 100
local initialized = false
local refresh_group = "NvimConfigThemeReload"
local refresh_generation = 0
local refresh_pending
local refresh_scheduled = false
local defer = vim.defer_fn

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve theme adapter")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = TITLE })
end

-- stdpath("state") contains NVIM_APPNAME. Always point both the editor and
-- nvimpager at the physical nvim directory beside the active app directory.
function M.state_path()
	local active_state = vim.fs.normalize(vim.fn.stdpath("state"))
	return vim.fs.joinpath(vim.fs.dirname(active_state), "nvim", "theme.yaml")
end

local function legacy_path()
	return vim.fs.joinpath(config_root, "lua", "localconfig", "theme.lua")
end

local function default_colorscheme()
	local ok, value = pcall(require, "config.theme_default")
	if ok and type(value) == "table" and type(value.colorscheme) == "string" and value.colorscheme ~= "" then
		return value.colorscheme
	end
	notify("Versioned theme default is invalid; using " .. FALLBACK, vim.log.levels.WARN)
	return FALLBACK
end

local function policy()
	return require("config.local_config").plugin("theme_router", {
		background = "auto",
		transparent = false,
		italic_comments = true,
		reload_on_focus = true,
	})
end

local function emit(event)
	vim.api.nvim_exec_autocmds("User", {
		pattern = "NvimThemeRouter",
		modeline = false,
		data = vim.deepcopy(event),
	})
end

local function paint_default(name)
	local ok, err = pcall(vim.cmd.colorscheme, name)
	if not ok then
		return false, "Colorscheme '" .. name .. "' is not installed: " .. tostring(err)
	end
	local palette_ok, palette_result, palette_err = pcall(function()
		return require("config.palette").apply()
	end)
	if not palette_ok or palette_result == false then
		return false,
			"Palette repaint failed: " .. tostring(palette_ok and (palette_err or "rejected") or palette_result)
	end
	return true
end

local function ensure_setup()
	if initialized then
		return true
	end
	local called, selection, err = pcall(router.setup, {
		state_path = M.state_path(),
		legacy_path = legacy_path(),
		default = default_colorscheme(),
		fallback = FALLBACK,
		notify = notify,
		on_state_change = emit,
		paint = paint_default,
		context = function()
			return { background = vim.o.background }
		end,
	})
	if not called then
		err = selection
		selection = nil
	end
	if not selection then
		notify("Could not initialize theme routing: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	initialized = true
	return true
end

local function reset_refresh_coalescer()
	refresh_generation = refresh_generation + 1
	refresh_pending = nil
	refresh_scheduled = false
end

-- Explicit host operations supersede every queued refresh even when the core
-- rejects, returns false, or throws. Preserve the core's return contract while
-- making coalescer invalidation a finally-style guarantee.
local function invoke_router(method, ...)
	local callback = router[method]
	local returned
	if type(callback) ~= "function" then
		returned = { false, "unknown theme router method: " .. tostring(method) }
	else
		returned = { pcall(callback, ...) }
	end
	reset_refresh_coalescer()
	if not returned[1] then
		return false, tostring(returned[2])
	end
	return unpack(returned, 2)
end

local function queue_refresh(kind)
	if kind == "reload" or refresh_pending == nil then
		refresh_pending = kind
	end
	if refresh_scheduled then
		return
	end
	refresh_scheduled = true
	local generation = refresh_generation
	defer(function()
		if generation ~= refresh_generation then
			return
		end
		local pending = refresh_pending
		refresh_pending = nil
		local refreshed, refresh_err = invoke_router(pending)
		if not refreshed then
			notify("Theme refresh failed: " .. tostring(refresh_err), vim.log.levels.ERROR)
		end
	end, REFRESH_COALESCE_MS)
end

local function is_background_response(event)
	local data = event and event.data
	local sequence = type(data) == "table" and data.sequence or data
	return type(sequence) == "string"
		and (sequence:find("^\27%]11;rgb:") ~= nil or sequence:find("^\27%]11;rgba:") ~= nil)
end

---Register a host painter for a colorscheme with custom setup requirements.
---@param name string
---@param painter fun(background: string)
function M.register(name, painter)
	if not ensure_setup() then
		return false
	end
	local called, ok, err = pcall(router.register, name, function(_, context)
		local painter_called, painted, paint_err = pcall(painter, context.background)
		if not painter_called or painted == false then
			return false, tostring(painter_called and (paint_err or "rejected") or painted)
		end
		local palette_called, palette_result, palette_err = pcall(function()
			return require("config.palette").apply()
		end)
		if not palette_called or palette_result == false then
			return false, tostring(palette_called and (palette_err or "rejected") or palette_result)
		end
		return true
	end)
	if not called then
		err = ok
		ok = false
	end
	if not ok then
		notify("Could not register theme painter: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

function M.selection()
	if not ensure_setup() then
		return { colorscheme = FALLBACK, source = "fallback", validity = { valid = false } }
	end
	return router.selection()
end

function M.apply(name)
	if not ensure_setup() then
		return false
	end
	return invoke_router("apply", name)
end

function M.repaint()
	if not ensure_setup() then
		return false
	end
	-- An explicit repaint owns the current frame and supersedes any delayed
	-- OptionSet/OSC repaint already waiting in the coalescer.
	return invoke_router("repaint")
end

function M.save(name)
	if not ensure_setup() then
		return false, "theme router setup failed"
	end
	return invoke_router("persist", name)
end

function M.select(name)
	if not ensure_setup() then
		return false
	end
	local selected, err, durable = invoke_router("select", name)
	if not selected then
		return false, err, durable
	end
	notify("Theme set to " .. name, vim.log.levels.INFO)
	return true, err, durable
end

function M.reload()
	if not ensure_setup() then
		return false
	end
	return invoke_router("reload")
end

function M.status()
	return router.status()
end

function M.effective_config()
	return router.effective_config()
end

function M.reset()
	if not ensure_setup() then
		return false
	end
	local reset, err, durable = invoke_router("reset")
	if not reset then
		return false, err, durable
	end
	notify("Theme reset to " .. M.selection().colorscheme, vim.log.levels.INFO)
	return true, err, durable
end

-- Interactive UI remains a host concern. Snacks previews when available and
-- vim.ui.select preserves the command when the picker is not loaded.
function M.pick()
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks and snacks.picker then
		snacks.picker.colorschemes({
			confirm = function(picker, item)
				picker:close()
				if not item then
					return
				end
				picker.preview.state.colorscheme = nil
				vim.schedule(function()
					M.select(item.text)
				end)
			end,
		})
		return
	end
	vim.ui.select(vim.fn.getcompletion("", "color"), { prompt = "Colorscheme" }, function(choice)
		if choice then
			M.select(choice)
		end
	end)
end

function M.setup()
	ensure_setup()
	local configured = policy()
	reset_refresh_coalescer()
	local group = vim.api.nvim_create_augroup(refresh_group, { clear = true })
	if configured.reload_on_focus ~= false then
		vim.api.nvim_create_autocmd("FocusGained", {
			group = group,
			callback = function()
				queue_refresh("reload")
			end,
		})
	end
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "background",
		callback = function()
			queue_refresh("repaint")
		end,
	})
	vim.api.nvim_create_autocmd("TermResponse", {
		group = group,
		callback = function(event)
			if is_background_response(event) then
				queue_refresh("repaint")
			end
		end,
	})
	vim.api.nvim_create_user_command("Theme", function(opts)
		if opts.args ~= "" then
			M.select(opts.args)
			return
		end
		M.pick()
	end, {
		nargs = "?",
		complete = "color",
		desc = "Pick a colorscheme (or set one by name) and persist it",
	})

	vim.api.nvim_create_user_command("ThemeReset", function()
		M.reset()
	end, { desc = "Reset the shared theme selection to the versioned default" })
end

return M
