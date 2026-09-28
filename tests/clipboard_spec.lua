vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

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

local original_ssh_tty = vim.env.SSH_TTY
local original_ssh_connection = vim.env.SSH_CONNECTION
local original_provider = vim.g.clipboard
local original_clipboard_option = vim.o.clipboard
local clipboard = require("config.clipboard")

local function local_session()
	vim.env.SSH_TTY = nil
	vim.env.SSH_CONNECTION = nil
	clipboard.teardown()
	vim.g.clipboard = original_provider
	vim.o.clipboard = ""
end

local function edit_lines(lines)
	vim.cmd.enew({ bang = true })
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function normal(keys)
	vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes(keys, true, false, true) }, bang = true })
end

local function native_clipboard()
	local_session()
	local calls = {}
	local contents = {}
	local provider = { name = "clipboard-spec", copy = {}, paste = {}, cache_enabled = 0 }
	for _, register in ipairs({ "+", "*" }) do
		provider.copy[register] = function(lines, kind)
			contents[register] = { vim.deepcopy(lines), kind }
			calls[#calls + 1] = { register, vim.deepcopy(lines), kind }
		end
		provider.paste[register] = function()
			return contents[register] or { {}, "v" }
		end
	end
	vim.g.clipboard = provider
	clipboard.setup()
	assert(vim.fn["provider#clipboard#Executable"]() == "clipboard-spec")
	return calls
end

test("copy refuses use before setup", function()
	local_session()
	local ok, err = clipboard.copy_text("value")
	assert(not ok and err:find("not configured", 1, true), "unconfigured copy was accepted")
	assert(not clipboard.available(), "unconfigured adapter reported availability")
end)

test("empty SSH variables keep the native provider and exact native payload", function()
	local_session()
	vim.env.SSH_TTY = ""
	vim.env.SSH_CONNECTION = ""
	local sentinel = { name = "native-sentinel" }
	vim.g.clipboard = sentinel
	local calls = {}
	clipboard.setup({}, {
		has_ui = function()
			return false
		end,
		native_setreg = function(register, value)
			calls[#calls + 1] = { register, value }
			return 0
		end,
		notify = function() end,
	})
	assert(clipboard.copy_text("one\ntwo\n", "*"))
	equal({ { "*", "one\ntwo\n" } }, calls, "native clipboard payload changed")
	equal(sentinel, vim.g.clipboard, "empty SSH marker installed the OSC 52 provider")
end)

test("remote raw byte bound includes inter-line separators without truncation", function()
	local_session()
	vim.env.SSH_CONNECTION = "client 1 2 3"
	local sent = {}
	clipboard.setup({ osc52_max_bytes = 5 }, {
		has_ui = function()
			return true
		end,
		native_setreg = function()
			error("remote copy reached native provider")
		end,
		notify = function() end,
		senders = {
			["+"] = function(lines)
				sent[#sent + 1] = { register = "+", lines = vim.deepcopy(lines) }
			end,
			["*"] = function(lines)
				sent[#sent + 1] = { register = "*", lines = vim.deepcopy(lines) }
			end,
		},
	})
	assert(clipboard.copy_lines("+", { "ab", "cd" }))
	equal({ { register = "+", lines = { "ab", "cd" } } }, sent, "accepted remote payload changed")
	local ok, err = clipboard.copy_lines("+", { "ab", "cde" })
	assert(not ok and err:find("5%-byte raw limit"), "oversized remote payload was accepted")
	equal(1, #sent, "oversized payload was partially sent")
	ok, err = clipboard.copy_lines("+", { "ok", 3 })
	assert(not ok and err:find("only strings", 1, true), "mixed payload types were accepted")
end)

test("remote provider requires a UI and reports rejected provider copies", function()
	local_session()
	vim.env.SSH_TTY = "pts/1"
	local notifications = {}
	local sends = 0
	clipboard.setup({ osc52_max_bytes = 3 }, {
		has_ui = function()
			return false
		end,
		native_setreg = function()
			return 0
		end,
		notify = function(message)
			notifications[#notifications + 1] = tostring(message)
		end,
		senders = {
			["+"] = function()
				sends = sends + 1
			end,
			["*"] = function()
				sends = sends + 1
			end,
		},
	})
	assert(not clipboard.available(), "headless OSC 52 reported availability")
	local ok, err = clipboard.copy_text("ok")
	assert(not ok and err:find("attached UI", 1, true), "headless copy did not fail closed")
	vim.g.clipboard.copy["+"]({ "toolong" })
	equal(0, sends, "rejected provider copy reached the sender")
	assert(notifications[#notifications]:find("3%-byte raw limit"), "provider rejection was silent")
end)

test("setup validates its public policy and dependencies", function()
	local_session()
	for _, options in ipairs({
		{ unknown = true },
		{ osc52_max_bytes = 0 },
		{ osc52_max_bytes = 16 * 1024 * 1024 + 1 },
		{ osc52_max_bytes = 1.5 },
	}) do
		assert(not pcall(clipboard.setup, options), "invalid clipboard policy was accepted")
	end
	assert(not pcall(clipboard.setup, {}, { has_ui = true }), "non-callable dependency was accepted")
	assert(not pcall(clipboard.setup, {}, { senders = { ["+"] = function() end } }), "partial senders were accepted")
end)

test("teardown restores the prior provider", function()
	local_session()
	vim.env.SSH_TTY = "pts/1"
	local sentinel = { name = "prior-provider" }
	vim.g.clipboard = sentinel
	clipboard.setup({}, {
		has_ui = function()
			return true
		end,
		native_setreg = function()
			return 0
		end,
		notify = function() end,
		senders = { ["+"] = function() end, ["*"] = function() end },
	})
	assert(vim.g.clipboard.name == "OSC52 (bounded)", "remote provider was not installed")
	clipboard.teardown()
	equal(sentinel, vim.g.clipboard, "teardown did not restore the previous provider")
end)

test("edits preserve the clipboard while native registers and puts still work", function()
	local calls = native_clipboard()
	edit_lines({ "copied word", "stay", "tail" })
	normal("yiw")
	equal({ { "+", { "copied" }, "v" } }, calls, "ordinary yank did not copy exactly once")
	normal("wciwchanged<Esc>")
	equal("word", vim.fn.getreg('"'), "change lost the native deleted text")
	normal("0x")
	equal("c", vim.fn.getreg('"'), "character delete lost its native register")
	normal("dd")
	equal("opied changed\n", vim.fn.getreg('"'), "line delete lost its native register")
	equal("copied", vim.fn.getreg("0"), "edits overwrote the last yank register")
	equal("copied", vim.fn.getreg("+"), "edits overwrote the system clipboard")
	normal("p")
	equal({ "stay", "opied changed", "tail" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "dd then p changed")
	edit_lines({ "one", "two" })
	normal("ddP")
	equal({ "one", "two" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "native P changed")
	equal(1, #calls, "editing or putting exported text to the clipboard")
end)

test("normal and visual yanks preserve exact contents and register types", function()
	local cases = {
		{ keys = "yiw", lines = { "abc" }, kind = "v" },
		{ keys = "yy", lines = { "abc", "" }, kind = "V" },
		{ keys = "viwy", lines = { "abc" }, kind = "v" },
		{ keys = "Vjy", lines = { "abc", "def", "" }, kind = "V" },
		{ keys = "<C-v>jly", lines = { "ab", "de", "" }, kind = "\0222", provider_kind = "b" },
	}
	for _, case in ipairs(cases) do
		local calls = native_clipboard()
		edit_lines({ "abc", "def", "ghi" })
		normal(case.keys)
		equal(
			{ { "+", case.lines, case.provider_kind or case.kind } },
			calls,
			"clipboard shape changed for " .. case.keys
		)
		equal(vim.fn.getreg("0"), vim.fn.getreg('"'), "clipboard mirroring replaced the unnamed register")
		equal(case.kind, vim.fn.getregtype("0"), "clipboard mirroring changed the last yank type")
	end
end)

test("explicit registers keep their destination without duplicate clipboard writes", function()
	local calls = native_clipboard()
	edit_lines({ "copy me" })
	for _, register in ipairs({ "a", "A", "_" }) do
		normal('"' .. register .. "yiw")
	end
	equal({}, calls, "private register yank reached the clipboard")
	for index, register in ipairs({ "+", "*" }) do
		normal('"' .. register .. "yiw")
		equal(index, #calls, "explicit clipboard yank was copied twice")
		equal({ register, { "copy" }, "v" }, calls[index], "explicit clipboard destination changed")
	end
	normal('""yiw')
	equal(3, #calls, "explicit unnamed yank did not mirror to the clipboard")
end)

test("remote yanks use the bounded provider including the linewise newline", function()
	local_session()
	vim.env.SSH_TTY = "pts/1"
	local sent = {}
	local notifications = {}
	clipboard.setup({ osc52_max_bytes = 5 }, {
		has_ui = function()
			return true
		end,
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
		senders = {
			["+"] = function(lines)
				sent[#sent + 1] = vim.deepcopy(lines)
			end,
			["*"] = function()
				error("ordinary yank reached the primary selection")
			end,
		},
	})
	assert(vim.fn["provider#clipboard#Executable"]() == "OSC52 (bounded)")
	edit_lines({ "abcd", "keep" })
	normal("yiw")
	normal("yy")
	equal({ { "abcd" }, { "abcd", "" } }, sent, "remote yanks lost their exact text")
	normal("ciwabcde<Esc>")
	normal("yy")
	normal("dd")
	equal(2, #sent, "edit or oversized yank reached the terminal")
	assert(notifications[#notifications]:find("5%-byte raw limit"), "oversized yank was silently rejected")
end)

test("repeated setup and teardown leave exactly one active yank observer", function()
	local_session()
	local copies = 0
	local deps = {
		native_setreg = function()
			copies = copies + 1
			return 0
		end,
	}
	clipboard.setup({}, deps)
	clipboard.setup({}, deps)
	edit_lines({ "copy me" })
	normal("yy")
	equal(1, copies, "repeated setup duplicated clipboard copies")
	clipboard.teardown()
	normal("yy")
	equal(1, copies, "teardown left an active yank observer")
end)

test("failed clipboard copies notify without losing the native yank", function()
	local_session()
	local notifications = {}
	clipboard.setup({}, {
		native_setreg = function()
			error("copy unavailable")
		end,
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
	})
	edit_lines({ "copy me" })
	normal("yiw")
	equal("copy", vim.fn.getreg("0"), "clipboard failure lost the yank")
	assert(notifications[1]:find("copy unavailable", 1, true), "clipboard failure was silent")
end)

clipboard.teardown()
vim.g.clipboard = original_provider
vim.o.clipboard = original_clipboard_option
vim.env.SSH_TTY = original_ssh_tty
vim.env.SSH_CONNECTION = original_ssh_connection

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("clipboard_spec: %d tests passed"):format(count))
