vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/coverage-workbench.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
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

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/src", "p", tonumber("700", 8))
fixture = vim.uv.fs_realpath(fixture) or fixture
local source = fixture .. "/src/probe.py"
vim.fn.writefile({ "value = 1", "print(value)" }, source)

local coverage = require("coverage_workbench")

test("lifecycle defaults are copied and rejected setup is non-mutating", function()
	local defaults = coverage.effective_config()
	equal({
		max_report_bytes = 50 * 1024 * 1024,
		max_source_bytes = 16 * 1024 * 1024,
		max_model_bytes = 64 * 1024 * 1024,
		signs = "all",
		stale = "hide",
	}, defaults)
	assert(coverage.status().configured == false)
	defaults.max_report_bytes = 1
	equal(50 * 1024 * 1024, coverage.effective_config().max_report_bytes, "effective config leaked state")
	local before = coverage.status()
	local ok, err = coverage.setup({ unknown = true })
	assert(not ok and err:find("unknown option", 1, true), err)
	equal(before, coverage.status(), "rejected setup mutated state")
	ok, err = coverage.setup(false)
	assert(not ok and err:find("object", 1, true), "false setup options were accepted")
	equal(before, coverage.status(), "false setup options mutated state")
end)

assert(coverage.setup())

test("setup enforces hard byte caps transactionally", function()
	assert(coverage.setup({
		max_report_bytes = 256 * 1024 * 1024,
		max_source_bytes = 16 * 1024 * 1024,
		max_model_bytes = 64 * 1024 * 1024,
	}))
	local before = coverage.status()
	for _, options in ipairs({
		{ max_report_bytes = 256 * 1024 * 1024 + 1 },
		{ max_report_bytes = 0 },
		{ max_source_bytes = 16 * 1024 * 1024 + 1 },
		{ max_source_bytes = 0 },
		{ max_model_bytes = 64 * 1024 * 1024 + 1 },
		{ max_source_bytes = 1.5 },
		{ max_model_bytes = 0 },
		{ max_model_bytes = "64" },
	}) do
		local ok, err = coverage.setup(options)
		assert(ok == nil and type(err) == "string", "invalid byte limits were accepted")
		equal(before, coverage.status(), "rejected byte limits mutated setup state")
	end
	assert(coverage.setup())
end)

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

test("Coverage.py line classifications must be pairwise disjoint", function()
	for _, overlap in ipairs({
		{ left = "executed_lines", right = "missing_lines" },
		{ left = "executed_lines", right = "excluded_lines" },
		{ left = "missing_lines", right = "excluded_lines" },
	}) do
		local entry = { executed_lines = {}, missing_lines = {}, excluded_lines = {} }
		entry[overlap.left] = { 1 }
		entry[overlap.right] = { 1 }
		local model, err = coverage.parse_coverage_json(fixture, json(3, { ["src/probe.py"] = entry }))
		assert(model == nil and err:find(overlap.left, 1, true) and err:find(overlap.right, 1, true), err)
	end
end)

test("canonical JSON and LCOV duplicates are rejected before a second read or hash", function()
	local alias = fixture .. "/src/probe-alias.py"
	assert(vim.uv.fs_symlink(source, alias))
	local original_read = vim.uv.fs_read
	local original_sha256 = vim.fn.sha256
	local reads = 0
	local hashes = 0
	vim.uv.fs_read = function(...)
		reads = reads + 1
		return original_read(...)
	end
	vim.fn.sha256 = function(...)
		hashes = hashes + 1
		return original_sha256(...)
	end
	local call_ok, model, err = pcall(
		coverage.parse_coverage_json,
		fixture,
		json(3, {
			["src/probe.py"] = { executed_lines = { 1 }, missing_lines = {}, excluded_lines = {} },
			["src/probe-alias.py"] = { executed_lines = { 1 }, missing_lines = {}, excluded_lines = {} },
		})
	)
	assert(call_ok, model)
	assert(model == nil and err:find("duplicate canonical source", 1, true), err)
	equal(1, reads, "canonical duplicate source was read twice")
	equal(1, hashes, "canonical duplicate source was hashed twice")

	reads, hashes = 0, 0
	call_ok, model, err = pcall(
		coverage.parse_lcov,
		fixture,
		table.concat({
			"SF:src/probe.py",
			"DA:1,1",
			"end_of_record",
			"SF:src/probe-alias.py",
			"DA:1,1",
			"end_of_record",
		}, "\n")
	)
	vim.uv.fs_read = original_read
	vim.fn.sha256 = original_sha256
	vim.fn.delete(alias)
	assert(call_ok, model)
	assert(model == nil and err:find("duplicate LCOV source record", 1, true), err)
	equal(1, reads, "canonical LCOV duplicate source was read twice")
	equal(1, hashes, "canonical LCOV duplicate source was hashed twice")
end)

