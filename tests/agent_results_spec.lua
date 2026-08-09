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

local fixture = vim.fn.tempname()
local outside = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
assert(vim.fn.writefile({ "first", "second" }, fixture .. "/inside.lua") == 0)
assert(vim.fn.writefile({ "outside" }, outside) == 0)
assert(vim.uv.fs_symlink(outside, fixture .. "/escape.lua"))
local root = assert(vim.uv.fs_realpath(fixture))
local results = require("config.agent_results")

local function item()
	return {
		path = "inside.lua",
		start = { line = 1, column = 2 },
		["end"] = { line = 2, column = 3 },
		severity = "warning",
		message = "finding",
		source = "agent-a",
	}
end

local function payload()
	return { version = 1, repo_root = root, run_id = "run-1", items = { item() } }
end

local function validate(value, expected_fragment)
	local converted, err = results.validate(vim.json.encode(value), root)
	assert(not converted, "invalid payload was accepted")
	assert(tostring(err):find(expected_fragment, 1, true), tostring(err))
end

test("valid results map every quickfix field and open Trouble", function()
	local qf
	local trouble = 0
	local imported = results.import(vim.json.encode(payload()), {
		current_root = function()
			return root
		end,
		setqflist = function(items, action, options)
			qf = { items, action, options }
		end,
		open_trouble = function()
			trouble = trouble + 1
		end,
		notify = function() end,
	})
	assert(imported and #imported.items == 1)
	assert(qf[2] == " ")
	assert(qf[3].title == "Agent results: run-1")
	local found = qf[3].items[1]
	assert(found.filename == root .. "/inside.lua")
	assert(found.lnum == 1 and found.col == 2 and found.end_lnum == 2 and found.end_col == 3)
	assert(found.type == "W" and found.text == "finding" and found.module == "agent-a")
	assert(trouble == 1, "Trouble qflist was not opened exactly once")
end)

test("size and count limits fail closed", function()
	local oversized = string.rep(" ", results.max_bytes + 1)
	local converted, err = results.validate(oversized, root)
	assert(not converted and err:find("maximum", 1, true))
	local value = payload()
	value.items = {}
	for _ = 1, results.max_items + 1 do
		value.items[#value.items + 1] = item()
	end
	validate(value, "maximum is 2000")
end)

test("unknown and executable fields are rejected at every object level", function()
	local value = payload()
	value.extra = true
	validate(value, "unknown key")
	for _, key in ipairs({ "executable", "action", "callback" }) do
		value = payload()
		value.items[1][key] = "danger"
		validate(value, "unknown key")
	end
	value = payload()
	value.items[1].start.extra = 1
	validate(value, "unknown key")
	value = payload()
	value.items[1]["end"].callback = "danger"
	validate(value, "unknown key")
end)

test("version, exact root, and bounded strings are enforced", function()
	local value = payload()
	value.version = 2
	validate(value, "version")
	value = payload()
	value.repo_root = root .. "/."
	validate(value, "exactly equal")
	value = payload()
	value.run_id = string.rep("r", 257)
	validate(value, "run_id exceeds")
	value = payload()
	value.items[1].source = string.rep("s", 257)
	validate(value, "source exceeds")
	value = payload()
	value.items[1].message = string.rep("m", 16 * 1024 + 1)
	validate(value, "message exceeds")
end)

test("positions and severity are strict", function()
	local value = payload()
	value.items[1].start.line = 0
	validate(value, "positive integer")
	value = payload()
	value.items[1].start.column = 1.5
	validate(value, "positive integer")
	value = payload()
	value.items[1]["end"] = { line = 1, column = 1 }
	validate(value, "before start")
	value = payload()
	value.items[1].severity = "error"
	validate(value, "blocker, warning, or nit")
end)

test("unsafe, missing, and escaping paths are rejected", function()
	local value = payload()
	value.items[1].path = "/etc/passwd"
	validate(value, "repository-relative")
	value = payload()
	value.items[1].path = "../outside.lua"
	validate(value, "traversal")
	value = payload()
	value.items[1].path = "missing.lua"
	validate(value, "does not exist")
	value = payload()
	value.items[1].path = "bad\0name"
	validate(value, "NUL")
	value = payload()
	value.items[1].path = "escape.lua"
	validate(value, "outside the repository")
end)

test("user command preserves one-line JSON containing spaces", function()
	local original = results.import
	local seen
	results.import = function(encoded)
		seen = encoded
	end
	results.setup()
	vim.cmd([[AgentResultsImport {"version": 1, "items": []}]])
	vim.api.nvim_del_user_command("AgentResultsImport")
	results.import = original
	assert(seen == [[{"version": 1, "items": []}]])
end)

vim.fn.delete(fixture, "rf")
vim.fn.delete(outside)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("agent_results_spec: %d tests passed", count))
vim.cmd("quitall!")
