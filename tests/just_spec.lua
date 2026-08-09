vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. "/src", "p")
vim.fn.writefile({ "build name:", "\t@echo {{name}}" }, fixture .. "/justfile")
vim.fn.writefile({ "int main(void) { return 0; }" }, fixture .. "/src/main.c")
vim.fn.system({ "git", "init", "-q", fixture })
assert(vim.v.shell_error == 0)
fixture = vim.uv.fs_realpath(fixture) or fixture
vim.cmd.edit(vim.fn.fnameescape(fixture .. "/src/main.c"))

local original_executable = vim.fn.executable
local original_secure_read = vim.secure.read
local original_terminal = package.loaded["config.terminal"]
local original_input = vim.ui.input
local original_schedule = vim.schedule
local original_notify = vim.notify

local executed
local terminal_lines = {}
package.loaded["config.terminal"] = {
	restart = function(spec)
		executed = vim.deepcopy(spec)
		return { spec = spec }
	end,
	lines = function()
		return terminal_lines
	end,
}
vim.fn.executable = function(name)
	return name == "just" and 1 or original_executable(name)
end
vim.secure.read = function(path)
	return path == fixture .. "/justfile" and table.concat(vim.fn.readfile(path), "\n") or nil
end
vim.schedule = function(callback)
	callback()
end
local notices = {}
vim.notify = function(message, level)
	notices[#notices + 1] = { message = message, level = level }
end

local just = require("config.just")
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

test("dump parser accepts structured recipes and rejects malformed parameters", function()
	local recipes = assert(just._decode_dump({
		code = 0,
		stdout = vim.json.encode({
			recipes = {
				build = { doc = "Build target", parameters = { { name = "name", kind = "singular" } } },
				clean = { parameters = {} },
			},
		}),
		stderr = "",
	}))
	assert(#recipes == 2 and recipes[1].name == "build" and recipes[2].name == "clean")
	assert(recipes[1].parameters[1].kind == "singular")
	assert(just._decode_dump({ code = 0, stdout = '{"recipes":{"bad":{"parameters":[{}]}}}' }) == nil)
end)

test("trusted recipe parameters remain literal argv entries", function()
	local unsafe = "name; touch /tmp/never"
	vim.ui.input = function(_, callback)
		callback(unsafe)
	end
	just.run("build", {
		system = function(argv, options, callback)
			assert(vim.deep_equal(argv, {
				"just",
				"--dump",
				"--dump-format",
				"json",
				"--justfile",
				fixture .. "/justfile",
				"--working-directory",
				fixture,
			}))
			assert(options.text == true)
			callback({
				code = 0,
				stdout = vim.json.encode({
					recipes = { build = { parameters = { { name = "name", kind = "singular" } } } },
				}),
				stderr = "",
			})
		end,
	})
	assert(executed and executed.argv[#executed.argv] == unsafe)
	assert(executed.layout == "bottom" and executed.runtime == "host" and executed.env ~= nil)
	assert(vim.deep_equal(vim.list_slice(executed.argv, 1, 7), {
		"just",
		"--justfile",
		fixture .. "/justfile",
		"--working-directory",
		fixture,
		"build",
		unsafe,
	}))
end)

test("official star and plus parameter kinds become literal argv tokens", function()
	local inputs = { "one two", "three four" }
	vim.ui.input = function(_, callback)
		callback(table.remove(inputs, 1))
	end
	just.run("many", {
		system = function(_, _, callback)
			callback({
				code = 0,
				stdout = vim.json.encode({
					recipes = {
						many = {
							parameters = {
								{ name = "optional", kind = "star" },
								{ name = "required", kind = "plus" },
							},
						},
					},
				}),
				stderr = "",
			})
		end,
	})
	assert(vim.deep_equal(vim.list_slice(executed.argv, 7), { "one", "two", "three", "four" }))
end)

test("location import is bounded to existing files in the same repository", function()
	local outside = vim.fn.tempname()
	vim.fn.writefile({ "outside" }, outside)
	local locations = just.parse_locations(fixture, {
		"src/main.c:1:4: compile error",
		"\27[31msrc/main.c:1: warning\27[0m",
		outside .. ":1: escape",
		"missing.c:2: absent",
		"not a location",
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

package.loaded["config.terminal"] = original_terminal
vim.fn.executable = original_executable
vim.secure.read = original_secure_read
vim.ui.input = original_input
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