test("source and aggregate caps reject from descriptor sizes before read or hash", function()
	local original_read = vim.uv.fs_read
	local original_sha256 = vim.fn.sha256
	local reads = 0
	local hashes = 0
	vim.uv.fs_read = function(...)
		reads = reads + 1
		return original_read(...)
	end
	vim.fn.sha256 = function(...)
		hashes = hashes + 1
		return original_sha256(...)
	end
	assert(coverage.setup({ max_source_bytes = 1, max_model_bytes = 1 }))
	local call_ok, model, err = pcall(coverage.parse_coverage_json, fixture, json(3))
	vim.uv.fs_read = original_read
	vim.fn.sha256 = original_sha256
	assert(call_ok, model)
	assert(model == nil and err:find("source exceeds 1 bytes", 1, true), err)
	equal(0, reads, "oversized source was read")
	equal(0, hashes, "oversized source was hashed")

	local first_size = assert(vim.uv.fs_stat(source)).size
	assert(coverage.setup({ max_source_bytes = first_size, max_model_bytes = 1024 * 1024 }))
	assert(coverage.parse_coverage_json(fixture, json(3)), "source exactly at both byte limits was rejected")

	local first_large = fixture .. "/src/first-large.py"
	local second = fixture .. "/src/second-large.py"
	vim.fn.writefile({ string.rep("a", 2047) }, first_large, "b")
	vim.fn.writefile({ string.rep("b", 2047) }, second, "b")
	local first_large_size = assert(vim.uv.fs_stat(first_large)).size
	local second_size = assert(vim.uv.fs_stat(second)).size
	local both_sources = {
		["src/first-large.py"] = { executed_lines = { 1 }, missing_lines = {}, excluded_lines = {} },
		["src/second-large.py"] = { executed_lines = { 1 }, missing_lines = {}, excluded_lines = {} },
	}
	assert(coverage.setup({
		max_source_bytes = math.max(first_large_size, second_size),
		max_model_bytes = first_large_size + second_size,
	}))
	assert(coverage.parse_coverage_json(fixture, json(3, both_sources)), "aggregate exact byte limit was rejected")
	assert(coverage.setup({
		max_source_bytes = math.max(first_large_size, second_size),
		max_model_bytes = first_large_size + second_size - 1,
	}))
	reads, hashes = 0, 0
	vim.uv.fs_read = function(...)
		reads = reads + 1
		return original_read(...)
	end
	vim.fn.sha256 = function(...)
		hashes = hashes + 1
		return original_sha256(...)
	end
	call_ok, model, err = pcall(coverage.parse_coverage_json, fixture, json(3, both_sources))
	vim.uv.fs_read = original_read
	vim.fn.sha256 = original_sha256
	vim.fn.delete(first_large)
	vim.fn.delete(second)
	assert(coverage.setup())
	assert(call_ok, model)
	assert(model == nil and err:find("coverage sources exceed", 1, true), err)
	equal(1, reads, "aggregate overflow read the source that exceeded the remaining descriptor budget")
	equal(1, hashes, "aggregate overflow hashed the source that exceeded the remaining descriptor budget")
end)

test("normalized model entries consume the independent model budget", function()
	local empty = fixture .. "/src/empty.py"
	vim.fn.writefile({}, empty, "b")
	local lines = {}
	for line = 1, 10000 do
		lines[line] = line
	end
	assert(coverage.setup({ max_source_bytes = 1, max_model_bytes = 1024 }))
	local model, err = coverage.parse_coverage_json(
		fixture,
		json(3, {
			["src/empty.py"] = { executed_lines = lines, missing_lines = {}, excluded_lines = {} },
		})
	)
	vim.fn.delete(empty)
	assert(coverage.setup())
	assert(model == nil and err:find("coverage model exceeds", 1, true), err)
end)

