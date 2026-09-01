vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local diagram = require("diagram_view")
local cache = require("diagram_view.cache")
local failures = {}
local count = 0
local temporary = {}

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

local function cache_root()
	local parent = vim.fn.tempname()
	assert(vim.fn.mkdir(parent, "p") == 1)
	temporary[#temporary + 1] = parent
	return parent .. "/diagram-v3"
end

local function setup(opts)
	opts = opts or {}
	local ok, err = diagram.setup({
		cache_root = opts.cache_root or cache_root(),
		default_mode = opts.default_mode,
		stage_timeout_ms = opts.stage_timeout_ms,
		max_stage_output_bytes = opts.max_stage_output_bytes,
		cache = opts.cache,
		spawn = opts.spawn,
		schedule = opts.schedule or function(callback)
			callback()
		end,
		defer = opts.defer,
		plantuml_policy = opts.plantuml_policy,
		notify = opts.notify,
		event = opts.event,
	})
	assert(ok, err)
end

test("lifecycle defaults are copied and rejected setup is non-mutating", function()
	local defaults = diagram.effective_config()
	equal({
		default_mode = "svg",
		stage_timeout_ms = 30000,
		max_stage_output_bytes = 16 * 1024 * 1024,
		cache = { max_age_seconds = 30 * 24 * 60 * 60, max_bytes = 256 * 1024 * 1024 },
	}, defaults)
	assert(diagram.status().configured == false)
	defaults.cache.max_bytes = 1
	equal(256 * 1024 * 1024, diagram.effective_config().cache.max_bytes, "effective config leaked state")
	local before = diagram.status()
	local ok, err = diagram.setup({ unknown = true })
	assert(not ok and err:find("unknown option", 1, true), err)
	equal(before, diagram.status(), "rejected setup mutated state")
end)

local function renderer(plantuml)
	assert(diagram.register_renderer("test", {
		plantuml = plantuml,
		build = function()
			return {
				extension = "txt",
				stages = { { argv = { "renderer" }, env = { PLANTUML_SECURITY_PROFILE = "UNSECURE" }, text = true } },
			}
		end,
	}))
end

local function presenter(log, name)
	name = name or "test"
	assert(diagram.register_presenter(name, {
		open = function(request)
			log.opened = request.kind
			return { name = name }
		end,
		deliver = function(presentation, result)
			log.delivered = { presentation.name, result.data, result.cached }
		end,
		error = function(_, message)
			log.error = message
		end,
		close = function()
			log.closed = (log.closed or 0) + 1
		end,
	}))
end

test("extracts homogeneous fences, explicit selections, and whole buffers", function()
	local fences = assert(diagram.find_fences({
		"````Mermaid title",
		"flowchart LR",
		"A --> B",
		"`````",
		"~~~plantuml",
		"@startuml",
		"A -> B",
		"@enduml",
		"~~~~",
	}))
	equal(2, #fences)
	equal("mermaid", fences[1].kind)
	equal("flowchart LR\nA --> B", fences[1].source)
	equal("plantuml", fences[2].kind)

	local selected = assert(diagram.extract({
		lines = { "ignored", "A -> B", "C -> D" },
		filetype = "plantuml",
		selection = { start_row = 2, end_row = 3 },
	}))
	equal("selection", selected.origin.type)
	equal("plantuml", selected.kind)
	equal("A -> B\nC -> D", selected.source)

	local fenced = assert(diagram.extract({
		lines = { "before", "```mermaid", "A --> B", "```", "after" },
		filetype = "markdown",
		row = 3,
	}))
	equal("fence", fenced.origin.type)
	equal("A --> B", fenced.source)

	local whole = assert(diagram.extract({ lines = { "graph TD", "A --> B" }, filetype = "mermaid" }))
	equal("buffer", whole.origin.type)
	equal("graph TD\nA --> B", whole.source)
end)

test("malformed and unsupported outer fences do not expose nested diagrams", function()
	local found = assert(diagram.find_fences({
		"~~~text",
		"```mermaid",
		"hidden",
		"```",
		"~~~",
		"```~text",
		"```mermaid",
		"visible",
		"```",
	}, { mermaid = true }))
	equal(1, #found)
	equal("visible", found[1].source)
end)

test("PlantUML is sandboxed unless local trust explicitly permits a profile", function()
	local environments = {}
	local function spawn(_, options, callback)
		environments[#environments + 1] = vim.deepcopy(options.env)
		callback({ code = 0, stdout = "rendered", stderr = "" })
		return { kill = function() end }
	end
	setup({ spawn = spawn })
	renderer(true)
	presenter({})
	assert(diagram.open({ renderer = "test", presenter = "test", kind = "plantuml", source = "A -> B" }))
	equal("SANDBOX", environments[1].PLANTUML_SECURITY_PROFILE)

	setup({
		spawn = spawn,
		plantuml_policy = function()
			return { policy = "local-trusted", profile = "ALLOWLIST" }
		end,
	})
	renderer(true)
	presenter({})
	local trusted =
		assert(diagram.open({ renderer = "test", presenter = "test", kind = "plantuml", source = "B -> C" }))
	equal("ALLOWLIST", trusted:status().security_profile)
	equal("ALLOWLIST", environments[2].PLANTUML_SECURITY_PROFILE)

	setup({
		spawn = spawn,
		plantuml_policy = function()
			return { policy = "remote-trusted", profile = "UNSECURE" }
		end,
	})
	renderer(true)
	presenter({})
	assert(diagram.open({ renderer = "test", presenter = "test", kind = "plantuml", source = "C -> D" }))
	equal("SANDBOX", environments[3].PLANTUML_SECURITY_PROFILE)
end)

test("cancellation kills active work and ignores a late callback", function()
	local callback
	local killed = {}
	local log = {}
	setup({
		spawn = function(_, _, done)
			callback = done
			return {
				kill = function(_, signal)
					killed[#killed + 1] = signal
				end,
			}
		end,
	})
	renderer(false)
	presenter(log)
	local session = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "A" }))
	equal("running", session:status().state)
	assert(session:cancel("closed"))
	equal({ 15 }, killed)
	equal(1, log.closed)
	callback({ code = 0, stdout = "too late", stderr = "" })
	assert(log.delivered == nil, "late renderer output reached the presenter")
	equal({}, diagram.status().sessions)
end)

test("stage timeout kills work and late completion cannot cache or present", function()
	local callback
	local timeout
	local killed = 0
	local log = {}
	local root = cache_root()
	setup({
		cache_root = root,
		stage_timeout_ms = 7,
		defer = function(done, milliseconds)
			equal(7, milliseconds, "configured timeout was not used")
			timeout = done
			return {
				stop = function() end,
				is_closing = function()
					return false
				end,
				close = function() end,
			}
		end,
		spawn = function(_, _, done)
			callback = done
			return {
				kill = function()
					killed = killed + 1
				end,
			}
		end,
	})
	renderer(false)
	presenter(log)
	local session = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "late" }))
	assert(timeout, "timeout callback was not scheduled")
	timeout()
	equal(1, killed, "timed out renderer was not killed")
	equal("error", session:status().state)
	assert(session:status().error:find("7 ms", 1, true), session:status().error)
	callback({ code = 0, stdout = "late output", stderr = "" })
	assert(log.delivered == nil, "late output reached the presenter")
	equal({}, vim.fn.glob(root .. "/*", false, true), "late output entered the cache")
