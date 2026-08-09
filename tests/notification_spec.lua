vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local original_noice = package.loaded.noice
local original_snacks = package.loaded.snacks
local original_notify = vim.notify
local original_echo = vim.api.nvim_echo
local original_fast_event = vim.in_fast_event
local original_schedule = vim.schedule

local notify_calls = {}
local echo_calls = {}
local scheduled
local setup_opts
local noice = {
	setup = function(opts)
		setup_opts = opts
	end,
}
local snacks = {
	notifier = {
		notify = function(message, level, opts)
			notify_calls[#notify_calls + 1] = { message = message, level = level, opts = opts }
			return { id = #notify_calls }
		end,
	},
}

local ok, err = xpcall(function()
	package.loaded.noice = noice
	package.loaded.snacks = snacks
	vim.api.nvim_echo = function(chunks, history, opts)
		echo_calls[#echo_calls + 1] = { chunks = chunks, history = history, opts = opts }
	end
	vim.in_fast_event = function()
		return false
	end

	local spec = require("plugins.noice")
	spec.config(nil, spec.opts)
	assert(setup_opts == spec.opts, "Noice options were not configured")
	assert(spec.opts.notify.enabled == false, "Noice replaced the config-owned vim.notify")

	local dedicated_route
	for _, route in ipairs(spec.opts.routes) do
		if route.filter and route.filter.kind == "nvim_config_notify" then
			dedicated_route = route
		end
	end
	assert(dedicated_route and dedicated_route.opts.skip, "native notification echo is not deduplicated")

	local first = vim.notify("exact\ntext", vim.log.levels.WARN, { title = "Probe" })
	assert(vim.deep_equal({ id = 1 }, first), "Noice replace handle was not returned")
	assert(#echo_calls == 1 and #notify_calls == 1, "notification was not dispatched exactly once")
	assert(echo_calls[1].chunks[1][1] == "exact\ntext", "native history text was changed")
	assert(echo_calls[1].history == true, "notification was not added to native history")
	assert(echo_calls[1].opts.kind == "nvim_config_notify", "notification echo kind drifted")
	assert(not echo_calls[1].chunks[1][1]:find("[notify]", 1, true), "visible history prefix remains")
	assert(echo_calls[1].opts.err == false, "warning notification was recorded as an error")

	local table_message = { "first line", 42, "third line" }
	vim.notify(table_message, vim.log.levels.ERROR, { title = "Multiline" })
	assert(#echo_calls == 2 and #notify_calls == 2, "table notification was duplicated")
	assert(echo_calls[2].chunks[1][1] == "first line\n42\nthird line", "table history lost multiline text")
	assert(echo_calls[2].opts.err == true, "error notification lost nvim_echo error semantics")
	assert(notify_calls[2].message == "first line\n42\nthird line", "Snacks did not receive normalized text")

	local replace_opts = { replace = first }
	local second = vim.notify("replacement", vim.log.levels.INFO, replace_opts)
	assert(vim.deep_equal({ id = 3 }, second), "replacement handle was not returned")
	assert(notify_calls[3].opts == replace_opts, "replace semantics were not forwarded")

	notify_calls = {}
	echo_calls = {}
	vim.in_fast_event = function()
		return true
	end
	vim.schedule = function(callback)
		scheduled = callback
	end
	assert(vim.notify("fast", vim.log.levels.ERROR, { title = "Fast" }) == nil, "fast notify returned early handle")
	assert(#notify_calls == 0 and #echo_calls == 0 and scheduled, "fast notification was not deferred")
	scheduled()
	assert(#notify_calls == 1 and #echo_calls == 1, "deferred notification was duplicated")
	assert(echo_calls[1].chunks[1][1] == "fast", "deferred history text changed")
end, debug.traceback)

package.loaded.noice = original_noice
package.loaded.snacks = original_snacks
vim.notify = original_notify
vim.api.nvim_echo = original_echo
vim.in_fast_event = original_fast_event
vim.schedule = original_schedule

assert(ok, err)
print("notification_spec: notification ownership and deduplication passed")
vim.cmd("quitall!")