test("line numbers outside the sign API range are rejected without publishing state", function()
	local report = fixture .. "/oversized-line.json"
	vim.fn.writefile({
		json(3, {
			["src/probe.py"] = { executed_lines = { 2147483648 }, missing_lines = {}, excluded_lines = {} },
		}),
	}, report)
	local called, loaded, err = pcall(coverage.load, { root = fixture, path = report })
	assert(called, loaded)
	assert(loaded == nil and err:find("invalid line", 1, true), err)
	assert(coverage.snapshot(fixture) == nil, "rejected line number published a registry generation")
	local lcov, lcov_err = coverage.parse_lcov(fixture, "SF:src/probe.py\nDA:2147483648,1\nend_of_record")
	assert(lcov == nil and lcov_err:find("invalid LCOV line", 1, true), lcov_err)
	vim.fn.delete(report)
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

test("source edits and replacements hide stale signs and failed refresh never restores them", function()
	local events = {}
	assert(coverage.setup({
		event = function(event)
			events[#events + 1] = vim.deepcopy(event)
			event.root = "mutated"
		end,
	}))
	vim.fn.writefile({ "value = 1", "print(value)" }, source)
	local report = fixture .. "/stale-coverage.json"
	vim.fn.writefile({ json(3) }, report)
	local buf = vim.fn.bufadd(source)
	vim.fn.bufload(buf)
	assert(coverage.load({ root = fixture, path = report }))
	assert(#owned_signs(buf) == 2)

	vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "value = 2" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
	equal(0, #owned_signs(buf), "modified source retained coverage signs")
	local stale = coverage.snapshot(fixture)
	assert(stale.model.files[source].stale == true, "modified source was not marked stale")
	local stale_event = events[#events]
	assert(stale_event.kind == "stale" and stale_event.root == fixture, "stale event was not isolated")

	vim.fn.writefile({ "{" }, report)
	local refreshed, refresh_err = coverage.refresh(fixture)
	assert(not refreshed and refresh_err:find("invalid coverage.py JSON", 1, true), refresh_err)
	equal(0, #owned_signs(buf), "failed refresh restored stale signs")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "value = 1", "print(value)" })
	vim.bo[buf].modified = false
	vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = buf, modeline = false })
	assert(#owned_signs(buf) == 2, "matching source did not recover its signs")
	local replacement = source .. ".replacement"
	vim.fn.writefile({ "value = 1", "print(value)" }, replacement)
	assert(vim.uv.fs_rename(replacement, source))
	vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf, modeline = false })
	equal(0, #owned_signs(buf), "replaced source identity retained coverage signs")

	assert(coverage.clear(fixture))
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.writefile({ "value = 1", "print(value)" }, source)
	vim.fn.delete(report)
end)

test("repeated text events use the indexed dirty-state fast path", function()
	assert(coverage.setup())
	vim.fn.writefile({ "value = 1", "print(value)" }, source)
	local report = fixture .. "/event-cost-coverage.json"
	vim.fn.writefile({ json(3) }, report)
	local buf = vim.fn.bufadd(source)
	vim.fn.bufload(buf)
	assert(coverage.load({ root = fixture, path = report }))
	assert(#owned_signs(buf) == 2)
	vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "value = 2" })

	local originals = {
		lstat = vim.uv.fs_lstat,
		open = vim.uv.fs_open,
		read = vim.uv.fs_read,
		realpath = vim.uv.fs_realpath,
		sha256 = vim.fn.sha256,
		place = vim.fn.sign_place,
		unplace = vim.fn.sign_unplace,
	}
	local counts = { lstat = 0, open = 0, read = 0, realpath = 0, sha256 = 0, place = 0, unplace = 0 }
	vim.uv.fs_lstat = function(...)
		counts.lstat = counts.lstat + 1
		return originals.lstat(...)
	end
	vim.uv.fs_open = function(...)
		counts.open = counts.open + 1
		return originals.open(...)
	end
	vim.uv.fs_read = function(...)
		counts.read = counts.read + 1
		return originals.read(...)
	end
	vim.uv.fs_realpath = function(...)
		counts.realpath = counts.realpath + 1
		return originals.realpath(...)
	end
	vim.fn.sha256 = function(...)
		counts.sha256 = counts.sha256 + 1
		return originals.sha256(...)
	end
	vim.fn.sign_place = function(...)
		counts.place = counts.place + 1
		return originals.place(...)
	end
	vim.fn.sign_unplace = function(...)
		counts.unplace = counts.unplace + 1
		return originals.unplace(...)
	end
	local call_ok, call_err = xpcall(function()
		for _ = 1, 32 do
			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf, modeline = false })
			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf, modeline = false })
		end
	end, debug.traceback)
	vim.uv.fs_lstat = originals.lstat
	vim.uv.fs_open = originals.open
	vim.uv.fs_read = originals.read
	vim.uv.fs_realpath = originals.realpath
	vim.fn.sha256 = originals.sha256
	vim.fn.sign_place = originals.place
	vim.fn.sign_unplace = originals.unplace
	assert(call_ok, call_err)
	equal({ lstat = 0, open = 0, read = 0, realpath = 0, sha256 = 0, place = 0, unplace = 1 }, counts)
	equal(0, #owned_signs(buf), "dirty fast path restored coverage signs")

	assert(coverage.clear(fixture))
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(report)
	vim.fn.writefile({ "value = 1", "print(value)" }, source)
end)