end)

test("combined stdout and stderr obey the per-stage output ceiling", function()
	local log = {}
	setup({
		max_stage_output_bytes = 5,
		spawn = function(_, _, callback)
			callback({ code = 0, stdout = "123", stderr = "456" })
			return { kill = function() end }
		end,
	})
	renderer(false)
	presenter(log)
	local session = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "large" }))
	equal("error", session:status().state)
	assert(log.error:find("exceeds 5 bytes", 1, true), log.error)
	assert(log.delivered == nil)
end)

test("cache is private, reused, and rejects a symlink root", function()
	local root = cache_root()
	local runs = 0
	local log = {}
	setup({
		cache_root = root,
		spawn = function(_, _, callback)
			runs = runs + 1
			callback({ code = 0, stdout = "cached output", stderr = "" })
			return { kill = function() end }
		end,
	})
	renderer(false)
	presenter(log)
	local first = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "same" }))
	local path = assert(first:status().result.path)
	local root_info = assert(vim.uv.fs_stat(root))
	local file_info = assert(vim.uv.fs_stat(path))
	equal(448, bit.band(root_info.mode, 511), "cache root mode")
	equal(384, bit.band(file_info.mode, 511), "cache file mode")
	local second_log = {}
	presenter(second_log)
	local second = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "same" }))
	equal(1, runs, "cache hit started another process")
	equal(true, second:status().result.cached)
	equal({ "test", "cached output", true }, second_log.delivered)

	local external = vim.fs.dirname(root) .. "/external.txt"
	assert(vim.fn.writefile({ "hostile" }, external) == 0)
	assert(vim.uv.fs_unlink(path))
	assert(vim.uv.fs_symlink(external, path))
	local entry_log = {}
	presenter(entry_log)
	local bad_entry = assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "same" }))
	equal("error", bad_entry:status().state)
	assert(entry_log.error:find("regular file", 1, true), entry_log.error)
	equal(1, runs, "symlink cache entry started a process")

	local symlink_parent = vim.fn.tempname()
	assert(vim.fn.mkdir(symlink_parent, "p") == 1)
	temporary[#temporary + 1] = symlink_parent
	local real = symlink_parent .. "/real"
	assert(vim.fn.mkdir(real, "p") == 1)
	local linked = symlink_parent .. "/linked"
	assert(vim.uv.fs_symlink(real, linked))
	setup({
		cache_root = linked,
		spawn = function()
			error("symlink cache must not spawn")
		end,
	})
	renderer(false)
	local symlink_log = {}
	presenter(symlink_log)
	local rejected =
		assert(diagram.open({ renderer = "test", presenter = "test", kind = "mermaid", source = "unsafe" }))
	equal("error", rejected:status().state)
	assert(symlink_log.error:find("real directory", 1, true), symlink_log.error)
end)

