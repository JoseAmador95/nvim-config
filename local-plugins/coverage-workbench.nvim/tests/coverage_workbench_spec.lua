vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/coverage-workbench.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

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
vim.fn.mkdir(fixture .. "/src", "p", tonumber("700", 8))
fixture = vim.uv.fs_realpath(fixture) or fixture
local source = fixture .. "/src/probe.py"
vim.fn.writefile({ "value = 1", "print(value)" }, source)

local coverage = require("coverage_workbench")
coverage.setup()

local function json(format)
	local meta = { version = "fixture" }
	if format ~= "legacy" then
		meta.format = format
	end
	return vim.json.encode({
		meta = meta,
		files = {
			["src/probe.py"] = {
				executed_lines = { 1 },
				missing_lines = { 2 },
				excluded_lines = {},
			},
		},
		totals = {},
	})
end

test("accepts legacy and known Coverage.py JSON formats", function()
	for _, format in ipairs({ "legacy", 1, 2, 3 }) do
		local model, err = coverage.parse_coverage_json(fixture, json(format))
		assert(model, err)
		assert(model.schema_version == format)
		assert(model.files[source].executed_lines[1] == 1)
		assert(model.totals.percent_covered == 50)
	end
end)

test("rejects future, malformed, and escaping Coverage.py data", function()
	local future, future_err = coverage.parse_coverage_json(fixture, json(4))
	assert(future == nil and future_err:match("unsupported"))
	local malformed = coverage.parse_coverage_json(fixture, "{")
	assert(malformed == nil)
	local outside = vim.fn.tempname()
	vim.fn.writefile({ "outside" }, outside)
	local data = vim.json.decode(json(3))
	data.files = { [outside] = { executed_lines = {}, missing_lines = {}, excluded_lines = {} } }
	local escaped = coverage.parse_coverage_json(fixture, vim.json.encode(data))
	assert(escaped == nil)
	vim.fn.delete(outside)
end)

test("parses LCOV without executing a generator", function()
	local original_system = vim.system
	local called = false
	vim.system = function()
		called = true
		error("generator execution is forbidden")
	end
	local model, err = coverage.parse_lcov(
		fixture,
		table.concat({ "TN:", "SF:src/probe.py", "DA:1,1", "DA:2,0", "LF:2", "LH:1", "end_of_record" }, "\n")
	)
	vim.system = original_system
	assert(model, err)
	assert(model.files[source].executed_lines[1] == 1)
	assert(model.files[source].missing_lines[1] == 2)
	assert(called == false)
end)

test("LCOV rejects unterminated, invalid, and outside records", function()
	assert(coverage.parse_lcov(fixture, "SF:src/probe.py\nDA:1,1") == nil)
	assert(coverage.parse_lcov(fixture, "DA:1,1\nend_of_record") == nil)
	local outside = vim.fn.tempname()
	vim.fn.writefile({ "outside" }, outside)
	assert(coverage.parse_lcov(fixture, "SF:" .. outside .. "\nDA:1,1\nend_of_record") == nil)
	vim.fn.delete(outside)
end)

test("load registers immutable project snapshots and owned signs", function()
	local report = fixture .. "/coverage.json"
	vim.fn.writefile({ json(3) }, report)
	local buf = vim.fn.bufadd(source)
	vim.fn.bufload(buf)
	local snapshot, err = coverage.load({ root = fixture, path = report })
	assert(snapshot, err)
	snapshot.model.files[source].executed_lines[1] = 99
	local second = coverage.snapshot(fixture)
	assert(second.model.files[source].executed_lines[1] == 1)
	assert(second.generation == 1)
	local placed = vim.fn.sign_getplaced(buf, { group = "*" })
	local owned = vim.tbl_filter(function(sign)
		return sign.name == "CoverageWorkbenchCovered" or sign.name == "CoverageWorkbenchMissing"
	end, placed[1].signs)
	assert(#placed == 1 and #owned == 2)
	assert(coverage.clear(fixture))
	assert(coverage.snapshot(fixture) == nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("size limits and unknown formats fail closed", function()
	local report = fixture .. "/tiny.json"
	vim.fn.writefile({ json(2) }, report)
	coverage.setup({ max_bytes = 2 })
	local loaded, err = coverage.load({ root = fixture, path = report })
	assert(loaded == nil and err:match("exceeds"))
	local unknown, unknown_err = coverage.load({ root = fixture, path = report, format = "future" })
	assert(unknown == nil and (unknown_err:match("exceeds") or unknown_err:match("unsupported")))
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("coverage_workbench_spec: %d tests passed"):format(count))
