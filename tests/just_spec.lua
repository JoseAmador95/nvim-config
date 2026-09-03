vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/just-workbench.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/src", "p")
vim.fn.writefile({ "build name:", "  @echo {{name}}" }, fixture .. "/justfile")
vim.fn.writefile({ "int main(void) { return 0; }" }, fixture .. "/src/main.c")
vim.fn.system({ "git", "init", "-q", fixture })
assert(vim.v.shell_error == 0)
fixture = assert(vim.uv.fs_realpath(fixture))
local just_bin = fixture .. "/bin/just"
vim.fn.mkdir(vim.fs.dirname(just_bin), "p")
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, just_bin)
assert(vim.uv.fs_chmod(just_bin, tonumber("700", 8)))
vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/main.c"))

local original_executable = vim.fn.executable
local original_exepath = vim.fn.exepath
local original_secure_read = vim.secure.read
local original_terminal = package.loaded["config.terminal"]
local original_local_config = package.loaded["config.local_config"]
local original_input = vim.ui.input
local original_select = vim.ui.select
local original_schedule = vim.schedule
local original_notify = vim.notify
local policy_overrides = {}

local executed
local restarted
local focused = 0
local status_by_key = {}
local terminal_lines = {}
package.loaded["config.terminal"] = {
	open = function(spec)
		executed = vim.deepcopy(spec)
		status_by_key[spec.key] = { state = "running", exists = true }
		return { spec = spec }
	end,
	restart = function(spec)
		restarted = vim.deepcopy(spec)
		status_by_key[spec.key] = { state = "running", exists = true }
		return { spec = spec }
	end,
	focus = function(identity)
		assert(type(identity) == "string", "Just focus did not use the stable terminal key")
		focused = focused + 1
		return { key = identity }
	end,
	status = function(key)
		return vim.deepcopy(status_by_key[key] or { state = "disposed", exists = false })
	end,
	lines = function()
		return terminal_lines
	end,
	stop = function(key)
		status_by_key[key] = { state = "disposed", exists = false }
		return true
	end,
}
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "just_workbench")
		assert(defaults.binary == "just" and defaults.root_mode == "repo" and defaults.conflict == "prompt")
		assert(vim.deep_equal(defaults.justfile_names, { "justfile", "Justfile", ".justfile" }))
		return vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(policy_overrides))
	end,
}
vim.fn.executable = function(name)
	return name == "just" and 1 or original_executable(name)
end
vim.fn.exepath = function(name)
	return name == "just" and just_bin or original_exepath(name)
end
vim.secure.read = function(path)
	return (path == fixture .. "/justfile" or path == fixture .. "/src/Justfile")
			and table.concat(vim.fn.readfile(path), "\n") .. "\n"
		or nil
end
vim.schedule = function(callback)
	callback()
