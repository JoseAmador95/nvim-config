vim.o.shadafile = "NONE"
vim.o.swapfile = false
local plugin = vim.fn.getcwd() .. "/local-plugins/rex.nvim"
vim.opt.runtimepath:prepend(plugin)
package.path = plugin .. "/lua/?.lua;" .. plugin .. "/lua/?/init.lua;" .. package.path

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })
local rex, calls, timers, scheduled, previous_timer, previous_env

local function flush()
	local turns = 0
	while #scheduled > 0 do
		turns = turns + 1
		assert(turns < 100, "callbacks did not settle")
		table.remove(scheduled, 1)()
	end
end

local function response(call, value, code, raw)
	if value ~= nil then
		call.options.stdout(nil, raw and value or vim.json.encode(value))
	end
	call.exit({ code = code or 0 })
	flush()
end

local function latest(method)
	local call = calls[#calls]
	assert(call and call.argv[8] == method, "expected " .. method .. ", got " .. vim.inspect(call and call.argv))
	return call
end

local function body(call)
	return vim.json.decode(call.argv[9])
end

local function count(method)
	local result = 0
	for _, call in ipairs(calls) do
		if call.argv[8] == method then
			result = result + 1
		end
	end
	return result
end

local function context()
	local result
	rex.context(function(err, value)
		assert(not err, err)
		result = value
	end)
	response(calls[#calls], {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		block = {
			block_id = "block:11111111-1111-4111-8111-111111111111",
			window_id = "window:11111111-1111-4111-8111-111111111111",
			creator_name = "terminal",
		},
	})
	return result
end

local function spec(ctx, callback)
	return {
		context = ctx,
		label = "LazyGit",
		command = { "lazygit", "literal ; $(text)", "" },
		cwd = "/tmp",
		on_close = callback,
	}
end

local function snapshot(label, focused)
	local layers = {
		{
			layer_id = "layer:11111111-1111-4111-8111-111111111111",
			kind = "tiled",
			blocks = {
				{ block_id = "block:11111111-1111-4111-8111-111111111111" },
				{ block_id = "block:33333333-3333-4333-8333-333333333333" },
			},
		},
	}
	if label then
		layers[#layers + 1] = {
			layer_id = "layer:22222222-2222-4222-8222-222222222222",
			kind = "floating",
			blocks = { { block_id = "block:22222222-2222-4222-8222-222222222222", label = label } },
		}
	end
	return {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		active_window_id = "window:11111111-1111-4111-8111-111111111111",
		windows = {
			{
				window_id = "window:11111111-1111-4111-8111-111111111111",
				focused_block_id = focused or "block:11111111-1111-4111-8111-111111111111",
				layers = layers,
			},
		},
	}
end

local function open(callback)
	local ctx = context()
	local value, failure
	local request = rex.open_float(spec(ctx, callback), function(err, result)
		failure, value = err, result
	end)
	response(latest("session.new_layer"), {
		layer_id = "layer:22222222-2222-4222-8222-222222222222",
		block_ids = { "block:22222222-2222-4222-8222-222222222222" },
		revision = 2,
	})
	assert(not failure and value, failure)
	return value, ctx, request
end

local function poll()
	for _, timer in ipairs(timers) do
		if timer.repeating and timer.repeating > 0 and not timer.closed then
			timer.callback()
			flush()
			return
		end
	end
	error("no live poll timer")
end

