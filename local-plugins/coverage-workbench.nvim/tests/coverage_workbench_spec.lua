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

local function json(format, files)
	local meta = { version = "fixture" }
	if format ~= "legacy" then
		meta.format = format
	end
	return vim.json.encode({
		meta = meta,
		files = files or {
			["src/probe.py"] = {
				executed_lines = { 1 },
				missing_lines = { 2 },
				excluded_lines = {},
			},
		},
		totals = {},
	})
end

local function owned_signs(buf)
	local placed = vim.fn.sign_getplaced(buf, { group = "*" })
	return vim.tbl_filter(function(sign)
		return sign.name == "CoverageWorkbenchCovered" or sign.name == "CoverageWorkbenchMissing"
	end, placed[1].signs)
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
	local scalar_meta, scalar_meta_err = coverage.parse_coverage_json(fixture, '{"meta":1,"files":{},"totals":{}}')
	assert(scalar_meta == nil and scalar_meta_err:find("meta must be an object", 1, true))
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

test("valid replacement clears stale signs while invalid refresh preserves state", function()
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
	assert(#owned_signs(buf) == 2)

	vim.fn.writefile({ json(3, vim.empty_dict()) }, report)
	local replacement = assert(coverage.load({ root = fixture, path = report }))
	assert(replacement.generation == 2 and replacement.model.files[source] == nil)
	assert(#owned_signs(buf) == 0, "successful replacement retained signs for an omitted file")

	vim.fn.writefile({ json(3) }, report)
	local restored = assert(coverage.load({ root = fixture, path = report }))
	assert(#owned_signs(buf) == 2)
	vim.fn.writefile({ "{" }, report)
	local refreshed, refresh_err = coverage.refresh(fixture)
	assert(refreshed == nil and refresh_err:find("invalid coverage.py JSON", 1, true))
	assert(vim.deep_equal(restored, coverage.snapshot(fixture)), "invalid refresh replaced the registered snapshot")
	assert(#owned_signs(buf) == 2, "invalid refresh removed the previous signs")

	assert(coverage.clear(fixture))
	assert(coverage.snapshot(fixture) == nil)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("outside symlink is rejected before its target is opened", function()
	local outside = vim.fn.tempname()
	local link = fixture .. "/outside-report.json"
	vim.fn.writefile({ json(3) }, outside)
	assert(vim.uv.fs_symlink(outside, link))
	local original_open = vim.uv.fs_open
	local target_opened = false
	vim.uv.fs_open = function(path, flags, mode)
		if path == outside then
			target_opened = true
		end
		return original_open(path, flags, mode)
	end
	local call_ok, loaded, load_err = pcall(coverage.load, { root = fixture, path = link })
	vim.uv.fs_open = original_open
	vim.fn.delete(link)
	vim.fn.delete(outside)
	assert(call_ok, loaded)
	assert(loaded == nil and load_err:find("outside the project", 1, true))
	assert(not target_opened, "outside report target was opened before containment was checked")
end)

test("descriptor identity and post-read changes fail closed", function()
	local race = fixture .. "/race.json"
	local outside = vim.fn.tempname()
	vim.fn.writefile({ json(3) }, race)
	vim.fn.writefile({ json(3) }, outside)

	local original_open = vim.uv.fs_open
	local original_read = vim.uv.fs_read
	local swapped = false
	local read_called = false
	vim.uv.fs_open = function(path, flags, mode)
		if path == race and flags == "r" and not swapped then
			assert(vim.uv.fs_unlink(race))
			assert(vim.uv.fs_symlink(outside, race))
			swapped = true
		end
		return original_open(path, flags, mode)
	end
	vim.uv.fs_read = function(...)
		read_called = true
		return original_read(...)
	end
	local call_ok, loaded, load_err = pcall(coverage.load, { root = fixture, path = race })
	vim.uv.fs_open = original_open
	vim.uv.fs_read = original_read
	assert(call_ok, loaded)
	assert(loaded == nil and load_err:find("changed while opening", 1, true))
	assert(not read_called, "swapped descriptor was read before its identity was rejected")
	assert(vim.uv.fs_unlink(race))
	vim.fn.writefile({ json(3) }, race)

	local mutated = false
	vim.uv.fs_read = function(...)
		local data, err = original_read(...)
		if not mutated then
			vim.fn.writefile({ '{"changed":true}' }, race)
			mutated = true
		end
		return data, err
	end
	call_ok, loaded, load_err = pcall(coverage.load, { root = fixture, path = race })
	vim.uv.fs_read = original_read
	vim.fn.delete(race)
	vim.fn.delete(outside)
	assert(call_ok, loaded)
	assert(loaded == nil and load_err:find("changed while reading", 1, true))
end)

test("alternating ancestor symlink swaps cannot fake descriptor containment", function()
	local report_dir = fixture .. "/report-dir"
	local displaced_dir = fixture .. "/report-dir.original"
	local report = report_dir .. "/race.json"
	local outside_dir = vim.fn.tempname()
	vim.fn.mkdir(report_dir, "p", tonumber("700", 8))
	vim.fn.mkdir(outside_dir, "p", tonumber("700", 8))
	vim.fn.writefile({ json(3) }, report)
	vim.fn.writefile({ json(3) }, outside_dir .. "/race.json")

	local original_lstat = vim.uv.fs_lstat
	local original_realpath = vim.uv.fs_realpath
	local original_read = vim.uv.fs_read
	local swapped = false
	local read_called = false
	local function swap_to_outside()
		assert(vim.uv.fs_rename(report_dir, displaced_dir))
		assert(vim.uv.fs_symlink(outside_dir, report_dir))
		swapped = true
	end
	local function restore_inside()
		assert(vim.uv.fs_unlink(report_dir))
		assert(vim.uv.fs_rename(displaced_dir, report_dir))
		swapped = false
	end
	vim.uv.fs_lstat = function(path)
		if path == report and not swapped then
			swap_to_outside()
		end
		return original_lstat(path)
	end
	vim.uv.fs_realpath = function(path)
		if path == report and swapped then
			restore_inside()
		end
		return original_realpath(path)
	end
	vim.uv.fs_read = function(...)
		read_called = true
		return original_read(...)
	end
	local call_ok, loaded, load_err = pcall(coverage.load, { root = fixture, path = report })
	vim.uv.fs_lstat = original_lstat
	vim.uv.fs_realpath = original_realpath
	vim.uv.fs_read = original_read
	if swapped then
		restore_inside()
	end
	vim.fn.delete(report_dir, "rf")
	vim.fn.delete(outside_dir, "rf")
	assert(call_ok, loaded)
	assert(loaded == nil and load_err:find("changed while opening", 1, true))
	assert(not read_called, "descriptor reached through an alternating ancestor swap was read")
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
