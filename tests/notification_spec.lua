vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local original_broker = package.loaded["config.notify_broker"]
local original_noice = package.loaded.noice
local original_snacks = package.loaded.snacks
local original_snacks_spec = package.loaded["plugins.snacks"]
local original_notify = vim.notify
local original_echo = vim.api.nvim_echo
local original_fast_event = vim.in_fast_event
local original_schedule = vim.schedule

local fallback_calls = {}
local function fallback(message, level, options)
	fallback_calls[#fallback_calls + 1] = { message = message, level = level, options = options }
	return { fallback = #fallback_calls }
end

local ok, err = xpcall(function()
	package.loaded["plugins.snacks"] = nil
	assert(require("plugins.snacks").opts.notifier.enabled == false, "Snacks still replaces broker-owned vim.notify")

	vim.notify = fallback
	package.loaded["config.notify_broker"] = nil
	local broker = require("config.notify_broker")
	assert(broker.setup())
	local dispatcher = vim.notify
	assert(dispatcher ~= fallback and broker.status().installed, "broker did not take stable ownership")
	assert(vim.deep_equal({ fallback = 1 }, vim.notify("native")), "empty broker did not preserve fallback")

	local first_calls = {}
	local first = assert(broker.acquire("first", function(message)
		first_calls[#first_calls + 1] = message
		return { first = #first_calls }
	end))
	local second_calls = {}
	local second = assert(broker.acquire("second", function(message)
		second_calls[#second_calls + 1] = message
		return { second = #second_calls }
	end))
	second.name = "mutated token"
	assert(broker.status().active == "second", "caller mutation changed broker-owned lease metadata")
	assert(vim.deep_equal({ second = 1 }, vim.notify("latest")), "newest lease did not own dispatch")
	assert(broker.release(first), "non-active lease could not be released")
	assert(vim.deep_equal({ second = 2 }, vim.notify("still latest")), "releasing an older lease changed ownership")
	assert(broker.release(second), "active lease was not released")
	assert(not broker.release(second), "stale lease release succeeded twice")
	assert(vim.deep_equal({ fallback = 2 }, vim.notify("released")), "release did not restore fallback dispatch")

	local failing = assert(broker.acquire("failing", function()
		error("provider failed")
	end))
	assert(vim.deep_equal({ fallback = 3 }, vim.notify("failure")), "provider failure did not fall back")
	assert(broker.release(failing))

	local scheduled
	local old_calls = 0
	local old = assert(broker.acquire("old", function()
		old_calls = old_calls + 1
	end))
	vim.in_fast_event = function()
		return true
	end
	vim.schedule = function(callback)
		scheduled = callback
	end
	assert(vim.notify("fast") == nil and scheduled, "fast notification was not deferred")
	local replacement_calls = 0
	local replacement = assert(broker.acquire("replacement", function()
		replacement_calls = replacement_calls + 1
	end))
	assert(broker.release(replacement))
	scheduled()
	assert(old_calls == 0 and replacement_calls == 0, "scheduled work crossed provider generations")
	assert(fallback_calls[#fallback_calls].message == "fast", "stale scheduled work did not use its fallback")
	assert(broker.release(old))

	local released_scheduled
	local released = assert(broker.acquire("released", function()
		error("released provider was called")
	end))
	vim.schedule = function(callback)
		released_scheduled = callback
	end
	assert(vim.notify("released fast") == nil and released_scheduled, "released fast notification was not deferred")
	assert(broker.release(released))
	local replacement_after_release = assert(broker.acquire("replacement after release", function()
		replacement_calls = replacement_calls + 1
	end))
	released_scheduled()
	assert(replacement_calls == 0, "released scheduled work reached a replacement provider")
	assert(fallback_calls[#fallback_calls].message == "released fast", "released scheduled work lost its fallback")
	vim.in_fast_event = function()
		return false
	end
	assert(broker.release(replacement_after_release))

	-- Reclaim a direct wrapper without recursion. Its retained dispatcher remains
	-- safe after teardown and delegates to the original fallback exactly once.
	local external_calls = 0
	local function external(message, level, options)
		external_calls = external_calls + 1
		return dispatcher(message, level, options)
	end
	vim.notify = external
	assert(broker.setup() and vim.notify == dispatcher, "broker did not chain a later wrapper")
	assert(vim.deep_equal({ fallback = 6 }, vim.notify("chained")), "chained fallback result changed")
	assert(external_calls == 1, "chained wrapper recursed")
	assert(broker.teardown() and vim.notify == external, "teardown clobbered or lost the chained wrapper")
	assert(vim.deep_equal({ fallback = 7 }, vim.notify("after teardown")), "retained dispatcher lost base fallback")
	assert(external_calls == 2, "retained wrapper recursed after teardown")

	vim.notify = fallback
	assert(broker.setup())

	local notify_calls = {}
	local echo_calls = {}
	local setup_opts
	package.loaded.noice = {
		setup = function(opts)
			setup_opts = opts
		end,
	}
	package.loaded.snacks = {
		notifier = {
			notify = function(message, level, options)
				notify_calls[#notify_calls + 1] = { message = message, level = level, options = options }
				return { id = #notify_calls }
			end,
		},
	}
	vim.api.nvim_echo = function(chunks, history, options)
		echo_calls[#echo_calls + 1] = { chunks = chunks, history = history, options = options }
	end

	package.loaded["plugins.noice"] = nil
	local spec = require("plugins.noice")
	spec.config(nil, spec.opts)
	assert(setup_opts == spec.opts, "Noice options were not configured")
	assert(spec.opts.notify.enabled == false, "Noice replaced the config-owned vim.notify")
	assert(broker.status().active == "noice" and broker.status().leases == 1, "Noice did not acquire one lease")

	local dedicated_route
	for _, route in ipairs(spec.opts.routes) do
		if route.filter and route.filter.kind == "nvim_config_notify" then
			dedicated_route = route
		end
	end
	assert(dedicated_route and dedicated_route.opts.skip, "native notification echo is not deduplicated")

	local first_handle = vim.notify("exact\ntext", vim.log.levels.WARN, { title = "Probe" })
	assert(vim.deep_equal({ id = 1 }, first_handle), "Noice replace handle was not returned")
	assert(#echo_calls == 1 and #notify_calls == 1, "notification was not dispatched exactly once")
	assert(echo_calls[1].chunks[1][1] == "exact\ntext", "native history text was changed")
	assert(echo_calls[1].history == true, "notification was not added to native history")
	assert(echo_calls[1].options.kind == "nvim_config_notify", "notification echo kind drifted")
	assert(echo_calls[1].options.err == false, "warning notification was recorded as an error")

	vim.notify({ "first line", 42, "third line" }, vim.log.levels.ERROR, { title = "Multiline" })
	assert(echo_calls[2].chunks[1][1] == "first line\n42\nthird line", "table history lost multiline text")
	assert(echo_calls[2].options.err == true, "error notification lost nvim_echo error semantics")
	assert(notify_calls[2].message == "first line\n42\nthird line", "Snacks did not receive normalized text")

	local replace_options = { replace = first_handle }
	local second_handle = vim.notify("replacement", vim.log.levels.INFO, replace_options)
	assert(vim.deep_equal({ id = 3 }, second_handle), "replacement handle was not returned")
	assert(notify_calls[3].options == replace_options, "replace semantics were not forwarded")

	local before_generation = broker.status().generation
	spec.config(nil, spec.opts)
	assert(broker.status().leases == 1, "repeated Noice config leaked a provider lease")
	assert(broker.status().generation > before_generation, "repeated Noice config did not replace its generation")
	spec.deactivate()
	assert(broker.status().active == nil and broker.status().leases == 0, "Noice deactivate retained its lease")
	assert(vim.deep_equal({ fallback = 8 }, vim.notify("native again")), "Noice deactivate lost native fallback")
	assert(not broker.release({ id = -1 }), "unknown provider token was released")
	broker.teardown()
end, debug.traceback)

package.loaded["plugins.noice"] = nil
package.loaded["plugins.snacks"] = original_snacks_spec
package.loaded["config.notify_broker"] = original_broker
package.loaded.noice = original_noice
package.loaded.snacks = original_snacks
vim.notify = original_notify
vim.api.nvim_echo = original_echo
vim.in_fast_event = original_fast_event
vim.schedule = original_schedule

assert(ok, err)
print("notification_spec: broker leases, fallback, generations, and Noice lifecycle passed")
vim.cmd("quitall!")
