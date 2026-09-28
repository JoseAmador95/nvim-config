-- Standalone local-plugin contract tests.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/treesitter-runtime.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

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

local function wait_for(predicate, message)
	assert(vim.wait(1000, predicate, 5), message)
end

local runtime = require("treesitter_runtime")
local buffers = {}
local installed = {}
local active = {}
local starts = {}
local stops = {}
local probes = 0
local fail_start = false

local function reset()
	runtime.teardown()
	for _, buf in ipairs(buffers) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	buffers = {}
	installed = {}
	active = {}
	starts = {}
	stops = {}
	probes = 0
	fail_start = false
end

local function make_buffer(contents, filetype, indentexpr)
	local buf = vim.api.nvim_create_buf(false, true)
	buffers[#buffers + 1] = buf
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { contents })
	vim.bo[buf].filetype = filetype
	vim.bo[buf].indentexpr = indentexpr or ""
	return buf
end

local function setup(options)
	options = vim.tbl_deep_extend("force", {
		profile = "test",
		allowlist = { "lua" },
		max_bytes = 200 * 1024,
		highlight = true,
		indent = true,
		installed = function()
			probes = probes + 1
			return vim.deepcopy(installed)
		end,
		is_started = function(buf)
			return active[buf] == true
		end,
		start = function(buf, language)
			starts[#starts + 1] = { buf = buf, language = language }
			if fail_start then
				error("fixture start failure")
			end
			active[buf] = true
			return true
		end,
		stop = function(buf, language)
			stops[#stops + 1] = { buf = buf, language = language }
			active[buf] = nil
			return true
		end,
		language = function(buf)
			return vim.bo[buf].filetype
		end,
	}, options or {})
	return runtime.setup(options)
end

test("installed-only setup waits for explicit retry and never installs", function()
	reset()
	local commands_before = vim.api.nvim_get_commands({})
	local buf = make_buffer("return true", "lua")
	setup()
	equal({}, starts, "missing parser was started")
	assert(runtime.install == nil, "runtime unexpectedly exposes an installer")
	equal(commands_before, vim.api.nvim_get_commands({}), "runtime registered a global command")
	installed = { "lua" }
	assert(runtime.retry(buf), "explicit retry did not attach an installed parser")
	equal({ { buf = buf, language = "lua" } }, starts, "retry started the wrong parser")
	assert(probes == 2, "installed parser state was not refreshed only by setup and retry")
end)

test("current unsaved bytes stop on growth and reattach after shrink", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("small", "lua", "LegacyIndent()")
	setup({ max_bytes = 16 })
	equal(1, #starts, "small buffer did not attach")
	assert(vim.bo[buf].indentexpr:find("nvim%-treesitter"), "eligible buffer did not receive indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 32) })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	wait_for(function()
		return #stops == 1
	end, "unsaved growth debounce did not complete")
	equal(1, #stops, "unsaved growth did not stop the owned parser")
	equal("LegacyIndent()", vim.bo[buf].indentexpr, "unsaved growth did not restore prior indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tiny" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	wait_for(function()
		return #starts == 2
	end, "unsaved shrink debounce did not complete")
	equal(2, #starts, "unsaved shrink did not reattach")
end)

test("initial oversized buffers stop a highlighter started before setup", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer(string.rep("x", 32), "lua", "PriorIndent()")
	active[buf] = true
	setup({ max_bytes = 16 })
	equal({}, starts, "initial oversized buffer started another parser")
	equal({ { buf = buf, language = "lua" } }, stops, "pre-existing oversized highlighter remained active")
	equal("PriorIndent()", vim.bo[buf].indentexpr, "initial oversized buffer changed indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tiny" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	wait_for(function()
		return #starts == 1
	end, "initial oversized buffer did not attach after shrinking")
	equal({ { buf = buf, language = "lua" } }, starts, "shrink did not start policy-owned highlighting")
end)

test("allowlist and disabled profile teardown owned state", function()
	reset()
	installed = { "lua", "python" }
	local buf = make_buffer("return true", "lua", "OriginalIndent()")
	setup()
	setup({ profile = "other", allowlist = { "python" } })
	equal(1, #stops, "allowlist change did not stop the owned parser")
	equal("OriginalIndent()", vim.bo[buf].indentexpr, "allowlist change did not restore indentation")

	setup({ allowlist = { "lua" } })
	equal(2, #starts, "eligible re-entry did not restart the parser")
	vim.bo[buf].filetype = "python"
	vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
	equal(2, #stops, "ineligible filetype did not stop the parser")
	equal("OriginalIndent()", vim.bo[buf].indentexpr, "filetype change did not restore indentation")
	vim.bo[buf].filetype = "lua"
	vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
	equal(3, #starts, "eligible filetype re-entry did not restart the parser")
	setup({ enabled = false })
	equal(3, #stops, "disabled profile did not stop the parser")
end)

test("indent restoration is conditional on exact ownership", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua", "PriorIndent()")
	setup()
	vim.bo[buf].indentexpr = "ExternalIndent()"
	setup({ enabled = false })
	equal("ExternalIndent()", vim.bo[buf].indentexpr, "external indentation was overwritten during teardown")
end)

test("pre-existing parser is managed across ineligible and eligible transitions", function()
	reset()
	installed = { "lua" }
	local target = "v:lua.require'nvim-treesitter'.indentexpr()"
	local buf = make_buffer("small", "lua", "PriorIndent()")
	active[buf] = true
	setup({ max_bytes = 16 })
	equal({}, starts, "pre-existing parser was started again")
	equal(target, vim.bo[buf].indentexpr, "managed pre-existing parser did not receive indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 32) })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	wait_for(function()
		return #stops == 1
	end, "pre-existing parser stop debounce did not complete")
	equal({ { buf = buf, language = "lua" } }, stops, "ineligible pre-existing parser was not stopped")
	equal("PriorIndent()", vim.bo[buf].indentexpr, "ineligible transition did not restore prior indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tiny" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	wait_for(function()
		return #starts == 1
	end, "pre-existing parser restart debounce did not complete")
	equal({ { buf = buf, language = "lua" } }, starts, "eligible re-entry did not restart the parser")
	equal(target, vim.bo[buf].indentexpr, "eligible re-entry did not restore managed indentation")
end)

test("retry recovers an externally stopped parser without reclaiming external indentation", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua", "PriorIndent()")
	setup()
	equal(1, #starts, "initial parser was not started")

	active[buf] = nil
	assert(runtime.retry(buf), "retry did not recover an externally stopped parser")
	equal(2, #starts, "retry did not restart the externally stopped parser exactly once")
	equal({}, stops, "retry tried to stop a parser that was already inactive")
	assert(vim.bo[buf].indentexpr:find("nvim%-treesitter"), "retry did not restore managed indentation")

	vim.bo[buf].indentexpr = "ExternalIndent()"
	active[buf] = nil
	assert(runtime.retry(buf), "second retry did not recover the externally stopped parser")
	equal(3, #starts, "second retry did not restart the parser exactly once")
	equal("ExternalIndent()", vim.bo[buf].indentexpr, "retry reclaimed externally changed indentation")
end)

test("failed starts are retryable after the condition is repaired", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua")
	fail_start = true
	setup()
	equal(1, #starts, "initial start was not attempted")
	fail_start = false
	assert(runtime.retry(buf), "retry did not recover the start")
	equal(2, #starts, "retry did not make exactly one new attempt")
end)

test("setup is idempotent and full teardown supports re-entry", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua", "Before()")
	setup()
	local autocmd_count = #vim.api.nvim_get_autocmds({ group = "TreesitterRuntime" })
	setup()
	equal(1, #starts, "idempotent setup restarted an eligible parser")
	equal(0, #stops, "idempotent setup stopped an eligible parser")
	equal(autocmd_count, #vim.api.nvim_get_autocmds({ group = "TreesitterRuntime" }), "setup duplicated autocmds")

	assert(runtime.teardown(), "full teardown failed")
	equal(1, #stops, "full teardown did not stop the owned parser")
	equal("Before()", vim.bo[buf].indentexpr, "full teardown did not restore indentation")
	assert(not runtime.retry(buf), "retry attached after full teardown")
	setup()
	equal(2, #starts, "setup did not re-enter after teardown")
end)

test("highlight and indent options remain independent host choices", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua", "KeepIndent()")
	setup({ highlight = false, indent = true })
	equal({}, starts, "disabled highlighting started a parser")
	equal("KeepIndent()", vim.bo[buf].indentexpr, "indent changed without an attached parser")
	equal(
		{},
		vim.api.nvim_get_autocmds({ group = "TreesitterRuntime", event = "FileType" }),
		"disabled profile watches FileType"
	)
end)

test("debounce coalesces reevaluation and reports exact eligibility reasons", function()
	reset()
	installed = { "lua" }
	local deferred = {}
	local buf = make_buffer("tiny", "lua", "KeepIndent()")
	setup({
		max_bytes = 16,
		defer = function(callback, milliseconds)
			equal(50, milliseconds, "default reevaluation debounce changed")
			deferred[#deferred + 1] = callback
		end,
	})
	equal("attached", runtime.status(buf).reason, "eligible buffer status is incorrect")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 32) })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
	equal(2, #deferred, "text changes did not schedule reevaluation")
	deferred[1]()
	equal(0, #stops, "stale debounce callback evaluated the buffer")
	deferred[2]()
	equal(1, #stops, "latest debounce callback did not evaluate exactly once")
	local status = runtime.status(buf)
	equal("max-bytes-exceeded", status.reason, "size rejection reason is incorrect")
	equal(16, status.max_bytes, "status omitted the effective size limit")
	status.reason = "mutated"
	equal("max-bytes-exceeded", runtime.status(buf).reason, "status shares plugin state")
end)

test("policy is a copied live query independent of recorded lifecycle state", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("tiny", "lua", "KeepIndent()")
	setup({ max_bytes = 16, indent = false })
	local before_status = runtime.status(buf)
	local before_starts = #starts
	local before_stops = #stops
	local policy = runtime.policy(buf)
	assert(policy.eligible and policy.reason == "eligible", "eligible live policy is incorrect")
	equal("lua", policy.language, "live policy omitted its language")
	equal(16, policy.max_bytes, "live policy omitted its effective limit")
	equal(false, policy.indent, "live policy omitted its effective indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 32) })
	policy = runtime.policy(buf)
	assert(not policy.eligible and policy.reason == "max-bytes-exceeded", "policy reused stale recorded eligibility")
	assert(policy.bytes > policy.max_bytes, "live policy did not inspect current contents")
	equal(before_status, runtime.status(buf), "policy query changed recorded lifecycle state")
	equal(before_starts, #starts, "policy query started a parser")
	equal(before_stops, #stops, "policy query stopped a parser")

	policy.reason = "mutated"
	policy.max_bytes = 999
	local current = runtime.policy(buf)
	equal("max-bytes-exceeded", current.reason, "policy result shares runtime state")
	equal(16, current.max_bytes, "policy result shares nested configuration")
	vim.api.nvim_set_current_buf(buf)
	equal(current, runtime.policy(0), "buffer zero did not resolve the current buffer")
end)

test("partial language overrides inherit independent global policy fields", function()
	reset()
	installed = { "lua", "python" }
	local lua_buf = make_buffer("tiny", "lua", "LuaIndent()")
	local python_buf = make_buffer("tiny", "python", "PythonIndent()")
	setup({
		allowlist = { "lua", "python" },
		max_bytes = 16,
		indent = true,
		languages = {
			lua = { max_bytes = 32 },
			python = { indent = false },
		},
	})
	local lua_policy = runtime.policy(lua_buf)
	equal(32, lua_policy.max_bytes, "language maximum override was not selected")
	equal(true, lua_policy.indent, "absent language indentation did not inherit globally")
	local python_policy = runtime.policy(python_buf)
	equal(16, python_policy.max_bytes, "absent language maximum did not inherit globally")
	equal(false, python_policy.indent, "language indentation override was not selected")
end)

test("language overrides and setup contracts remain copied and transactional", function()
	reset()
	local initial = runtime.status()
	assert(initial.configured == false and vim.deep_equal(initial.buffers, {}), "pre-setup status is unavailable")
	equal(50, runtime.effective_config().reevaluate_debounce_ms, "pre-setup defaults are unavailable")
	installed = { "lua" }
	local buf = make_buffer("small", "lua", "KeepIndent()")
	setup({
		languages = { lua = { max_bytes = 8, indent = false } },
		on_state_change = function(event)
			event.reason = "mutated"
			error("observer failure")
		end,
	})
	equal("attached", runtime.status(buf).reason, "observer failure escaped setup evaluation")
	equal("KeepIndent()", vim.bo[buf].indentexpr, "language indent override was ignored")
	local effective = runtime.effective_config()
	equal(50, effective.reevaluate_debounce_ms, "effective debounce default is incorrect")
	effective.languages.lua.max_bytes = 999
	equal(8, runtime.effective_config().languages.lua.max_bytes, "effective config shares nested state")
	local before = runtime.status(buf)
	local ok, err = pcall(runtime.setup, {
		allowlist = { "lua" },
		installed = function()
			return { "lua" }
		end,
		injected = true,
	})
	assert(not ok and tostring(err):find("unknown option: injected", 1, true), "unknown setup option was accepted")
	equal(before, runtime.status(buf), "rejected setup mutated runtime status")
end)

test("installed discovery is strict and setup snapshots it before publication", function()
	reset()
	installed = { "lua" }
	local buf = make_buffer("return true", "lua", "Before()")
	setup()
	local before_config = runtime.effective_config()
	local before_status = runtime.status(buf)
	for _, callback in ipairs({
		function()
			error("fixture discovery failure")
		end,
		function()
			return "lua"
		end,
		function()
			return { 123 }
		end,
		function()
			return { lua = "yes" }
		end,
	}) do
		local ok = pcall(setup, { profile = "broken", installed = callback })
		assert(not ok, "malformed installed discovery was accepted")
		equal(before_config, runtime.effective_config(), "failed discovery published a new profile")
		equal(before_status, runtime.status(buf), "failed discovery mutated the active attachment")
	end
end)

test("failed parser stop rejects reconfiguration without publishing it", function()
	reset()
	installed = { "lua" }
	local fail_stop = false
	local buf = make_buffer("return true", "lua", "Before()")
	setup({
		profile = "active",
		stop = function(target, language)
			stops[#stops + 1] = { buf = target, language = language }
			if fail_stop then
				return false
			end
			active[target] = nil
			return true
		end,
	})
	fail_stop = true
	local ok, err = pcall(setup, { profile = "disabled", enabled = false })
	assert(not ok and tostring(err):find("could not stop parser", 1, true), tostring(err))
	equal("active", runtime.effective_config().profile, "failed stop published the candidate profile")
	assert(runtime.status(buf).attached, "failed stop discarded the prior attachment")
	assert(vim.bo[buf].indentexpr:find("nvim%-treesitter"), "failed stop restored owned indentation early")
	fail_stop = false
end)

reset()

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("treesitter_runtime_spec: %d tests passed", count))
vim.cmd("quitall!")