end
local notices = {}
vim.notify = function(message, level)
	notices[#notices + 1] = { message = message, level = level }
end

local just = require("config.just")
assert(package.loaded.just_workbench == nil, "loading the host Just adapter initialized just-workbench")
local system_calls = {}
just._configure({
	system = function(argv, options, callback)
		system_calls[#system_calls + 1] = vim.deepcopy(argv)
		assert(options.text == true)
		callback({
			code = 0,
			stdout = vim.json.encode({
				recipes = { build = { parameters = { { name = "name", kind = "singular" } } } },
				aliases = {},
				modules = {},
			}),
			stderr = "",
		})
		return { pid = #system_calls }
	end,
	supports_one = function(binary)
		assert(binary == just_bin)
		return false
	end,
})
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

local function dump(recipes, aliases, modules)
	return {
		code = 0,
		stdout = vim.json.encode({ recipes = recipes, aliases = aliases or {}, modules = modules or {} }),
		stderr = "",
	}
end

test("host adapter catalogs structured recipes aliases and modules", function()
	local decoded = assert(just._decode_dump(dump({
		build = { doc = "Build target", parameters = { { name = "name", kind = "singular" } } },
		clean = { parameters = {} },
	}, { b = { target = "build" } }, {
		tools = { recipes = { lint = { parameters = {} } }, aliases = {}, modules = {} },
	})))
	local names = {}
	for _, action in ipairs(decoded.actions) do
		names[#names + 1] = action.name
	end
	assert(vim.deep_equal(names, { "b", "build", "clean", "tools::lint" }))
	assert(decoded.actions[2].parameters[1].kind == "singular")
	assert(just._decode_dump({ code = 0, stdout = '{"recipes":{"bad":{"parameters":[{}]}}}' }) == nil)
end)

test("trusted parameters remain literal terminal argv entries", function()
	local unsafe = "name; touch /tmp/never"
	vim.ui.input = function(_, callback)
		callback(unsafe)
	end
	just.run("build")
	assert(vim.deep_equal(system_calls[1], {
		just_bin,
		"--dump",
		"--dump-format",
		"json",
		"--justfile",
		fixture .. "/justfile",
		"--working-directory",
		fixture,
	}))
	assert(executed and executed.launch.argv[#executed.launch.argv] == unsafe)
	assert(executed.view.layout == "bottom" and executed.metadata.runtime == "host")
	assert(vim.deep_equal(vim.list_slice(executed.launch.argv, 1, 7), {
		just_bin,
		"--justfile",
		fixture .. "/justfile",
		"--working-directory",
		fixture,
		"build",
		unsafe,
	}))
end)

test("nearest root mode uses the closest justfile inside the repository", function()
	local nested = fixture .. "/src/Justfile"
	assert(vim.fn.writefile({ "build name:", "  @echo {{name}}" }, nested) == 0)
	policy_overrides.root_mode = "nearest"
	just.run("build")
	local catalog_argv = system_calls[#system_calls]
	assert(catalog_argv[6] == nested and catalog_argv[8] == fixture .. "/src")
	assert(executed.launch.cwd == fixture .. "/src" and executed.metadata.task_root == fixture .. "/src")
	policy_overrides.root_mode = nil
	vim.fn.delete(nested)
end)

test("second host run presents focus replace cancel and never replaces implicitly", function()
	local selection
	vim.ui.select = function(items, _, callback)
		selection = vim.deepcopy(items)
		callback(nil)
	end
	just.run("build")
	assert(#selection == 3)
	assert(selection[1].value == "focus" and selection[2].value == "replace" and selection[3].value == "cancel")
	assert(restarted == nil, "dismissing the prompt replaced a running process")
	vim.ui.select = function(items, _, callback)
		callback(items[1])
	end
	just.run("build")
	assert(focused == 1 and restarted == nil, "focus reused the newly requested launch")

	vim.ui.select = function(items, _, callback)
		callback(items[2])
	end
	just.run("build")
	assert(restarted and restarted.metadata.recipe == "build")
	assert(focused == 1)
end)

test("configured conflict policy executes without an inert prompt", function()
	local before = focused
	policy_overrides.conflict = "focus"
	vim.ui.select = function()
		error("configured focus policy opened a prompt")
	end
	just.run("build")
	assert(focused == before + 1, "configured focus policy was ignored")
	policy_overrides.conflict = nil
end)

test("location import remains bounded to existing repository files", function()
	local outside = vim.fn.tempname()
	vim.fn.writefile({ "outside" }, outside)
	local locations = just.parse_locations(fixture, {
		"src/main.c:1:4: compile error",
		"\27[31msrc/main.c:1: warning\27[0m",
		outside .. ":1: escape",
		"missing.c:2: absent",
	})
	assert(#locations == 2)
	assert(locations[1].filename == fixture .. "/src/main.c" and locations[1].col == 4)
	assert(locations[2].filename == fixture .. "/src/main.c" and locations[2].col == 1)
	vim.fn.delete(outside)

	terminal_lines = { "src/main.c:1:4: compile error", "noise" }
	local trouble_opened = false
	vim.api.nvim_create_user_command("Trouble", function()
		trouble_opened = true
	end, { nargs = "*" })
	just.import_last()
	local qf = vim.fn.getqflist({ title = 1, items = 1 })
	assert(qf.title == "Just output" and #qf.items == 1 and trouble_opened)
	vim.api.nvim_del_user_command("Trouble")
end)

test("global command surface remains host-owned", function()
	just.setup()
	for _, name in ipairs({ "JustRun", "JustImportLast", "JustRefresh", "JustTranscript", "JustStop" }) do
		assert(vim.fn.exists(":" .. name) == 2, "missing command " .. name)
	end
	local plugin_lua = table.concat(vim.fn.glob(plugin .. "/lua/**/*.lua", false, true), "\n")
	assert(plugin_lua ~= "")
	for _, path in ipairs(vim.split(plugin_lua, "\n", { trimempty = true })) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(not contents:find("nvim_create_user_command", 1, true))
		assert(not contents:match([=[require%s*%(%s*["']config[%.'"]]=]))
	end
	for _, name in ipairs({ "JustRun", "JustImportLast", "JustRefresh", "JustTranscript", "JustStop" }) do
		vim.api.nvim_del_user_command(name)
	end
end)

package.loaded["config.terminal"] = original_terminal
package.loaded["config.local_config"] = original_local_config
vim.fn.executable = original_executable
vim.fn.exepath = original_exepath
vim.secure.read = original_secure_read
vim.ui.input = original_input
vim.ui.select = original_select
vim.schedule = original_schedule
vim.notify = original_notify
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("just_spec: %d tests passed", count))
vim.cmd("quitall!")
