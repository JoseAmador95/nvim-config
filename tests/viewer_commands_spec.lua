vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

package.loaded["config.pager"] = {
	active = false,
	strip_ansi = function()
		return true
	end,
}
local deferred_loads = {}
local log_watch_calls = {}
package.loaded["config.deferred"] = {
	try = function()
		return false
	end,
	load = function(name)
		deferred_loads[#deferred_loads + 1] = name
		if name == "config.log_watch" then
			return {
				command = function(opts)
					log_watch_calls[#log_watch_calls + 1] = opts.args
				end,
				complete = function()
					return { "on", "off", "pause", "resume" }
				end,
			}
		end
		return {}
	end,
}

local deferred_callbacks = {}
local queried
local notifications = {}
local original_defer_fn = vim.defer_fn
local original_get_clients = vim.lsp.get_clients
local original_notify = vim.notify
vim.defer_fn = function(callback, timeout)
	deferred_callbacks[#deferred_callbacks + 1] = { callback = callback, timeout = timeout }
end
vim.lsp.get_clients = function(filter)
	queried = filter
	return {}
end
vim.notify = function(message, level, options)
	notifications[#notifications + 1] = { message = message, level = level, options = options }
end

require("config.viewer_commands")

test("SetFileType fires FileType once and probes the original buffer", function()
	vim.cmd("enew!")
	local target = vim.api.nvim_get_current_buf()
	local filetype_events = 0
	local group = vim.api.nvim_create_augroup("ViewerCommandsSpec", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		buffer = target,
		callback = function()
			filetype_events = filetype_events + 1
		end,
	})

	vim.cmd("SetFileType lua")
	equal("lua", vim.bo[target].filetype, "filetype was not applied")
	equal(1, filetype_events, "SetFileType replayed FileType")
	equal("scratch-1.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target), ":t"), "scratch name was not assigned")
	equal(1, #deferred_callbacks, "LSP availability probe count")
	equal(200, deferred_callbacks[1].timeout, "LSP availability probe delay")

	local other = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(other)
	deferred_callbacks[1].callback()
	equal({ bufnr = target }, queried, "deferred LSP probe followed the current buffer")
	assert(
		notifications[#notifications]
			and notifications[#notifications].message == "No LSP client started for this buffer",
		"missing LSP warning was not emitted"
	)
	vim.api.nvim_del_augroup_by_id(group)
	vim.api.nvim_buf_delete(other, { force = true })
	vim.api.nvim_buf_delete(target, { force = true })
end)

test("LogWatchCurrentFile crosses only the audited deferred boundary", function()
	assert(package.loaded["config.log_watch"] == nil, "log watch adapter loaded during command registration")
	vim.cmd("LogWatchCurrentFile pause")
	equal({ "pause" }, log_watch_calls, "log command arguments changed")
	equal("config.log_watch", deferred_loads[#deferred_loads], "log command bypassed deferred loading")
	local completions = vim.fn.getcompletion("LogWatchCurrentFile ", "cmdline")
	equal({ "on", "off", "pause", "resume" }, completions, "log completion changed")
	equal("config.log_watch", deferred_loads[#deferred_loads], "log completion bypassed deferred loading")
end)

vim.defer_fn = original_defer_fn
vim.lsp.get_clients = original_get_clients
vim.notify = original_notify

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("viewer_commands_spec: %d tests passed", count))
vim.cmd("quitall!")
