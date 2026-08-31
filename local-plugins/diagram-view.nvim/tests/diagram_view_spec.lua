vim.o.shadafile = "NONE"
vim.o.swapfile = false

local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({ plugin .. "/lua/?.lua", plugin .. "/lua/?/init.lua", package.path }, ";")

local diagram = require("diagram_view")
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
		spawn = opts.spawn,
		schedule = opts.schedule or function(callback)
			callback()
		end,
		plantuml_policy = opts.plantuml_policy,
		notify = opts.notify,
		event = opts.event,
	})
	assert(ok, err)
end

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
