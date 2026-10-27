local store = require("config.usage_store")

local M = {}
local enabled, paused, database, timer, warning
local inventory = {}

local function notify_error(err)
	if err and err ~= warning then
		vim.notify("Usage: " .. tostring(err), vim.log.levels.WARN)
	end
	warning = err
end

local function record(origin, id, mode, amount)
	if database and (not paused or amount == 0) then
		database:record(origin, id, mode, amount)
	end
end

local function register(origin, id, mode)
	local key = table.concat({ origin, id, mode }, "\0")
	if not inventory[key] then
		inventory[key] = { origin, id, mode }
		record(origin, id, mode, 0)
	end
end

local function wrap(scope, mode, lhs, rhs, options)
	local opts = vim.deepcopy(options or {})
	local id = scope .. ":" .. lhs
	register("mapping", id, mode)
	if type(rhs) == "string" and not opts.expr then
		-- Expand <Leader> and special keys now, as keymap.set does for a string RHS.
		local keys = vim.api.nvim_replace_termcodes(rhs, true, true, true)
		rhs = function()
			return keys
		end
		opts.expr, opts.replace_keycodes = true, false
	end
	if type(rhs) ~= "function" then
		return rhs, opts
	end
	return function(...)
		record("mapping", id, mode)
		return rhs(...)
	end, opts
end

-- Explicit host-owned mappings only; no global monkey-patch or keystroke observer.
function M.mapper(scope, setter)
	return function(mode, lhs, rhs, opts)
		local set = setter or vim.keymap.set
		if not enabled then
			set(mode, lhs, rhs, opts)
			return rhs
		end
		local callback
		for _, m in ipairs(type(mode) == "table" and mode or { mode }) do
			local options
			callback, options = wrap(scope, m, lhs, rhs, opts)
			set(m, lhs, callback, options)
		end
		return callback
	end
end

