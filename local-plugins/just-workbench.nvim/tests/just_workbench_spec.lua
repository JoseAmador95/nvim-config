vim.o.shadafile = "NONE"
vim.o.swapfile = false

local script = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local plugin_root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({ plugin_root .. "/lua/?.lua", plugin_root .. "/lua/?/init.lua", package.path }, ";")

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

local function write(path, lines)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	assert(vim.fn.writefile(lines, path) == 0)
end

local fixture = vim.fn.tempname()
local root = fixture .. "/repo"
local external = fixture .. "/shared/external.just"
local module = root .. "/modules/jobs.just"
local just_bin = fixture .. "/bin/just"
vim.fn.mkdir(root, "p")
write(just_bin, { "#!/bin/sh", "exit 0" })
assert(vim.uv.fs_chmod(just_bin, tonumber("755", 8)))
write(root .. "/justfile", {
	"import '../shared/external.just'",
	"mod jobs 'modules/jobs.just'",
	"build target:",
	"  echo {{target}}",
})
write(external, { "shared:", "  echo shared" })
write(module, { "lint:", "  echo lint" })
root = assert(vim.uv.fs_realpath(root))
external = assert(vim.uv.fs_realpath(external))
module = assert(vim.uv.fs_realpath(module))
just_bin = assert(vim.uv.fs_realpath(just_bin))
local justfile = root .. "/justfile"

local workbench = require("just_workbench")
local dump = {
	code = 0,
	stderr = "",
	stdout = vim.json.encode({
		recipes = {
			build = { doc = "Build target", parameters = { { name = "target", kind = "singular" } } },
			shared = { parameters = {} },
		},
		aliases = { b = { target = "build", doc = "Build alias" } },
		modules = {
			jobs = {
				doc = "Job recipes",
				recipes = { lint = { parameters = { { name = "flags", kind = "star" } } } },
				aliases = { check = { target = "lint" } },
				modules = {},
			},
		},
	}),
}

local trusted = {}
local calls = {}
local states = {}
local opened = {}
local focused = 0
local replaced = 0
local transcript_lines = { "src/main.c:3:2: failure" }