hooks.pre_case = function()
	calls, timers, scheduled = {}, {}, {}
	previous_env = { session = vim.env.REX_SESSION, block = vim.env.REX_BLOCK, server = vim.env.REX_SERVER }
	vim.env.REX_SESSION, vim.env.REX_BLOCK, vim.env.REX_SERVER =
		"session:11111111-1111-4111-8111-111111111111",
		"block:11111111-1111-4111-8111-111111111111",
		"unix:///tmp/rex.sock"
	previous_timer = vim.uv.new_timer
	vim.uv.new_timer = function()
		local timer = {}
		function timer:start(delay, repeating, callback)
			self.delay, self.repeating, self.callback = delay, repeating, callback
		end
		function timer:stop()
			self.stopped = true
		end
		function timer:close()
			self.closed = true
		end
		timers[#timers + 1] = timer
		return timer
	end
	package.loaded.rex, package.loaded["rex.process"] = nil, nil
	rex = require("rex")
	rex.setup({
		system = function(argv, options, on_exit)
			local call = { argv = vim.deepcopy(argv), options = options, exit = on_exit }
			calls[#calls + 1] = call
			function call:kill(signal)
				self.killed = signal
			end
			return call
		end,
		schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end,
	})
end

hooks.post_case = function()
	vim.uv.new_timer = previous_timer
	vim.env.REX_SESSION, vim.env.REX_BLOCK, vim.env.REX_SERVER =
		previous_env.session, previous_env.block, previous_env.server
end

T["setup is passive, copied, and rejects unknown options without mutation"] = function()
	assert(#calls == 0 and #timers == 0)
	local initial = rex.effective_config()
	local changed = rex.effective_config()
	changed.bin = "wrong"
	assert(rex.effective_config().bin == "rex")
	local ok = pcall(rex.setup, { bin = "changed", invented = true })
	assert(not ok and vim.deep_equal(rex.effective_config(), initial))
	for _, options in ipairs({ { timeout_ms = 0 }, { poll_interval_ms = math.huge }, { system = false } }) do
		assert(not pcall(rex.setup, options))
	end
	assert(#calls == 0 and #timers == 0)
end

T["absent context falls back asynchronously; partial and remote contexts fail"] = function()
	vim.env.REX_SESSION, vim.env.REX_BLOCK = nil, nil
	local invoked = false
	rex.context(function(err, value)
		assert(not err and value == nil)
		invoked = true
	end)
	assert(not invoked)
	flush()
	assert(invoked and #calls == 0)
	vim.env.REX_SESSION = "session:11111111-1111-4111-8111-111111111111"
	local failure
	rex.context(function(err)
		failure = err
	end)
	flush()
	assert(failure and #calls == 0)
	vim.env.REX_BLOCK, vim.env.REX_SERVER = "block:11111111-1111-4111-8111-111111111111", "ssh://other"
	rex.context(function(err)
		failure = err
	end)
	flush()
	assert(failure:find("local Unix", 1, true) and #calls == 0)
end

T["context verifies inherited IDs rather than current app focus"] = function()
	local ctx = context()
	assert(vim.deep_equal(ctx, {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		window_id = "window:11111111-1111-4111-8111-111111111111",
		block_id = "block:11111111-1111-4111-8111-111111111111",
	}))
	assert(vim.deep_equal(calls[1].argv, {
		"rex",
		"--autostart=false",
		"--timeout=5000ms",
		"block",
		"inspect",
		"-s",
		"session:11111111-1111-4111-8111-111111111111",
		"block:11111111-1111-4111-8111-111111111111",
		"--json",
	}))
	local failure
	rex.context(function(err)
		failure = err
	end)
	response(calls[2], {
		session_id = "session:22222222-2222-4222-8222-222222222222",
		block = {
			block_id = "block:11111111-1111-4111-8111-111111111111",
			window_id = "window:11111111-1111-4111-8111-111111111111",
		},
	})
	assert(failure:find("exact inherited", 1, true))
end

T["creation preserves argv and cwd and targets the verified source window"] = function()
	local value = open()
	local args = body(latest("session.new_layer"))
	assert(
		args.session_id == "session:11111111-1111-4111-8111-111111111111"
			and args.window_id == "window:11111111-1111-4111-8111-111111111111"
			and args.focus
	)
	assert(vim.deep_equal(args.bounds, { 0.05, 0.05, 0.9, 0.9 }))
	assert(vim.deep_equal(args.layout.block.options, {
		command = { "lazygit", "literal ; $(text)", "" },
		cwd = "/tmp",
		shell = "none",
		login = false,
		exit = { on_completion = true },
	}))
	assert(args.layout.block.flavor == "com.superlogical.terminal.shell")
	assert(args.layout.block.label == value.label and value.label ~= "LazyGit")
	assert(
		value.session_id == "session:11111111-1111-4111-8111-111111111111"
			and value.source_block_id == "block:11111111-1111-4111-8111-111111111111"
			and value.window_id == "window:11111111-1111-4111-8111-111111111111"
	)
	assert(
		value.layer_id == "layer:22222222-2222-4222-8222-222222222222"
			and value.block_id == "block:22222222-2222-4222-8222-222222222222"
	)
end

T["invalid and unverified open requests do not mutate Rex"] = function()
	local ctx = {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		window_id = "window:11111111-1111-4111-8111-111111111111",
		block_id = "block:11111111-1111-4111-8111-111111111111",
	}
	local failure
	rex.open_float(spec(ctx), function(err)
		failure = err
	end)
	flush()
	assert(failure and #calls == 0)
	ctx = context()
	for _, change in ipairs({
		{ cwd = "relative" },
		{ command = { "exe", "nul\0" } },
		{ command = {} },
		{ arbitrary = true },
	}) do
		rex.open_float(vim.tbl_extend("force", spec(ctx), change), function(err)
			failure = err
		end)
		flush()
		assert(failure and #calls == 1)
	end
end

T["owned handles are copied and focus targets the exact block"] = function()
	local value = open()
	local bad = vim.deepcopy(value)
	bad.block_id = "unrelated"
	local failure
	rex.close(bad, function(err)
		failure = err
	end)
	flush()
	assert(failure and #calls == 2)
	local status = rex.status()
	status.records[1].handle.layer_id = "wrong"
	assert(rex.status().records[1].handle.layer_id == "layer:22222222-2222-4222-8222-222222222222")
	rex.focus(value, function(err)
		assert(not err, err)
	end)
	assert(vim.deep_equal(body(latest("session.focus_block")), {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		block_id = "block:22222222-2222-4222-8222-222222222222",
	}))
	response(latest("session.focus_block"), { revision = 3 })
end

T["a repeated open reuses the live resource and rejects different commands"] = function()
	local value, ctx = open()
	local reused, failure
	rex.open_float(spec(ctx), function(err, result)
		failure, reused = err, result
	end)
	flush()
	assert(not failure and vim.deep_equal(reused, value) and count("session.new_layer") == 1)
	local changed = spec(ctx)
	changed.command = { "another" }
	rex.open_float(changed, function(err)
		failure = err
	end)
	flush()
	assert(failure and count("session.new_layer") == 1)
end

T["a lost creation reply is reconciled by its unique label without replay"] = function()
	local ctx = context()
	local value, failure
	rex.open_float(spec(ctx), function(err, result)
		failure, value = err, result
	end)
	local create = latest("session.new_layer")
	local label = body(create).layout.block.label
	response(create, "not json", 0, true)
	response(latest("session.view"), snapshot(label, "block:22222222-2222-4222-8222-222222222222"))
	assert(
		not failure
			and value.layer_id == "layer:22222222-2222-4222-8222-222222222222"
			and count("session.new_layer") == 1
	)
end

T["missing uncertain creation stays blocked and an explicit retry reconciles it"] = function()
	local ctx = context()
	local failure, value
	rex.open_float(spec(ctx), function(err)
		failure = err
	end)
	local create = latest("session.new_layer")
	local label = body(create).layout.block.label
	response(create, nil, 124)
	response(latest("session.view"), snapshot())
	assert(failure:find("uncertain", 1, true) and rex.status().records[1].state == "uncertain")
	rex.open_float(spec(ctx), function(err, result)
		failure, value = err, result
	end)
	response(latest("session.view"), snapshot(label, "block:22222222-2222-4222-8222-222222222222"))
	assert(
		not failure
			and value.block_id == "block:22222222-2222-4222-8222-222222222222"
			and count("session.new_layer") == 1
	)
end

T["ambiguous reconciliation cannot adopt or close unrelated layers"] = function()
	local ctx = context()
	local failure
	rex.open_float(spec(ctx), function(err)
		failure = err
	end)
	local label = body(latest("session.new_layer")).layout.block.label
	response(latest("session.new_layer"), {}, 0)
	local state = snapshot(label)
	state.windows[1].layers[2].blocks[2] = { block_id = "another", label = label }
	response(latest("session.view"), state)
	assert(failure:find("uncertain", 1, true) and count("session.close_layer") == 0)
end

T["close targets only its layer and does not steal unrelated focus"] = function()
	local closed_count = 0
	local value = open(function()
		closed_count = closed_count + 1
	end)
	local done
	rex.close(value, function(err)
		assert(not err, err)
		done = true
	end)
	response(latest("session.view"), snapshot(value.label, "block:33333333-3333-4333-8333-333333333333"))
	assert(vim.deep_equal(body(latest("session.close_layer")), {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		layer_id = "layer:22222222-2222-4222-8222-222222222222",
	}))
	response(latest("session.close_layer"), { revision = 3 })
	assert(done and closed_count == 1 and #rex.status().records == 0 and count("session.focus_block") == 0)
	for _, timer in ipairs(timers) do
		assert(timer.closed, "timer leaked after close")
	end
end

T["focus returns to the source only while its window still needs focus"] = function()
	local value = open()
	local done
	rex.close(value, function(err)
		assert(not err, err)
		done = true
	end)
	response(latest("session.view"), snapshot(value.label, "block:22222222-2222-4222-8222-222222222222"))
	response(latest("session.close_layer"), { revision = 3 })
	response(latest("session.view"), snapshot(nil, vim.NIL))
	assert(body(latest("session.focus_block")).block_id == "block:11111111-1111-4111-8111-111111111111")
	response(latest("session.focus_block"), { revision = 4 })
	assert(done)
end

T["a focus change during close prevents restoration"] = function()
	local value = open()
	rex.close(value, function(err)
		assert(not err, err)
	end)
	response(latest("session.view"), snapshot(value.label, "block:22222222-2222-4222-8222-222222222222"))
	response(latest("session.close_layer"), { revision = 3 })
	response(latest("session.view"), snapshot(nil, "block:33333333-3333-4333-8333-333333333333"))
	assert(count("session.focus_block") == 0)
end

T["polling observes external close once and ignores malformed or failed views"] = function()
	local closed_count = 0
	open(function()
		closed_count = closed_count + 1
	end)
	poll()
	local in_flight = #calls
	poll()
	assert(#calls == in_flight, "poll requests overlapped")
	response(latest("session.view"), {
		session_id = "session:11111111-1111-4111-8111-111111111111",
		windows = { { window_id = "window:11111111-1111-4111-8111-111111111111" } },
	})
	assert(closed_count == 0)
	poll()
	response(latest("session.view"), nil, 1)
	assert(closed_count == 0)
	poll()
	response(latest("session.view"), snapshot())
	assert(closed_count == 1 and #rex.status().records == 0)
	for _, timer in ipairs(timers) do
		assert(timer.closed)
	end
end

T["cancelling a pending create reconciles then removes only its owned layer"] = function()
	local ctx = context()
	local failure, closed_count
	closed_count = 0
	local request = rex.open_float(
		spec(ctx, function()
			closed_count = closed_count + 1
		end),
		function(err)
			failure = err
		end
	)
	local create = latest("session.new_layer")
	local label = body(create).layout.block.label
	request.cancel()
	flush()
	assert(create.killed == 9)
	response(latest("session.view"), snapshot(label, "block:11111111-1111-4111-8111-111111111111"))
	response(latest("session.view"), snapshot(label, "block:11111111-1111-4111-8111-111111111111"))
	response(latest("session.close_layer"), { revision = 3 })
	assert(failure:find("cancelled", 1, true) and closed_count == 1 and #rex.status().records == 0)
	response(create, {
		layer_id = "layer:22222222-2222-4222-8222-222222222222",
		block_ids = { "block:22222222-2222-4222-8222-222222222222" },
	})
	assert(closed_count == 1 and count("session.new_layer") == 1)
end

T["timeouts kill the CLI and reconcile without replaying mutations"] = function()
	local ctx = context()
	local failure
	rex.open_float(spec(ctx), function(err)
		failure = err
	end)
	local create = latest("session.new_layer")
	timers[#timers].callback()
	flush()
	assert(create.killed == 9 and timers[2].closed)
	response(latest("session.view"), snapshot())
	assert(failure:find("uncertain", 1, true) and count("session.new_layer") == 1)
end

T["bounded output is killed before decoding and a late exit cannot finish twice"] = function()
	local invoked, failure = 0
	rex.context(function(err)
		invoked, failure = invoked + 1, err
	end)
	local call = calls[#calls]
	call.options.stdout(nil, string.rep("x", 1024 * 1024 + 1))
	flush()
	assert(call.killed == 9 and invoked == 1 and failure:find("size limit", 1, true))
	response(call, nil, 1)
	assert(invoked == 1 and rex.status().pending == 0)
end

T["changing the local server cannot redirect an owned handle"] = function()
	local value = open()
	vim.env.REX_SERVER = "unix:///tmp/other.sock"
	local failure
	rex.focus(value, function(err)
		failure = err
	end)
	flush()
	assert(failure:find("server changed", 1, true) and count("session.focus_block") == 0)
end

T["teardown closes existing resources and prevents new creation"] = function()
	local value, ctx = open()
	rex.teardown()
	response(latest("session.view"), snapshot(value.label))
	response(latest("session.close_layer"), { revision = 3 })
	local failure
	rex.open_float(spec(ctx), function(err)
		failure = err
	end)
	flush()
	assert(failure:find("stopping", 1, true))
	assert(rex.status().pending == 0 and #rex.status().records == 0)
end

T["hide and restore keep the owned layer alive, including while minimized"] = function()
	local closed_count, completed = 0, 0
	local value = open(function()
		closed_count = closed_count + 1
	end)
	local function done(err)
		assert(not err, err)
		completed = completed + 1
	end
	rex.hide(value, done)
	response(latest("session.view"), snapshot(value.label, value.block_id))
	assert(vim.deep_equal(body(latest("session.set_layer_state")), {
		session_id = value.session_id,
		layer_id = value.layer_id,
		state = "minimized",
	}))
	response(latest("session.set_layer_state"), { revision = 3 })
	local hidden = snapshot(value.label)
	hidden.windows[1].layers[2].state = "minimized"
	poll()
	response(latest("session.view"), hidden)
	assert(closed_count == 0 and #rex.status().records == 1)
	rex.restore(value, done)
	response(latest("session.view"), hidden)
	assert(vim.deep_equal(body(latest("session.set_layer_state")), {
		session_id = value.session_id,
		layer_id = value.layer_id,
		state = "normal",
		focus = true,
	}))
	response(latest("session.set_layer_state"), { revision = 4 })
	assert(completed == 2 and count("session.new_layer") == 1 and count("session.close_layer") == 0)
end

T["resize validates and copies bounds without focusing or recreating the layer"] = function()
	local value = open()
	for _, bounds in ipairs({ {}, { 0, 0, 0, 1 }, { 0.8, 0, 0.5, 1 }, { 0, 0, 1, 0 / 0 }, { "x", 0, 1, 1 } }) do
		local failure
		local before = #calls
		rex.resize(value, bounds, function(err)
			failure = err
		end)
		flush()
		assert(failure and #calls == before)
	end
	local bounds = { 0.52, 0.05, 0.43, 0.9 }
	local completed
	rex.resize(value, bounds, function(err)
		assert(not err, err)
		completed = true
	end)
	bounds[1] = 0
	response(latest("session.view"), snapshot(value.label))
	assert(vim.deep_equal(body(latest("session.resize_layer")).bounds, { 0.52, 0.05, 0.43, 0.9 }))
	assert(body(latest("session.resize_layer")).layer_id == value.layer_id)
	response(latest("session.resize_layer"), { revision = 3 })
	assert(completed and count("session.focus_block") == 0 and count("session.new_layer") == 1)
end

T["pane controls refuse foreign handles and layers moved out of the owned window"] = function()
	local closed_count = 0
	local value = open(function()
		closed_count = closed_count + 1
	end)
	local forged = vim.deepcopy(value)
	forged.layer_id = "layer:foreign"
	local failure
	local before = #calls
	rex.hide(forged, function(err)
		failure = err
	end)
	flush()
	assert(failure and #calls == before)
	rex.restore(value, function(err)
		failure = err
	end)
	local moved = snapshot(value.label)
	moved.windows[1].window_id = "window:other"
	response(latest("session.view"), moved)
	assert(failure:find("source window", 1, true))
	assert(closed_count == 1 and count("session.set_layer_state") == 0 and #rex.status().records == 0)
end

return T
