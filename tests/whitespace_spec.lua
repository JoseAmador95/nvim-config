vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local whitespace = require("config.whitespace")

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. tostring(err)
	end
end

local function buffer(lines, filetype)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = ""
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = filetype or "lua"
	return buf
end

test("cleanup removes only trailing ASCII spaces and tabs", function()
	whitespace.setup()
	local buf = buffer({ "space   ", "tab\t ", "kept\194\160" })
	local outcome = whitespace.trim(buf)
	equal(
		{ "space", "tab", "kept\194\160" },
		vim.api.nvim_buf_get_lines(buf, 0, -1, false),
		"cleanup changed content incorrectly"
	)
	assert(outcome.changed and not outcome.skipped and outcome.error == nil, "cleanup outcome was inaccurate")
	local unchanged = whitespace.trim(buf)
	assert(not unchanged.changed and not unchanged.skipped, "unchanged buffer was reported as skipped or changed")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("semantic, binary, hex, and opted-out buffers are skipped", function()
	whitespace.setup()
	local cases = {
		{ filetype = "markdown", reason = "semantic-whitespace" },
		{ filetype = "xxd", reason = "binary-or-hex" },
		{ filetype = "lua", binary = true, reason = "binary-or-hex" },
		{ filetype = "lua", hex = true, reason = "binary-or-hex" },
		{ filetype = "lua", opt_out = true, reason = "buffer-opt-out" },
	}
	for _, case in ipairs(cases) do
		local buf = buffer({ "value   " }, case.filetype)
		vim.bo[buf].binary = case.binary or false
		vim.b[buf].hex = case.hex or nil
		if case.opt_out then
			vim.b[buf].trim_trailing_whitespace = false
		end
		local outcome = whitespace.trim(buf)
		assert(outcome.skipped and outcome.reason == case.reason, "wrong skip outcome: " .. vim.inspect(outcome))
		equal({ "value   " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "skipped buffer was modified")
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end)

test("byte and line budgets reject work before mutation", function()
	whitespace.setup({ max_bytes = 5, max_lines = 2 })
	local bytes = buffer({ "abcdef   " })
	local byte_outcome = whitespace.trim(bytes)
	assert(byte_outcome.skipped and byte_outcome.reason == "byte-limit", "byte bound did not skip cleanup")
	local lines = buffer({ "a ", "b ", "c " })
	local line_outcome = whitespace.trim(lines)
	assert(line_outcome.skipped and line_outcome.reason == "line-limit", "line bound did not skip cleanup")
	equal({ "abcdef   " }, vim.api.nvim_buf_get_lines(bytes, 0, -1, false), "byte-limited buffer changed")
	equal({ "a ", "b ", "c " }, vim.api.nvim_buf_get_lines(lines, 0, -1, false), "line-limited buffer changed")
	vim.api.nvim_buf_delete(bytes, { force = true })
	vim.api.nvim_buf_delete(lines, { force = true })
end)

test("cleanup restores every visible view even when substitution fails", function()
	whitespace.setup()
	local buf = buffer({ "one   ", "two", "three" })
	vim.api.nvim_set_current_buf(buf)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(win, { 2, 2 })
	local before = vim.fn.winsaveview()
	local original_cmd = vim.cmd
	vim.cmd = function()
		error("simulated cleanup failure")
	end
	local outcome = whitespace.trim(buf)
	vim.cmd = original_cmd
	assert(outcome.error and outcome.reason == "cleanup-error", "cleanup error was not returned")
	equal(before, vim.fn.winsaveview(), "cleanup error changed the window view")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("setup rejects unknown and out-of-range policy", function()
	for _, options in ipairs({
		{ unknown = true },
		{ max_bytes = 0 },
		{ max_bytes = 64 * 1024 * 1024 + 1 },
		{ max_lines = 0 },
		{ max_lines = 1000001 },
		{ max_lines = 1.5 },
	}) do
		assert(not pcall(whitespace.setup, options), "invalid whitespace policy was accepted")
	end
	whitespace.setup({ max_bytes = 1, max_lines = 1 })
	equal({ max_bytes = 1, max_lines = 1 }, whitespace.status(), "inclusive lower bounds were rejected")
end)

pcall(vim.api.nvim_del_augroup_by_name, "trim_whitespace")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("whitespace_spec: %d tests passed"):format(count))
