vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)

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

local original_redraw = package.loaded["config.redraw_profile"]
local original_inline = package.loaded["config.inline_diagnostics"]
local original_config = vim.diagnostic.config
local original_get = vim.diagnostic.get
local original_handler = vim.diagnostic.handlers.virtual_lines
local original_schedule = vim.schedule

local effective_mode = "settled-line"
package.loaded["config.redraw_profile"] = {
	inline_diagnostics = function()
		return effective_mode
	end,
}
package.loaded["config.inline_diagnostics"] = nil

local configs = {}
local applied_config
local gets = {}
local shows = {}
local hides = {}
local scheduled = {}
local diagnostics = {}
local get_error

vim.diagnostic.config = function(opts)
	applied_config = vim.deepcopy(opts)
	configs[#configs + 1] = vim.deepcopy(opts)
	return opts
end
vim.diagnostic.get = function(buf, opts)
	gets[#gets + 1] = { buf = buf, opts = vim.deepcopy(opts) }
	if get_error then
		error(get_error)
	end
	return vim.deepcopy(diagnostics)
end
vim.diagnostic.handlers.virtual_lines = {
	show = function(namespace, buf, values, opts)
		shows[#shows + 1] = {
			namespace = namespace,
			buf = buf,
			diagnostics = vim.deepcopy(values),
			opts = vim.deepcopy(opts),
		}
	end,
	hide = function(namespace, buf)
		hides[#hides + 1] = { namespace = namespace, buf = buf }
	end,
}
vim.schedule = function(callback)
	scheduled[#scheduled + 1] = callback
end

local inline = require("config.inline_diagnostics")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "zero", "one", "two" })

local function reset_observations()
	configs = {}
	gets = {}
	shows = {}
	hides = {}
	scheduled = {}
	get_error = nil
end

local function setup(mode)
	effective_mode = mode
	inline.setup()
	reset_observations()
end

local function event(name, target)
	vim.api.nvim_exec_autocmds(name, { buffer = target or buf, modeline = false })
end

local function hold_at(row, column)
	vim.api.nvim_win_set_cursor(0, { row + 1, column or 0 })
	event("CursorHold")
end

test("native and disabled policies use only the global diagnostic handler", function()
	setup("current-line")
	assert(inline.status().mode == "current-line")
	assert(inline.toggle() == "off")
	assert(configs[#configs].virtual_lines == false)
	assert(inline.toggle() == "current-line")
	assert(vim.deep_equal(configs[#configs].virtual_lines, { current_line = true }))
	local mode, err = inline.set("automatic")
	assert(mode == nil and err:find("current%-line"), "invalid mode did not fail closed")

	setup("off")
	assert(inline.status().mode == "off")
	assert(inline.toggle() == "current-line", "disabled default did not restore a useful explicit presenter")
	assert(inline.toggle() == "off")
	event("CursorHold")
	assert(#gets == 0 and #shows == 0, "off mode performed settled diagnostic work")
end)

test("settled mode owns only non-insert idle and row-change events", function()
	setup("settled-line")
	local events = {}
	for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "NvimConfigInlineDiagnostics" })) do
		events[autocmd.event] = true
	end
	assert(events.CursorHold, "settled diagnostics do not observe CursorHold")
	assert(events.CursorMoved, "settled diagnostics do not observe row changes")
	assert(not events.CursorHoldI, "settled diagnostics repaint while inserting")
	assert(not events.CursorMovedI, "settled diagnostics repaint while moving in insert mode")
	assert(events.BufLeave and events.WinLeave and events.TabLeave and events.InsertEnter)
	assert(applied_config.virtual_lines == false, "settled mode enabled the native CursorMoved handler")
end)

test("settled mode renders one row per namespace and ignores horizontal movement", function()
	setup("settled-line")
	diagnostics = {
		{ namespace = 20, lnum = 1, col = 8, severity = vim.diagnostic.severity.WARN, message = "later" },
		{ namespace = 10, lnum = 1, col = 4, severity = vim.diagnostic.severity.WARN, message = "warning" },
		{ namespace = 10, lnum = 1, col = 2, severity = vim.diagnostic.severity.ERROR, message = "error" },
	}
	hold_at(1, 0)
	assert(#gets == 1 and gets[1].opts.lnum == 1, "settled render queried more than its selected row")
	assert(#shows == 2 and shows[1].namespace == 10 and shows[2].namespace == 20, "namespaces were not stable")
	assert(shows[1].diagnostics[1].severity == vim.diagnostic.severity.ERROR, "diagnostics were not severity sorted")
	assert(shows[1].opts.virtual_lines.current_line == false, "settled renderer installed CursorMoved ownership")

	local before = { gets = #gets, shows = #shows, hides = #hides }
	vim.api.nvim_win_set_cursor(0, { 2, 3 })
	event("CursorMoved")
	assert(#gets == before.gets and #shows == before.shows and #hides == before.hides, "column move repainted")

	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	event("CursorMoved")
	assert(#gets == before.gets and #shows == before.shows, "row move rendered before settling")
	assert(#hides == before.hides + 2, "row move did not clear every rendered namespace")
	hold_at(2, 0)
	assert(#gets == before.gets + 1 and #shows == before.shows + 2, "new row did not render after settling")
end)

test("settled marks clear on inactive views and entering insert mode", function()
	setup("settled-line")
	diagnostics = {
		{ namespace = 10, lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "error" },
	}
	for _, name in ipairs({ "BufLeave", "WinLeave", "TabLeave", "InsertEnter" }) do
		hold_at(0, 0)
		local before = #hides
		event(name)
		assert(#hides == before + 1, name .. " left settled diagnostic marks visible")
	end
	local before = #shows
	event("CursorHoldI")
	assert(#shows == before, "insert idle repainted settled diagnostics")
end)

test("diagnostic bursts coalesce and stale work cannot resurrect a presenter", function()
	setup("settled-line")
	diagnostics = {
		{ namespace = 10, lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "first" },
	}
	hold_at(0, 0)
	reset_observations()
	diagnostics[1].message = "changed"
	event("DiagnosticChanged")
	event("DiagnosticChanged")
	assert(#scheduled == 1 and inline.status().pending, "DiagnosticChanged burst was not coalesced")
	assert(#gets == 0 and #shows == 0, "diagnostics repainted before the scheduled boundary")
	scheduled[1]()
	assert(#gets == 1 and #shows == 1 and not inline.status().pending, "coalesced diagnostics did not repaint once")

	reset_observations()
	event("DiagnosticChanged")
	local stale = assert(scheduled[1])
	assert(inline.set("off") == "off")
	reset_observations()
	stale()
	assert(#gets == 0 and #shows == 0, "stale diagnostic work resurrected a disabled presenter")
end)

test("failed row reads retry and BufWipeout drops queued work", function()
	setup("settled-line")
	diagnostics = {
		{ namespace = 10, lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "error" },
	}
	get_error = "transient diagnostic read"
	hold_at(0, 0)
	assert(#gets == 1 and #shows == 0, "failed diagnostic read escaped or rendered")
	get_error = nil
	event("CursorHold")
	assert(#gets == 2 and #shows == 1, "failed diagnostic read was not retryable")

	reset_observations()
	event("DiagnosticChanged")
	local pending = assert(scheduled[1])
	event("BufWipeout")
	reset_observations()
	pending()
	assert(#gets == 0 and #shows == 0, "BufWipeout did not invalidate queued diagnostic work")
end)

local cleanup_ok, cleanup_err = pcall(inline.teardown)
vim.diagnostic.config = original_config
vim.diagnostic.get = original_get
vim.diagnostic.handlers.virtual_lines = original_handler
vim.schedule = original_schedule
package.loaded["config.inline_diagnostics"] = original_inline
package.loaded["config.redraw_profile"] = original_redraw

if not cleanup_ok then
	failures[#failures + 1] = "cleanup\n" .. tostring(cleanup_err)
end
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("inline_diagnostics_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
