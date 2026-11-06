vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local equal = require("tests.helpers").equal

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

local stubbed = { "config.tool_bootstrap", "config.treesitter_runtime" }
local originals = {}
for _, name in ipairs(stubbed) do
	originals[name] = package.loaded[name]
end
local original_auto_install = package.loaded["config.auto_install"]
local original_offline = vim.env.NVIM_CONFIG_OFFLINE
local original_list_uis = vim.api.nvim_list_uis
local original_executable = vim.fn.executable
local original_notify = vim.notify
local original_state_home = vim.env.XDG_STATE_HOME

local state_home = vim.fn.tempname()
assert(vim.fn.mkdir(state_home, "p", 448) == 1)

local calls
local notifications
local scenario

local function fresh_module()
	calls = { mise = 0, parsers = {} }
	notifications = {}
	package.loaded["config.tool_bootstrap"] = {
		install_mise = function(on_done)
			calls.mise = calls.mise + 1
			vim.schedule(function()
				on_done(scenario.mise_ok, scenario.mise_ok and "Installed Mise" or "network is down")
			end)
			return true
		end,
	}
	package.loaded["config.treesitter_runtime"] = {
		inventory = function()
			return {
				exact = #scenario.parsers == 0,
				required = vim.deepcopy(scenario.parsers),
				problems = {},
				extras = {},
			}
		end,
		install = function(names, opts)
			calls.parsers[#calls.parsers + 1] = { names = vim.deepcopy(names), force = opts.force }
			vim.schedule(function()
				opts.on_done(true)
			end)
			return true
		end,
	}
	package.loaded["config.auto_install"] = nil
	return require("config.auto_install")
end

local function interactive()
	vim.env.NVIM_CONFIG_OFFLINE = nil
	vim.env.XDG_STATE_HOME = state_home
	vim.api.nvim_list_uis = function()
		return { { chan = 1 } }
	end
	vim.notify = function(message, level)
		notifications[#notifications + 1] = { message = tostring(message), level = level }
	end
end

local function mise_present(present)
	vim.fn.executable = function(name)
		if name == "mise" then
			return present and 1 or 0
		end
		return original_executable(name)
	end
end

local function settle(auto_install, step)
	assert(
		vim.wait(2000, function()
			return auto_install.status().steps[step] ~= nil
		end, 10),
		step .. " never finished"
	)
end

T["full editor installs Mise and then builds missing or stale parsers"] = function()
	vim.fn.delete(state_home, "rf")
	scenario = {
		mise_ok = true,
		parsers = {
			{ name = "lua", expected = "1", actual = vim.NIL, exact = false },
			{ name = "c", expected = "2", actual = "1", exact = false },
			{ name = "rust", expected = vim.NIL, actual = vim.NIL, exact = false },
			{ name = "toml", expected = "3", actual = "3", exact = true },
		},
	}
	local auto_install = fresh_module()
	interactive()
	mise_present(false)
	auto_install.setup({ profile = "full" })
	assert(auto_install.run(), "interactive run did not start")
	settle(auto_install, "parsers")

	equal(1, calls.mise, "Mise was not installed exactly once")
	equal({ { names = { "lua", "c" }, force = true } }, calls.parsers, "wrong parsers were installed")
	local status = auto_install.status()
	assert(status.steps.mise.ok and status.steps.parsers.ok, vim.inspect(status))
	equal({}, status.failures, "successful steps left failures behind")
	assert(not auto_install.run(), "a second run in the same session started work")
end

T["failures are recorded, reported and not retried within a day"] = function()
	vim.fn.delete(state_home, "rf")
	scenario = { mise_ok = false, parsers = {} }
	local auto_install = fresh_module()
	interactive()
	mise_present(false)
	auto_install.setup({ profile = "full" })
	assert(auto_install.run())
	settle(auto_install, "parsers")
	local failure = auto_install.status().failures.mise
	assert(failure and failure.detail == "network is down", "Mise failure was not persisted")
	assert(
		vim.iter(notifications):any(function(item)
			return item.message:find("checkhealth nvimconfig", 1, true) ~= nil and item.level == vim.log.levels.WARN
		end),
		"failure did not point to :checkhealth"
	)

	auto_install = fresh_module()
	interactive()
	mise_present(false)
	auto_install.setup({ profile = "full" })
	assert(auto_install.run())
	settle(auto_install, "parsers")
	equal(0, calls.mise, "Mise was retried before the backoff expired")
	assert(auto_install.status().failures.mise, "backoff forgot the recorded failure")
end

T["pager skips Mise and offline or headless sessions download nothing"] = function()
	vim.fn.delete(state_home, "rf")
	scenario = { mise_ok = true, parsers = { { name = "markdown", expected = "1", actual = vim.NIL } } }
	local auto_install = fresh_module()
	interactive()
	mise_present(false)
	auto_install.setup({ profile = "pager" })
	assert(auto_install.run())
	settle(auto_install, "parsers")
	equal(0, calls.mise, "the pager installed Mise")
	equal(1, #calls.parsers, "the pager did not build its parsers")

	auto_install = fresh_module()
	interactive()
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	auto_install.setup({ profile = "full" })
	assert(not auto_install.run(), "offline session started work")
	equal("NVIM_CONFIG_OFFLINE=1", auto_install.status().skipped)

	auto_install = fresh_module()
	interactive()
	vim.api.nvim_list_uis = function()
		return {}
	end
	auto_install.setup({ profile = "full" })
	assert(not auto_install.run(), "headless session started work")
	equal("headless session", auto_install.status().skipped)
	equal(0, calls.mise + #calls.parsers, "a skipped session did work")
end

hooks.post_once = function()
	for _, name in ipairs(stubbed) do
		package.loaded[name] = originals[name]
	end
	package.loaded["config.auto_install"] = original_auto_install
	vim.env.NVIM_CONFIG_OFFLINE = original_offline
	vim.env.XDG_STATE_HOME = original_state_home
	vim.api.nvim_list_uis = original_list_uis
	vim.fn.executable = original_executable
	vim.notify = original_notify
	vim.fn.delete(state_home, "rf")
end

return T