test("buffer events revalidate only the directly indexed project", function()
	assert(coverage.setup())
	local other_root = fixture .. "/other-project"
	local other_source = other_root .. "/src/probe.py"
	assert(vim.fn.mkdir(other_root .. "/src", "p", tonumber("700", 8)) == 1)
	assert(vim.fn.writefile({ "other = true" }, other_source) == 0)
	local report = fixture .. "/indexed-coverage.json"
	local other_report = other_root .. "/coverage.json"
	assert(vim.fn.writefile({ json(3) }, report) == 0)
	assert(vim.fn.writefile({ json(3) }, other_report) == 0)
	local buf = vim.fn.bufadd(source)
	vim.fn.bufload(buf)
	assert(coverage.load({ root = fixture, path = report }))
	assert(coverage.load({ root = other_root, path = other_report }))

	local original_lstat = vim.uv.fs_lstat
	local source_stats = 0
	local other_stats = 0
	vim.uv.fs_lstat = function(path, ...)
		if path == source then
			source_stats = source_stats + 1
		elseif path == other_source then
			other_stats = other_stats + 1
		end
		return original_lstat(path, ...)
	end
	local call_ok, call_err = xpcall(function()
		vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf, modeline = false })
	end, debug.traceback)
	vim.uv.fs_lstat = original_lstat
	assert(call_ok, call_err)
	equal(2, source_stats, "current source metadata was not checked exactly once")
	equal(0, other_stats, "unrelated registered project was scanned for a buffer event")

	assert(coverage.clear(fixture))
	assert(coverage.clear(other_root))
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(report)
	vim.fn.delete(other_root, "rf")
end)

test("reload after an atomic symlink retarget releases signs from the old source", function()
	assert(coverage.setup())
	local alias = fixture .. "/retarget.py"
	local first = fixture .. "/retarget-a.py"
	local second = fixture .. "/retarget-b.py"
	local replacement = fixture .. "/retarget.next"
	local report = fixture .. "/retarget.info"
	assert(vim.fn.writefile({ "first = true" }, first) == 0)
	assert(vim.fn.writefile({ "second = true" }, second) == 0)
	assert(vim.uv.fs_symlink(vim.fs.basename(first), alias))
	assert(vim.fn.writefile({ "SF:retarget.py", "DA:1,1", "end_of_record" }, report) == 0)
	local buf = vim.fn.bufadd(alias)
	vim.fn.bufload(buf)
	assert(coverage.load({ root = fixture, path = report, format = "lcov" }))
	equal(1, #owned_signs(buf), "coverage was not rendered for the original symlink target")

	assert(vim.uv.fs_symlink(vim.fs.basename(second), replacement))
	assert(vim.uv.fs_rename(replacement, alias))
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("edit!")
	end)
	equal({ "second = true" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	equal(0, #owned_signs(buf), "old-target coverage survived a symlink retarget and reload")

	assert(coverage.clear(fixture))
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.fn.delete(alias)
	vim.fn.delete(first)
	vim.fn.delete(second)
	vim.fn.delete(report)
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
	coverage.setup({ max_report_bytes = 2 })
	local loaded, err = coverage.load({ root = fixture, path = report })
	assert(loaded == nil and err:match("exceeds"))
	local unknown, unknown_err = coverage.load({ root = fixture, path = report, format = "future" })
	assert(unknown == nil and (unknown_err:match("exceeds") or unknown_err:match("unsupported")))
end)

test("repeated setup replaces config and teardown is deterministic", function()
	assert(coverage.setup({ signs = "missing", stale = "show" }))
	local status = coverage.status()
	status.config.signs = "changed"
	equal("missing", coverage.status().config.signs, "status leaked mutable config")
	local before = coverage.status()
	local ok = coverage.setup({ injected = true })
	assert(not ok)
	equal(before, coverage.status(), "invalid repeated setup mutated state")
	assert(coverage.setup())
	equal("all", coverage.effective_config().signs)
	assert(coverage.teardown())
	assert(coverage.teardown())
	assert(not coverage.status().configured)
	equal("hide", coverage.effective_config().stale)
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("coverage_workbench_spec: %d tests passed"):format(count))