local function setup(overrides)
	overrides = overrides or {}
	workbench._reset()
	trusted = {}
	calls = {}
	states = {}
	opened = {}
	focused = 0
	replaced = 0
	workbench.setup({
		system = overrides.system or function(argv, opts, callback)
			calls[#calls + 1] = vim.deepcopy(argv)
			assert(opts.text == true)
			callback(vim.deepcopy(dump))
			return { pid = 1 }
		end,
		trust = overrides.trust or function(path, contents, digest)
			trusted[path] = { contents = contents, digest = digest }
			return true
		end,
		hash = vim.fn.sha256,
		home = fixture,
		now = function()
			return 42
		end,
		schedule = overrides.schedule or function(callback)
			callback()
		end,
		supports_one = overrides.supports_one or function()
			return false
		end,
		event = overrides.event,
		terminal = {
			status = function(key)
				return vim.deepcopy(states[key] or { state = "disposed", exists = false })
			end,
			open = function(spec)
				opened[#opened + 1] = vim.deepcopy(spec)
				states[spec.key] = { state = "running", exists = true }
				return { key = spec.key }
			end,
			focus = function(identity)
				assert(type(identity) == "string", "focus received a requested launch instead of the existing key")
				focused = focused + 1
				return { key = identity }
			end,
			replace = function(spec)
				replaced = replaced + 1
				opened[#opened + 1] = vim.deepcopy(spec)
				states[spec.key] = { state = "running", exists = true }
				return { key = spec.key }
			end,
			lines = function()
				return vim.deepcopy(transcript_lines)
			end,
			stop = function(key)
				states[key] = { state = "disposed", exists = false }
				return true
			end,
		},
	})
end

local function catalog_sync()
	local result
	local err
	local handle, start_err = workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function(value, callback_err)
		result = value
		err = callback_err
	end)
	assert(handle, start_err)
	return assert(result, err)
end

test("pre-setup public config and aggregate status are copied", function()
	local first = workbench.effective_config()
	assert(vim.tbl_isempty(first) and pcall(vim.json.encode, first))
	first.injected = true
	assert(workbench.effective_config().injected == nil)

	local status = workbench.status()
	assert(status.configured == false and vim.tbl_isempty(status.catalogs))
	status.configured = true
	assert(workbench.status().configured == false)
end)

test("closure authorizes root, external import, and explicit module by content", function()
	setup()
	local catalog = catalog_sync()
	assert(trusted[justfile] and trusted[external] and trusted[module])
	assert(#catalog.closure.entries == 3)
	assert(#catalog.closure.imports == 1 and catalog.closure.imports[1].path == external)
	assert(#catalog.closure.modules == 1 and catalog.closure.modules[1].path == module)
	assert(vim.deep_equal(calls[1], {
		just_bin,
		"--dump",
		"--dump-format",
		"json",
		"--justfile",
		justfile,
		"--working-directory",
		root,
	}))
end)

test("catalog includes recipes aliases modules and parameters as caller-owned copies", function()
	setup()
	local catalog = catalog_sync()
	local names = {}
	for _, action in ipairs(catalog.actions) do
		names[#names + 1] = action.name
	end
	assert(vim.deep_equal(names, { "b", "build", "jobs::check", "jobs::lint", "shared" }))
	assert(catalog.actions[1].parameters[1].name == "target")
	assert(catalog.actions[2].parameters[1].name == "target")
	assert(catalog.actions[3].parameters[1].name == "flags")
	assert(catalog.modules[1].name == "jobs")
	catalog.actions[2].parameters[1].name = "mutated"
	local result = assert(workbench.run(catalog, "build", { "safe" }))
	assert(result.outcome == "started")
	assert(opened[1].metadata.recipe == "build")
end)

test("changed closure fails closed between authorization and execution", function()
	setup()
	local catalog = catalog_sync()
	write(external, { "shared:", "  echo changed" })
	local result, err = workbench.run(catalog, "build", { "target" })
	assert(result == nil and tostring(err):find("closure changed", 1, true))
	assert(#opened == 0, "TOCTOU failure launched a terminal")
	write(external, { "shared:", "  echo shared" })
end)

test("empty recipe values remain exact terminal argv entries", function()
	setup()
	local catalog = catalog_sync()
	local result = assert(workbench.run(catalog, "build", { "" }))
	assert(result.outcome == "started")
	assert(opened[1].launch.argv[#opened[1].launch.argv] == "", "empty recipe value was dropped")
end)

test("closure drift permits conflict focus and cancel but blocks replace", function()
	setup()
	local catalog = catalog_sync()
	local unsafe = "name; touch /tmp/never"
	local first = assert(workbench.run(catalog, "build", { unsafe }))
	assert(first.outcome == "started")
	assert(opened[1].launch.argv[#opened[1].launch.argv] == unsafe)
	write(external, { "shared:", "  echo changed" })

	local second, conflict = workbench.run(catalog, "build", { "other" })
	assert(second == nil and conflict.kind == "conflict")
	assert(vim.deep_equal(conflict.choices, { "focus", "replace", "cancel" }))
	assert(replaced == 0, "second run killed the first silently")
	assert(workbench.run(catalog, "build", {}, { decision = "cancel" }).outcome == "cancelled")
	assert(replaced == 0)
	assert(workbench.run(catalog, "build", {}, { decision = "focus" }).outcome == "focused")
	assert(focused == 1 and replaced == 0)
	local replacement, replacement_err = workbench.run(catalog, "build", { "new" }, { decision = "replace" })
	assert(replacement == nil and tostring(replacement_err):find("closure changed", 1, true))
	assert(replaced == 0, "closure drift replaced the existing execution")
	write(external, { "shared:", "  echo shared" })
	assert(workbench.run(catalog, "build", { "new" }, { decision = "replace" }).outcome == "replaced")
	assert(replaced == 1)

	local transcript = assert(workbench.transcript({ runtime = "host", task_root = root }))
	assert(transcript.recipe == "build" and transcript.started_at == 42)
	assert(vim.deep_equal(transcript.lines, transcript_lines))
	transcript.lines[1] = "mutated"
	assert(workbench.transcript({ runtime = "host", task_root = root }).lines[1] == transcript_lines[1])
	assert(not workbench.transcript({ runtime = "container", task_root = root }))
end)

test("catalog concurrency rejects stale completion and format operations are non-mutating", function()
	local pending = {}
	setup({
		system = function(argv, _, callback)
			pending[#pending + 1] = { argv = vim.deepcopy(argv), callback = callback }
			return { pid = #pending }
		end,
	})
	local first_error
	local second_catalog
	assert(workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function(_, err)
		first_error = err
	end))
	assert(workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function(value)
		second_catalog = value
	end))
	pending[1].callback(vim.deepcopy(dump))
	assert(first_error == "catalog request was superseded")
	pending[2].callback(vim.deepcopy(dump))
	assert(second_catalog)

	local checked
	assert(workbench.format(second_catalog, "check", function(result)
		checked = result
	end))
	local format_argv = pending[3].argv
	assert(format_argv[#format_argv - 1] == "--fmt" and format_argv[#format_argv] == "--check")
	pending[3].callback({ code = 0, stdout = "", stderr = "" })
	assert(checked and checked.code == 0)
	assert(not workbench.format(second_catalog, "write", function() end))
end)

test("catalog callbacks cannot cross a teardown and setup generation", function()
	local pending = {}
	local function deferred_system(_, _, callback)
		pending[#pending + 1] = callback
		return { pid = #pending }
	end
	local spec = { runtime = "host", task_root = root, justfile = justfile, just_bin = just_bin }
	setup({ system = deferred_system })
	local old_value
	local old_error
	assert(workbench.catalog(spec, function(value, err)
		old_value = value
		old_error = err
	end))
	setup({ system = deferred_system })
	local new_value
	assert(workbench.catalog(spec, function(value)
		new_value = value
	end))
	assert(#pending == 2)
	pending[1](vim.deepcopy(dump))
	assert(old_value == nil and old_error == "catalog request was superseded")
	assert(vim.tbl_isempty(workbench.status().catalogs), "old lifecycle published a catalog into the new setup")
	pending[2](vim.deepcopy(dump))
	assert(new_value and not vim.tbl_isempty(workbench.status().catalogs))
end)

test("system completion is scheduled out of fast-event context", function()
	local scheduled
	setup({
		schedule = function(callback)
			scheduled = callback
		end,
	})
	local catalog
	assert(workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function(value)
		catalog = value
	end))
	assert(catalog == nil and type(scheduled) == "function")
	scheduled()
	assert(catalog and #catalog.actions == 5)
end)

test("untrusted and symlinked closure sources are rejected before dump", function()
	setup({
		trust = function(path)
			return path ~= external, "external source rejected"
		end,
	})
	local result, err = workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function() end)
	assert(result == nil and tostring(err):find("external source rejected", 1, true))
	assert(#calls == 0)

	setup()
	local symlink = fixture .. "/linked.just"
	assert(vim.uv.fs_symlink(external, symlink))
	write(root .. "/justfile", { "import '../linked.just'", "build:" })
	local linked, linked_err = workbench.catalog({
		runtime = "host",
		task_root = root,
		justfile = justfile,
		just_bin = just_bin,
	}, function() end)
	assert(linked == nil and tostring(linked_err):find("non%-symlink"))
	write(root .. "/justfile", {
		"import '../shared/external.just'",
		"mod jobs 'modules/jobs.just'",
		"build target:",
	})
end)

test("modern parameter cardinality and private modules are projected exactly", function()
	local decoded = assert(workbench._decode_dump({
		code = 0,
		stderr = "",
		stdout = vim.json.encode({
			recipes = {
				bounded = {
					parameters = {
						{
							name = "items",
							kind = "plus",
							min = 2,
							max = 4,
							help = "Exact items",
							long = "items",
							pattern = { "safe" },
							value = "literal",
						},
					},
				},
				plain = {
					parameters = {
						{ name = "value", kind = "singular", default = vim.NIL, min = vim.NIL, max = vim.NIL },
					},
				},
				_hidden = { parameters = {} },
			},
			aliases = { b = { target = "bounded" } },
			modules = {
				_hidden = { recipes = { leaked = { parameters = {} } } },
				secret = { attributes = { "private" }, recipes = { leaked = { parameters = {} } } },
			},
		}),
	}))
	assert(#decoded.actions == 3 and #decoded.modules == 0)
	for _, action in ipairs(decoded.actions) do
		if action.name == "plain" then
			assert(action.min_arguments == 1 and action.max_arguments == 1 and action.parameters[1].default == nil)
		else
			assert(action.min_arguments == 2 and action.max_arguments == 4)
			assert(action.parameters[1].help == "Exact items")
			assert(action.parameters[1].pattern[1] == "safe" and action.parameters[1].value == "literal")
		end
	end
end)

test("literal variadics and invocation-time one capability are preserved", function()
	local probes = 0
	setup({
		supports_one = function(binary)
			probes = probes + 1
			assert(binary == just_bin)
			return true
		end,
	})
	local catalog = catalog_sync()
	assert(probes == 0, "catalog discovery probed an execution-only capability")
	assert(workbench.run(catalog, "jobs::lint", { "--flag value" }))
	assert(probes == 1)
	assert(opened[1].launch.argv[2] == "--one")
	assert(opened[1].launch.argv[#opened[1].launch.argv] == "--flag value")
	assert(workbench.run(catalog, "jobs::lint", { "second literal" }, { decision = "replace" }))
	assert(probes == 1, "binary capability was not cached")
end)

test("setup rejects unknown keys transactionally and public snapshots are copied", function()
	local events = {}
	setup({
		event = function(event)
			events[#events + 1] = event
		end,
	})
	local before = assert(workbench.effective_config())
	assert(vim.tbl_isempty(before) and pcall(vim.json.encode, before))
	local ok, err = pcall(workbench.setup, { injected = true })
	assert(not ok and tostring(err):find("unknown key", 1, true))
	ok, err = pcall(workbench.setup, { home = 42 })
	assert(not ok and tostring(err):find("home must be", 1, true), "invalid home was accepted")
	ok = pcall(workbench.setup, false)
	assert(not ok, "false setup options were accepted")
	local after = assert(workbench.effective_config())
	assert(vim.tbl_isempty(after))
	after.injected = true
	assert(workbench.effective_config().injected == nil)
	local first = assert(workbench.status({ runtime = "host", task_root = root }))
	first.state = "mutated"
	assert(assert(workbench.status({ runtime = "host", task_root = root })).state ~= "mutated")
	local aggregate = workbench.status()
	assert(aggregate.configured == true)
	aggregate.configured = false
	assert(workbench.status().configured == true)
	assert(events[1].kind == "setup" and vim.tbl_isempty(events[1].config))
	assert(pcall(vim.json.encode, events[1].config))
	assert(workbench.teardown())
	assert(vim.tbl_isempty(workbench.effective_config()) and workbench.status().configured == false)
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("just_workbench_spec: %d tests passed", count))
vim.cmd("quitall!")