-- Lazy owns loading and replay of the first keypress. Only the final RHS counts.
function M.spec(spec, scope)
	if not enabled or type(spec) ~= "table" then
		return spec
	end
	if type(spec.keys) == "table" then
		local keys = spec.keys
		spec.keys = function()
			local result = {}
			for _, key in ipairs(keys) do
				if type(key) == "table" and (type(key[2]) == "function" or type(key[2]) == "string") then
					for _, mode in ipairs(type(key.mode) == "table" and key.mode or { key.mode or "n" }) do
						local entry = vim.deepcopy(key)
						local callback
						callback, entry = wrap(scope, mode, key[1], key[2], entry)
						entry[2] = callback
						entry.mode = mode
						result[#result + 1] = entry
					end
				else
					result[#result + 1] = key
				end
			end
			return result
		end
	end
	for _, child in ipairs(spec) do
		M.spec(child, scope)
	end
	for _, child in ipairs(spec.dependencies or {}) do
		M.spec(child, scope)
	end
	for _, child in ipairs(spec.specs or {}) do
		M.spec(child, scope)
	end
	return spec
end

function M.palette_catalog(sections)
	if not enabled then
		return
	end
	for _, section in ipairs(sections) do
		for _, item in ipairs(section.items) do
			if not item.surfaces or item.surfaces.palette ~= false then
				register("palette", item.id, "-")
			end
		end
	end
end

function M.observe(event)
	if event.kind == "executed" and event.surface == "palette" then
		record("palette", event.id, "-")
	end
end

function M.flush(synchronous)
	if database then
		local ok, err = pcall(database.flush, database, synchronous)
		if ok then
			notify_error(database.error)
		else
			notify_error(err)
		end
	end
end

function M.pause(value)
	paused = value
end

function M.report(origin, days)
	if not database then
		return nil, "collection is inactive; use :UsageResume or enable telemetry in ~/.nvim-local.lua"
	end
	return database:report(origin or "all", days or 30)
end

local function show(args)
	local origin, days = args[1] or "all", tonumber(args[2] or "30")
	if not vim.tbl_contains({ "all", "mapping", "palette" }, origin) or not days or days < 0 or days % 1 ~= 0 then
		vim.notify("UsageStats [all|mapping|palette] [days; 0=all time]", vim.log.levels.WARN)
		return
	end
	local rows, err = M.report(origin, days)
	if not rows then
		notify_error(err)
		return
	end
	local lines = {
		("Usage — %s — %s"):format(
			paused and "paused" or "collecting",
			days == 0 and "all time" or days .. " days"
		),
		"Counts are invocations, including mapping replays/macros; not completion or success of background work.",
		"Coverage: registered host mappings/Lazy keys and palette actions. Zero = registered, never invoked in this period.",
		"Plugin option dictionaries (Oil, dashboard, pickers), unloaded buffer maps, built-in keys and typed Ex commands are excluded.",
		"Palette and mapping totals describe separate surfaces; do not add them as feature totals. q closes this tab.",
		"",
		"   Uses  Days  Last used (ever)  Profile  Origin   Mode  Action",
	}
	for _, row in ipairs(rows) do
		lines[#lines + 1] = ("%7d %5d  %-16s  %-8s %-8s %-5s %s"):format(
			row.uses,
			row.days,
			row.last_used and row.last_used > 0 and os.date("%Y-%m-%d %H:%M", row.last_used) or "never",
			row.profile,
			row.origin,
			row.mode,
			row.action
		)
	end
	vim.cmd.tabnew()
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.keymap.set("n", "q", "<Cmd>tabclose<CR>", { buffer = buf, silent = true })
end

-- path is supplied by isolated tests; normal profiles share the editor's state directory.
function M.setup(options, path)
	enabled = options.enabled ~= false
		and (
			path ~= nil
			or not (
				vim.env.CI
				or vim.env.NVIM_CONFIG_TEST
				or vim.env.NVIM_CONFIG_TEST_PROFILE
				or vim.env.NVIM_CONFIG_BOOTSTRAP
				or (vim.tbl_contains(vim.v.argv, "--headless") and not vim.g.vscode)
			)
		)
	paused = false
	local function start()
		if not enabled or database then
			return
		end
		local profile = vim.g.vscode and "vscode" or vim.env.NVIM_APPNAME == "nvimpager" and "pager" or "editor"
		path = path or vim.fs.joinpath(vim.fs.dirname(vim.fn.stdpath("state")), "nvim", "usage", "usage.sqlite3")
		local ok, value, err = pcall(store.open, path, profile)
		if not ok or not value then
			notify_error(ok and err or value)
			return
		end
		database = value
		for _, entry in pairs(inventory) do
			record(entry[1], entry[2], entry[3], 0)
		end
		timer = vim.uv.new_timer()
		timer:start(
			30000,
			30000,
			vim.schedule_wrap(function()
				M.flush(false)
			end)
		)
	end
	local group = vim.api.nvim_create_augroup("ConfigUsage", { clear = true })
	vim.api.nvim_create_autocmd("UIEnter", { group = group, callback = start })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
			M.flush(true)
		end,
	})
	vim.api.nvim_create_user_command("UsageStats", function(args)
		show(args.fargs)
	end, { nargs = "*", desc = "Local mapping and palette usage" })
	vim.api.nvim_create_user_command("UsagePause", function()
		M.pause(true)
		M.flush(false)
	end, { desc = "Pause usage collection in this editor" })
	vim.api.nvim_create_user_command("UsageResume", function()
		M.pause(false)
		start()
		if not enabled then
			vim.notify("Enable telemetry in ~/.nvim-local.lua and restart Neovim", vim.log.levels.INFO)
		end
	end, { desc = "Resume usage collection in this editor" })
	vim.api.nvim_create_user_command("UsageReset", function()
		vim.ui.select(
			{ "Cancel", "Reset" },
			{ prompt = "Delete usage counters for all editor profiles?" },
			function(choice)
				if choice == "Reset" and database then
					local _, err = database:reset()
					notify_error(err)
				end
			end
		)
	end, { desc = "Reset shared local usage statistics" })
	if path or vim.g.vscode or #vim.api.nvim_list_uis() > 0 then
		start()
	end
end

return M
