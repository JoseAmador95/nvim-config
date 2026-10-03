vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/local-plugins/native-review.nvim")

local failures = {}
local count = 0
local requests = {}
local function adapter_run(request, callback)
	local pending = { request = request, callback = callback, cancelled = false }
	requests[#requests + 1] = pending
	return function()
		pending.cancelled = true
	end
end
local noop_adapter = setmetatable({}, {
	__index = function()
		return function() end
	end,
})
local dependencies = require("native_review.dependencies")
dependencies.setup({
	repo = noop_adapter,
	fs = noop_adapter,
	editor = noop_adapter,
	tabs = noop_adapter,
	lsp_navigation = {},
	config = {},
	structural_diff = { run = adapter_run },
})
local structural = require("native_review.structural")
local lsp = require("native_review.lsp")
local entry = {
	identity = "frozen",
	old_path = "demo.lua",
	new_path = "demo.lua",
	old_text = "local x = 30\n",
	new_text = "local x = 60\n",
	hunks = { { 1, 1, 1, 1 } },
}
local function flush()
	local done = false
	vim.schedule(function()
		done = true
	end)
	assert(vim.wait(200, function()
		return done
	end, 1))
end
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	structural.close()
	flush()
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

test("frozen requests are copies and the float has no source or LSP authority", function()
	local origin = vim.api.nvim_get_current_win()
	assert(structural.open(entry, function()
		return true
	end))
	local buf = vim.api.nvim_get_current_buf()
	local pending = requests[#requests]
	assert(pending.request.entry ~= entry and vim.deep_equal(pending.request.entry, entry))
	assert(pending.request.width == vim.api.nvim_win_get_width(0))
	assert(pending.request.background == vim.o.background)
	assert(lsp.blocked(buf) and vim.b[buf].nvim_review_role == "panel")
	assert(not vim.bo[buf].modifiable and not vim.bo[buf].buflisted)
	assert(vim.b[buf].nvim_review_source_map == nil)
	pending.request.entry.old_text = "changed copy"
	assert(entry.old_text == "local x = 30\n")
	pending.callback("\27[91mOLD 30\27[0m   \27[92mNEW 60\27[0m\n", nil)
	flush()
	assert(vim.bo[buf].buftype == "terminal" and not vim.bo[buf].modifiable)
	assert(vim.wait(200, function()
		return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "OLD 30   NEW 60"
	end, 1))
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		local map = vim.api.nvim_buf_call(buf, function()
			return vim.fn.maparg(lhs, "n", false, true)
		end)
		assert(map.buffer == 1 and map.callback == structural.close)
	end
	structural.close()
	assert(pending.cancelled and not vim.api.nvim_buf_is_valid(buf))
	assert(vim.api.nvim_get_current_win() == origin)
end)

test("terminal controls are stripped while ANSI colors remain displayable", function()
	assert(structural.open(entry, function()
		return true
	end))
	local buf = vim.api.nvim_get_current_buf()
	local clipboard_events = 0
	local group = vim.api.nvim_create_augroup("StructuralEscapeSpec", { clear = true })
	vim.api.nvim_create_autocmd("TermRequest", {
		group = group,
		callback = function()
			clipboard_events = clipboard_events + 1
		end,
	})
	requests[#requests].callback(
		"one\27[2Jtwo\27]52;c;aGVsbG8=\7\27]8;;https://example.invalid\27\\three\27]8;;\27\\\n",
		nil
	)
	flush()
	assert(vim.wait(200, function()
		return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "onetwothree"
	end, 1))
	assert(clipboard_events == 0)
	vim.api.nvim_del_augroup_by_id(group)
end)

test("superseded and manually closed requests cannot publish late output", function()
	assert(structural.open(entry, function()
		return true
	end))
	local old = requests[#requests]
	local old_buf = vim.api.nvim_get_current_buf()
	assert(structural.open(entry, function()
		return true
	end))
	local buf = vim.api.nvim_get_current_buf()
	assert(old.cancelled and not vim.api.nvim_buf_is_valid(old_buf))
	old.callback("late old output", nil)
	flush()
	assert(vim.api.nvim_get_current_buf() == buf and vim.bo[buf].buftype == "nofile")
	local pending = requests[#requests]
	structural.close()
	pending.callback("late closed output", nil)
	flush()
	assert(pending.cancelled and not vim.api.nvim_buf_is_valid(buf))
end)

test("owner invalidation suppresses successful output without modifying review data", function()
	local valid = true
	local before = vim.deepcopy(entry)
	assert(structural.open(entry, function()
		return valid
	end))
	local buf = vim.api.nvim_get_current_buf()
	valid = false
	requests[#requests].callback("stale output", nil)
	flush()
	assert(not vim.api.nvim_buf_is_valid(buf) and vim.deep_equal(entry, before))
end)

test("external window closure cancels the underlying render", function()
	assert(structural.open(entry, function()
		return true
	end))
	local pending = requests[#requests]
	vim.api.nvim_win_close(0, true)
	flush()
	assert(pending.cancelled)
end)

test("adapter failures notify and leave the source window intact", function()
	local notices = {}
	local notify = vim.notify
	vim.notify = function(value)
		notices[#notices + 1] = value
	end
	local origin = vim.api.nvim_get_current_win()
	assert(structural.open(entry, function()
		return true
	end))
	requests[#requests].callback(nil, "install difftastic explicitly")
	flush()
	vim.notify = notify
	assert(vim.api.nvim_get_current_win() == origin)
	assert(vim.deep_equal(notices, { "install difftastic explicitly" }))
end)

test("binary and metadata-only changes never invoke the adapter", function()
	local total = #requests
	for _, flag in ipairs({ "binary", "metadata_only" }) do
		local value = vim.deepcopy(entry)
		value[flag] = true
		local opened, err = structural.open(value, function()
			return true
		end)
		assert(not opened and err and #requests == total)
	end
end)

test("optional adapter validation leaves the previous adapter unchanged", function()
	local previous = dependencies.get("structural_diff").run
	local ok = pcall(dependencies.setup, {
		repo = noop_adapter,
		fs = noop_adapter,
		editor = noop_adapter,
		tabs = noop_adapter,
		lsp_navigation = {},
		config = {},
		structural_diff = { run = true },
	})
	assert(not ok and dependencies.get("structural_diff").run == previous)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("native_review_structural_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
