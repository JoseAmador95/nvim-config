vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local deferred_loads = 0
package.loaded["config.deferred"] = {
	load = function()
		deferred_loads = deferred_loads + 1
		error("unexpected startup resolution")
	end,
	try = function()
		return false, "upstream UI unavailable in isolated spec"
	end,
}
local jqx = require("config.jqx")
local notifications = {}
jqx._notify = function(message, level)
	notifications[#notifications + 1] = { message = tostring(message), level = level }
end

local function json_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(bufnr)
	vim.bo[bufnr].filetype = "json"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"{",
		'  "alpha": 1,',
		'  "space key": "value"',
		"}",
	})
	return bufnr
end

local function json_array_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(bufnr)
	vim.bo[bufnr].filetype = "json"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"[",
		'  "zero",',
		'  { "name": "one" }',
		"]",
	})
	return bufnr
end

test("module discovery never resolves jq or starts a process", function()
	assert(deferred_loads == 0)
end)

test("missing or drifted jq blocks before spawn", function()
	local bufnr = json_buffer()
	for _, reason in ipairs({ "absent", "drift: executable metadata changed" }) do
		local spawns = 0
		jqx._resolve = function()
			return nil, reason
		end
		jqx._system = function()
			spawns = spawns + 1
		end
		local process, err = jqx.list()
		assert(process == nil and tostring(err):find(reason, 1, true))
		assert(spawns == 0, "unverified jq reached the process boundary")
	end
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("YAML is blocked without resolving PATH-only yq", function()
	local bufnr = json_buffer()
	vim.bo[bufnr].filetype = "yaml"
	local resolves = 0
	local spawns = 0
	jqx._resolve = function()
		resolves = resolves + 1
		return "/verified/bin/jq"
	end
	jqx._system = function()
		spawns = spawns + 1
	end
	local process, err = jqx.list()
	assert(process == nil and tostring(err):find("verified yq is not configured", 1, true))
	assert(resolves == 0 and spawns == 0, "YAML fell through to a PATH executable")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("oversized JSON is rejected before a full read, decode, or spawn", function()
	local bufnr = json_buffer()
	local original_offset = vim.api.nvim_buf_get_offset
	local original_lines = vim.api.nvim_buf_get_lines
	local original_decode = vim.json.decode
	local reads = 0
	local decodes = 0
	local spawns = 0
	local ok, err = xpcall(function()
		vim.api.nvim_buf_get_offset = function(target, index)
			if target == bufnr then
				assert(index == vim.api.nvim_buf_line_count(bufnr))
				return 16 * 1024 * 1024 + 2
			end
			return original_offset(target, index)
		end
		vim.api.nvim_buf_get_lines = function(target, ...)
			if target == bufnr then
				reads = reads + 1
				error("oversized buffer was read")
			end
			return original_lines(target, ...)
		end
		vim.json.decode = function(...)
			decodes = decodes + 1
			return original_decode(...)
		end
		jqx._resolve = function()
			return "/verified/bin/jq"
		end
		jqx._system = function()
			spawns = spawns + 1
		end

		local process, list_err = jqx.list()
		assert(process == nil and tostring(list_err):find("exceeds", 1, true))
		assert(vim.deep_equal(jqx.complete_keys(""), {}))
	end, debug.traceback)
	vim.api.nvim_buf_get_offset = original_offset
	vim.api.nvim_buf_get_lines = original_lines
	vim.json.decode = original_decode
	assert(ok, err)
	assert(reads == 0, "oversized JSON reached nvim_buf_get_lines")
	assert(decodes == 0, "oversized JSON reached vim.json.decode")
	assert(spawns == 0, "oversized JSON reached the process boundary")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("JSON tree uses verified absolute jq and stdin without shell interpolation", function()
	local bufnr = json_buffer()
	local observed
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(argv, options, callback)
		observed = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
		options.stdout(nil, '"alpha"\n"space key"\n')
		callback({ code = 0 })
		return { pid = 1 }
	end
	assert(jqx.list())
	assert(vim.wait(1000, function()
		return #vim.fn.getqflist() == 2
	end))
	assert(observed.argv[1] == "/verified/bin/jq" and observed.argv[2] == "-r")
	assert(type(observed.argv) == "table" and #observed.argv == 3, "jq was not passed as an argv vector")
	assert(observed.options.stdin:find('"space key"', 1, true), "buffer content did not use stdin")
	local items = vim.fn.getqflist()
	assert(items[1].bufnr == bufnr and items[1].lnum == 2 and items[1].col == 3)
	assert(items[2].bufnr == bufnr and items[2].lnum == 3 and items[2].col == 3)
	local mapping
	for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
		if candidate.lhs == "X" then
			mapping = candidate
			break
		end
	end
	assert(mapping and type(mapping.callback) == "function", "JQX key query mapping is missing")
	observed = nil
	mapping.callback()
	assert(vim.wait(1000, function()
		return observed ~= nil and vim.bo.filetype == "jqx"
	end))
	assert(vim.deep_equal(observed.argv, { "/verified/bin/jq", "-r", "--arg", "key", "alpha", ".[$key]" }))
	vim.cmd("close")
	vim.cmd("cclose")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("top-level arrays keep typed numeric keys and query indices with argjson", function()
	local bufnr = json_array_buffer()
	local observed = {}
	vim.fn.setqflist({}, "r")
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(argv, options, callback)
		observed[#observed + 1] = vim.deepcopy(argv)
		if #observed == 1 then
			options.stdout(nil, "0\n1\n")
		else
			options.stdout(nil, "zero\n")
		end
		callback({ code = 0 })
		return { pid = 9 }
	end
	assert(jqx.list())
	assert(vim.wait(1000, function()
		local state = vim.fn.getqflist({ items = 0 })
		return #state.items == 2
			and type(state.items[1].user_data) == "table"
			and type(state.items[1].user_data.jqx_key) == "table"
			and state.items[1].user_data.jqx_key.kind == "integer"
	end))
	local items = vim.fn.getqflist()
	assert(items[1].text == "0" and items[2].text == "1")
	assert(items[1].user_data.jqx_key.kind == "integer" and items[1].user_data.jqx_key.value == 0)
	local mapping
	for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
		if candidate.lhs == "X" then
			mapping = candidate
			break
		end
	end
	assert(mapping and type(mapping.callback) == "function")
	mapping.callback()
	assert(vim.wait(1000, function()
		return #observed == 2 and vim.bo.filetype == "jqx"
	end))
	assert(vim.deep_equal(observed[2], { "/verified/bin/jq", "-r", "--argjson", "key", "0", ".[$key]" }))
	vim.cmd("close")
	vim.cmd("cclose")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("type-filtered JSON tree keeps the upstream JQX query contract", function()
	local bufnr = json_buffer()
	local observed
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(argv, options, callback)
		observed = vim.deepcopy(argv)
		options.stdout(nil, '"alpha"\n')
		callback({ code = 0 })
		return { pid = 4 }
	end
	assert(jqx.list("number"))
	assert(vim.wait(1000, function()
		return #vim.fn.getqflist() == 1
	end))
	assert(observed[1] == "/verified/bin/jq")
	assert(vim.deep_equal(vim.list_slice(observed, 2, 5), { "-r", "--arg", "kind", "number" }))
	assert(observed[6]:find("select(.value|type == $kind)", 1, true))
	vim.cmd("cclose")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("query text remains one inert argv item", function()
	local bufnr = json_buffer()
	local observed
	local original_columns = vim.o.columns
	local original_lines = vim.o.lines
	vim.o.columns = 12
	vim.o.lines = 6
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(argv, options, callback)
		observed = vim.deepcopy(argv)
		options.stdout(nil, "1\n")
		callback({ code = 0 })
		return { pid = 2 }
	end
	assert(jqx.query('.alpha; "$(touch /tmp/not-run)"'))
	assert(vim.wait(1000, function()
		return observed ~= nil and vim.bo.filetype == "jqx"
	end))
	assert(vim.deep_equal(observed, { "/verified/bin/jq", '.alpha; "$(touch /tmp/not-run)"' }))
	local window = vim.api.nvim_win_get_config(0)
	assert(window.width <= 10 and window.height <= 2, "JQX float escaped the narrow editor bounds")
	assert(window.row >= 0 and window.col >= 0, "JQX float used a negative placement")
	vim.cmd("close")
	vim.o.columns = original_columns
	vim.o.lines = original_lines
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("a changed buffer invalidates asynchronous tree results", function()
	local bufnr = json_buffer()
	local pending
	vim.fn.setqflist({}, "r")
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(_, options, callback)
		pending = { options = options, callback = callback }
		return { pid = 3 }
	end
	assert(jqx.list())
	vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '  "changed": 2,' })
	pending.options.stdout(nil, '"alpha"\n')
	pending.callback({ code = 0 })
	assert(vim.wait(1000, function()
		return notifications[#notifications]
			and notifications[#notifications].message:find("results were discarded", 1, true)
	end))
	assert(#vim.fn.getqflist() == 0)
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("key queries reject a list snapshot changed before spawn", function()
	local bufnr = json_buffer()
	local spawns = 0
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(_, options, callback)
		spawns = spawns + 1
		options.stdout(nil, '"alpha"\n')
		callback({ code = 0 })
		return { pid = 6 }
	end
	assert(jqx.list())
	assert(vim.wait(1000, function()
		return #vim.fn.getqflist() == 1
	end))
	local mapping
	for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do
		if candidate.lhs == "X" then
			mapping = candidate
			break
		end
	end
	assert(mapping and type(mapping.callback) == "function")
	vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '  "alpha": 2,' })
	local before_notifications = #notifications
	mapping.callback()
	assert(spawns == 1, "stale list snapshot reached a second jq spawn")
	assert(#notifications == before_notifications + 1)
	assert(notifications[#notifications].message:find("results were discarded", 1, true))
	vim.cmd("cclose")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("an in-flight query never publishes a result after the source changes", function()
	local bufnr = json_buffer()
	local pending
	local windows = #vim.api.nvim_list_wins()
	local before_notifications = #notifications
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(_, options, callback)
		pending = { options = options, callback = callback }
		return { pid = 7 }
	end
	assert(jqx.query(".alpha"))
	vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '  "alpha": 2,' })
	pending.options.stdout(nil, "1\n")
	pending.callback({ code = 0 })
	assert(vim.wait(1000, function()
		return #notifications > before_notifications
			and notifications[#notifications].message:find("results were discarded", 1, true) ~= nil
	end))
	assert(#vim.api.nvim_list_wins() == windows, "stale query opened a result window")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("too many query result lines fail before a float is materialized", function()
	local bufnr = json_buffer()
	local output_lines = {}
	for index = 1, 4097 do
		output_lines[index] = tostring(index)
	end
	local windows = #vim.api.nvim_list_wins()
	local before_notifications = #notifications
	jqx._resolve = function()
		return "/verified/bin/jq"
	end
	jqx._system = function(_, options, callback)
		options.stdout(nil, table.concat(output_lines, "\n"))
		callback({ code = 0 })
		return { pid = 8 }
	end
	assert(jqx.query(".alpha"))
	assert(vim.wait(1000, function()
		return #notifications > before_notifications
			and notifications[#notifications].message:find("4096-line JQX result limit", 1, true) ~= nil
	end))
	assert(#vim.api.nvim_list_wins() == windows, "oversized query result opened a float")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("too many keys stop at the item bound without publishing a partial quickfix", function()
	local bufnr = json_buffer()
	vim.fn.setqflist({}, " ", {
		title = "existing",
		items = { { bufnr = bufnr, lnum = 1, col = 1, text = "sentinel" } },
	})
	local output_lines = {}
	for index = 1, 4097 do
		output_lines[index] = vim.json.encode("key-" .. index)
	end
	local original_decode = vim.json.decode
	local decodes = 0
	local before_notifications = #notifications
	local ok, err = xpcall(function()
		vim.json.decode = function(...)
			decodes = decodes + 1
			return original_decode(...)
		end
		jqx._resolve = function()
			return "/verified/bin/jq"
		end
		jqx._system = function(_, options, callback)
			options.stdout(nil, table.concat(output_lines, "\n") .. "\n")
			callback({ code = 0 })
			return { pid = 5 }
		end
		assert(jqx.list())
		assert(vim.wait(1000, function()
			local latest = notifications[#notifications]
			return #notifications > before_notifications and latest.message:find("4096-item JQX limit", 1, true) ~= nil
		end))
	end, debug.traceback)
	vim.json.decode = original_decode
	assert(ok, err)
	assert(decodes == 4096, "JQX decoded entries beyond its strict item bound")
	local state = vim.fn.getqflist({ title = 0, items = 0 })
	assert(state.title == "existing" and #state.items == 1 and state.items[1].text == "sentinel")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("the pinned upstream plugin remains UI-only and has no command trigger", function()
	package.loaded["plugins.jqx"] = nil
	local specs = require("plugins.jqx")
	assert(#specs == 1 and specs[1][1] == "gennaro-tedesco/nvim-jqx")
	assert(specs[1].event == "User NvimConfigJqxUi")
	assert(specs[1].cmd == nil, "upstream shell-string commands remain directly triggerable")
end)

test("the host facade synchronously reclaims upstream shell-string entries", function()
	vim.api.nvim_create_user_command("JqxList", function() end, { force = true })
	vim.api.nvim_create_user_command("JqxQuery", function() end, { force = true })
	vim.api.nvim_exec2("function! FileKeys(A, L, P)\nreturn []\nendfunction", { output = false })
	vim.api.nvim_exec2("function! TypeKeys(A, L, P)\nreturn []\nendfunction", { output = false })
	vim.keymap.set("n", "<Plug>JqxList", "<cmd>echo 'unsafe'<cr>")
	local group = vim.api.nvim_create_augroup("JqxAutoClose", { clear = true })
	vim.api.nvim_create_autocmd("WinLeave", { group = group, callback = function() end })

	local commands = require("config.jqx_commands")
	commands.setup(true)
	assert(vim.fn.exists("*FileKeys") == 0 and vim.fn.exists("*TypeKeys") == 0)
	assert(vim.fn.maparg("<Plug>JqxList", "n") == "")
	assert(vim.fn.exists("#JqxAutoClose") == 0)
	local list = vim.api.nvim_get_commands({ builtin = false }).JqxList
	local query = vim.api.nvim_get_commands({ builtin = false }).JqxQuery
	assert(list and list.nargs == "?" and list.definition:find("verified jq", 1, true))
	assert(query and query.nargs == "?" and query.definition:find("verified jq", 1, true))
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("jqx_spec: %d tests passed", count))
vim.cmd("quitall!")