test("conditional cache cleanup never removes a same-key fresh publication", function()
	local root = cache_root()
	assert(cache.setup({ root = root, max_age_seconds = 1, max_bytes = 1024 }))
	local path = assert(cache.write("same-key", "txt", "stale"))
	local data, read_err, invalid_path, identity = cache.read("same-key", "txt", function()
		return false
	end)
	assert(data == nil and read_err and invalid_path == path and identity, "invalid cache identity was not returned")
	local published = false
	cache._set_test_hook(function(event)
		if event == "after_cleanup_reserve" and not published then
			published = true
			assert(cache.write("same-key", "txt", "fresh"))
		end
	end)
	assert(cache.remove(path, identity))
	cache._set_test_hook(nil)
	equal("fresh", assert(cache.read("same-key", "txt")), "invalid-hit cleanup removed the fresh publication")

	local stale_path = assert(cache.write("prune-key", "txt", "old"))
	assert(vim.uv.fs_utime(stale_path, 1, 1))
	published = false
	cache._set_test_hook(function(event)
		if event == "after_cleanup_reserve" and not published then
			published = true
			assert(cache.write("prune-key", "txt", "new"))
		end
	end)
	assert(cache.prune())
	cache._set_test_hook(nil)
	equal("new", assert(cache.read("prune-key", "txt")), "prune removed the fresh same-key publication")
end)

test("failed process or presenter shutdown preserves session authority and rejects reconfiguration", function()
	local kill_fails = true
	local close_fails = true
	local root = cache_root()
	setup({
		cache_root = root,
		spawn = function()
			return {
				kill = function()
					if kill_fails then
						error("fixture kill failure")
					end
					return true
				end,
			}
		end,
	})
	renderer(false)
	assert(diagram.register_presenter("fragile", {
		open = function()
			return {}
		end,
		deliver = function() end,
		close = function()
			if close_fails then
				error("fixture close failure")
			end
			return true
		end,
	}))
	local session = assert(diagram.open({ renderer = "test", presenter = "fragile", kind = "text", source = "A" }))
	local before_config = diagram.effective_config()
	local configured, err = diagram.setup({ cache_root = cache_root() })
	assert(not configured and tostring(err):find("could not be stopped", 1, true), tostring(err))
	equal(before_config, diagram.effective_config(), "failed shutdown published candidate configuration")
	local status = diagram.status()
	equal(1, #status.sessions, "failed shutdown discarded session authority")
	equal({ "fragile" }, status.presenters, "failed shutdown reset presenter registry")

	kill_fails = false
	local cancelled, cancel_err = diagram.cancel(session, "retry")
	assert(not cancelled and tostring(cancel_err):find("could not be closed", 1, true), tostring(cancel_err))
	equal(1, #diagram.status().sessions, "presenter failure discarded session authority")
	close_fails = false
	assert(diagram.cancel(session, "retry"))
	equal(0, #diagram.status().sessions, "successful retry retained cancelled session")
end)

test("presenters are selected by name and renderer errors stay session-local", function()
	local logs = { first = {}, second = {} }
	setup({
		spawn = function(_, _, callback)
			callback({ code = 9, stdout = "", stderr = "bad source" })
			return { kill = function() end }
		end,
	})
	renderer(false)
	presenter(logs.first, "first")
	presenter(logs.second, "second")
	local session = assert(diagram.open({ renderer = "test", presenter = "second", kind = "mermaid", source = "bad" }))
	assert(logs.first.opened == nil)
	equal("mermaid", logs.second.opened)
	equal("bad source", logs.second.error)
	equal("error", session:status().state)
	equal({ "first", "second" }, diagram.status().presenters)
end)

test("repeated setup and teardown reset registries deterministically", function()
	setup({ default_mode = "ascii" })
	renderer(false)
	presenter({})
	local status = diagram.status()
	status.config.default_mode = "mutated"
	equal("ascii", diagram.status().config.default_mode, "status leaked config state")
	setup()
	equal({}, diagram.status().renderers, "repeated setup retained renderer registrations")
	equal({}, diagram.status().presenters, "repeated setup retained presenter registrations")
	assert(diagram.teardown())
	assert(diagram.teardown())
	assert(not diagram.status().configured)
	equal("svg", diagram.effective_config().default_mode)
end)

for _, path in ipairs(temporary) do
	vim.fn.delete(path, "rf")
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("diagram_view_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
