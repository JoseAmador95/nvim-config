vim.o.shadafile = "NONE"
vim.o.swapfile = false
-- Exercise the documented focused invocation with a relative runtime path.
vim.opt.runtimepath:prepend(".")
require("config.local_plugins").setup()
local review = require("config.native_review")
local adapter = require("config.review_diffbandit")
local bandit = require("native_review.diffbandit")
local original_system, original_resolve, original_timer = adapter._system, adapter._resolve, adapter._new_timer

local T = MiniTest.new_set({
	hooks = {
		post_case = function()
			adapter._system, adapter._resolve, adapter._new_timer = original_system, original_resolve, original_timer
		end,
	},
})

local function entry(old, new)
	return {
		old_text = old,
		new_text = new,
		old_path = "sample.lua",
		new_path = "sample.lua",
		hunks = vim.diff(old, new, { result_type = "indices" }),
	}
end

local function prepare(value)
	local done, result, failure
	local cancel = review.engines.prepare("diffbandit", value, function(prepared, err)
		assert(not vim.in_fast_event())
		done, result, failure = true, prepared, err
	end)
	MiniTest.finally(cancel)
	assert(
		vim.wait(6000, function()
			return done
		end, 10),
		"Diffbandit did not finish"
	)
	return result, failure
end

T["pinned worker supplies word detail and sub-block alignment from frozen texts"] = function()
	local value =
		entry("local answer = old_name\nreturn answer\n", "local answer = new_name\nlog(answer)\nreturn answer\n")
	local before = vim.deepcopy(value)
	local result = assert(prepare(value))
	assert(result.selected_engine == "diffbandit" and result.origin_engine.version == "0.3.0")
	assert(result.presentation == "projected" and not result.structural_only)
	assert(#result.projection.hunks > 0 and #result.intraline.old > 0 and #result.intraline.new > 0)
	local range = result.intraline.old[1]
	assert(range.line == 1 and range.start_col == 15 and range.end_col == 23)
	assert(result.projection.by_source.old[2] and result.projection.by_source.new[3])
	assert(vim.deep_equal(before, value), "engine changed the canonical Git model")
	assert(package.loaded.diffbandit == nil and package.loaded["diffbandit.diff"] == nil)
	assert(vim.fn.exists(":DiffBandit") == 0, "engine activated the upstream UI")
end

T["textual changes preserve whitespace CRLF Unicode and source coordinates"] = function()
	local samples = {
		{ "  return café\n", "    return cafés\n" },
		{ "local x = 1\r\nreturn x\r\n", "local x = 2\r\nreturn x\r\n" },
		{ "return x\r\n", "return x\n" },
		{ "local x = 1\rlocal y = 2\r", "local x = 1\rlocal y = 3\r" },
		{ 'return "👩‍💻 é"\n', 'return "👨‍💻 é"\n' },
		{ "return 1", "return 2" },
		{ "", "new\n" },
		{ "old\n", "" },
		{ "\n", "\n\n" },
	}
	for _, sample in ipairs(samples) do
		local value = entry(unpack(sample))
		local result, err = prepare(value)
		assert(result, err)
		assert(result.origin_engine.id == "diffbandit")
		assert(#result.projection.hunks > 0, "textual change was hidden")
		for _, side in ipairs({ "old", "new" }) do
			local source = result.projection.sources[side]
			assert(source.raw == value[side .. "_text"])
			for line = 1, source.line_count do
				local display = result.projection.by_source[side][line]
				assert(display and result.projection.rows[display][side .. "_line"] == line)
			end
		end
	end
end

T["final-newline changes visibly use Main with truthful provenance"] = function()
	adapter._system = function()
		error("final-newline fallback spawned a worker")
	end
	for _, pair in ipairs({ { "return 1", "return 1\n" }, { "return 1\n", "return 2" } }) do
		local value = entry(unpack(pair))
		local result = assert(prepare(value))
		assert(result.selected_engine == "diffbandit" and result.origin_engine.id == "main")
		assert(result.fallback_reason:find("Final-newline", 1, true) and result.presentation == "native")
		assert(#value.hunks > 0)
	end
end

T["binary and metadata-only entries retain their native presentation"] = function()
	adapter._system = function()
		error("nontext entry spawned a worker")
	end
	for _, flag in ipairs({ "binary", "metadata_only" }) do
		local value = entry("", "")
		value[flag] = true
		local result = assert(prepare(value))
		assert(result.origin_engine.id == "main" and result.fallback_reason)
	end
end

T["malformed hunks cannot hide changes or create invalid source anchors"] = function()
	local value = entry("one\nold\n", "one\nnew\n")
	for _, hunks in ipairs({ {}, { { 3, 1, 3, 1 } }, { { 2, 1, 2, 1 }, { 2, 1, 2, 1 } }, { { 0, 0, 0, 0 } } }) do
		local result, err = bandit.normalize(value, { hunks = hunks, intraline = { old = {}, new = {} } })
		assert(not result and err)
	end
end

T["intraline coordinates reject unchanged lines byte overflow and split UTF-8"] = function()
	local value = entry("same\néx\n", "same\nèy\n")
	for _, range in ipairs({
		{ line = 1, start_col = 0, end_col = 1 },
		{ line = 2, start_col = 0, end_col = 4 },
		{ line = 2, start_col = 1, end_col = 2 },
		{ line = 2, start_col = 0, end_col = 1 },
		{ line = 0, start_col = 0, end_col = 1 },
	}) do
		assert(not bandit.normalize(value, { hunks = { { 2, 1, 2, 1 } }, intraline = { old = { range }, new = {} } }))
	end
end

T["missing dependency gives an explicit installation command"] = function()
	adapter._resolve = function()
		return nil, "Diffbandit is unavailable; run :Lazy install diffbandit.nvim"
	end
	local result, err = prepare(entry("old\n", "new\n"))
	assert(not result and err:find(":Lazy install diffbandit.nvim", 1, true))
end

local function process_fixture()
	local calls = { killed = 0, results = {} }
	adapter._new_timer = function()
		return {
			start = function(_, timeout, _, fire)
				calls.timeout, calls.fire = timeout, fire
				return 0
			end,
			stop = function() end,
			close = function()
				calls.timer_closed = true
			end,
		}
	end
	adapter._resolve = function()
		return "/pinned/diffbandit"
	end
	adapter._system = function(argv, opts, on_exit)
		calls.argv, calls.opts, calls.exit = argv, opts, on_exit
		return {
			kill = function(_, signal)
				assert(signal == 9)
				calls.killed = calls.killed + 1
			end,
		}
	end
	calls.cancel = adapter.analyze({ entry = entry("old\r\n", "new\r\n") }, function(output, err)
		assert(not vim.in_fast_event())
		calls.results[#calls.results + 1] = { output = output, err = err }
	end)
	MiniTest.finally(calls.cancel)
	return calls
end

T["worker gets only frozen stdin and has a five-second deadline"] = function()
	local calls = process_fixture()
	assert(vim.json.decode(calls.opts.stdin).old_text == "old\r\n")
	assert(calls.timeout == 5000 and calls.opts.clear_env and calls.opts.cwd == "/")
	assert(not table.concat(calls.argv, " "):find("old", 1, true))
	calls.fire()
	calls.exit({ code = 0 })
	assert(vim.wait(1000, function()
		return #calls.results == 1
	end))
	assert(calls.results[1].err:find("5 seconds", 1, true))
	assert(calls.killed == 1 and calls.timer_closed)
end

T["output limit kills the worker and reports once despite late completion"] = function()
	local calls = process_fixture()
	calls.opts.stdout(nil, string.rep("x", 8 * 1024 * 1024 + 1))
	calls.exit({ code = 0 })
	assert(vim.wait(1000, function()
		return #calls.results == 1
	end))
	assert(calls.killed == 1 and calls.results[1].err:find("exceeded 8 MiB", 1, true))
	assert(calls.timer_closed)
end

T["cancellation suppresses in-flight and already queued completions"] = function()
	for _, exited in ipairs({ false, true }) do
		local calls = process_fixture()
		calls.opts.stdout(nil, "[]")
		if exited then
			calls.exit({ code = 0 })
		end
		calls.cancel()
		if not exited then
			calls.exit({ code = 0 })
		end
		vim.wait(20, function()
			return false
		end, 1)
		assert(#calls.results == 0 and calls.killed == (exited and 0 or 1))
	end
end

T["spawn failures are reported without replacing the review"] = function()
	adapter._system = function()
		error("spawn unavailable")
	end
	local result, err = prepare(entry("old\n", "new\n"))
	assert(not result and err:find("Cannot start Diffbandit", 1, true))
end

T["deadline forcefully stops a real CPU-bound worker"] = function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root .. "/lua/diffbandit", "p")
	vim.fn.writefile(
		{ "return { compute_hunks = function() while true do end end }" },
		root .. "/lua/diffbandit/diff.lua"
	)
	MiniTest.finally(function()
		vim.fn.delete(root, "rf")
	end)
	adapter._resolve = function()
		return root
	end
	local exited
	adapter._system = function(argv, opts, on_exit)
		return original_system(argv, opts, function(result)
			exited = result
			on_exit(result)
		end)
	end
	-- Keep the regression quick while retaining the actual timer and process.
	adapter._new_timer = function()
		local timer = assert(original_timer())
		return {
			start = function(_, timeout, interval, callback)
				assert(timeout == 5000)
				return timer:start(200, interval, callback)
			end,
			stop = function()
				timer:stop()
			end,
			close = function()
				timer:close()
			end,
		}
	end
	local result, err = prepare(entry("old\n", "new\n"))
	assert(not result and err:find("exceeded 5 seconds", 1, true))
	assert(
		vim.wait(1000, function()
			return exited ~= nil
		end, 10),
		"worker survived its deadline"
	)
	assert(exited.signal == 9, vim.inspect(exited))
end

T["a missing deadline prevents unbounded worker startup"] = function()
	adapter._new_timer = function()
		return nil
	end
	adapter._system = function()
		error("worker started without a deadline")
	end
	local result, err = prepare(entry("old\n", "new\n"))
	assert(not result and err:find("Cannot start Diffbandit deadline", 1, true))
end

return T
