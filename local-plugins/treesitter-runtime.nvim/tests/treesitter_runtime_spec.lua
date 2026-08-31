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
	equal(1, #stops, "unsaved growth did not stop the owned parser")
	equal("LegacyIndent()", vim.bo[buf].indentexpr, "unsaved growth did not restore prior indentation")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tiny" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	equal(2, #starts, "unsaved shrink did not reattach")
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

test("pre-existing parser and indentation are never claimed or stopped", function()
	reset()
	installed = { "lua" }
	local target = "v:lua.require'nvim-treesitter'.indentexpr()"
	local buf = make_buffer("return true", "lua", target)
	active[buf] = true
	setup()
	equal({}, starts, "pre-existing parser was started again")
	assert(runtime.teardown(), "teardown failed")
	equal({}, stops, "pre-existing parser was stopped")
	equal(target, vim.bo[buf].indentexpr, "pre-existing indentation was erased")
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

reset()

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("treesitter_runtime_spec: %d tests passed", count))
vim.cmd("quitall!")
