vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local cli = require("config.devcontainer_runtime_cli")
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
assert(vim.fn.mkdir(fixture, "p", tonumber("700", 8)) == 1)
local root = assert(vim.uv.fs_realpath(fixture))

test("prepare-up emits exactly one tab-delimited runtime line", function()
	local seen
	local output, err = cli.execute({ "prepare-up", root }, {
		prepare_up = function(actual)
			seen = actual
			return { cli_path = "/managed/devcontainer", docker_path = "/managed/podman" }
		end,
	})
	assert(err == nil and seen == root)
	assert(output == "/managed/devcontainer\t/managed/podman\n")
end)

test("preflight-record emits no output and uses the exact repository", function()
	local seen
	local output, err = cli.execute({ "preflight-record", root }, {
		preflight_record = function(actual)
			seen = actual
			return true
		end,
	})
	assert(err == nil and seen == root and output == "")
end)

test("adapter failures are preserved exactly", function()
	local output, err = cli.execute({ "prepare-up", root }, {
		prepare_up = function()
			return nil, "certified runtime is unavailable"
		end,
	})
	assert(output == nil and err == "certified runtime is unavailable")

	output, err = cli.execute({ "preflight-record", root }, {
		preflight_record = function()
			return nil, "recorded engine changed"
		end,
	})
	assert(output == nil and err == "recorded engine changed")
end)

test("commands and repositories are strict", function()
	for _, arguments in ipairs({
		{},
		{ "prepare-up" },
		{ "unknown", root },
		{ "prepare-up", "relative" },
		{ "prepare-up", root .. "\nother" },
		{ "prepare-up", root, "extra" },
	}) do
		local output = cli.execute(arguments, {})
		assert(output == nil, "invalid arguments were accepted: " .. vim.inspect(arguments))
	end
end)

test("runtime output rejects missing relative or control-bearing paths", function()
	for _, runtime in ipairs({
		{},
		{ cli_path = "devcontainer", docker_path = "/managed/podman" },
		{ cli_path = "/managed/devcontainer", docker_path = "podman" },
		{ cli_path = "/managed/devcontainer\nother", docker_path = "/managed/podman" },
		{ cli_path = "/managed/devcontainer", docker_path = "/managed/podman\tother" },
	}) do
		local output = cli.execute({ "prepare-up", root }, {
			prepare_up = function()
				return runtime
			end,
		})
		assert(output == nil, "invalid runtime was emitted: " .. vim.inspect(runtime))
	end
end)

test("adapter exceptions and missing methods fail closed", function()
	local output, err = cli.execute({ "prepare-up", root }, {
		prepare_up = function()
			error("resolver exploded")
		end,
	})
	assert(output == nil and err:find("resolver exploded", 1, true))
	output, err = cli.execute({ "preflight-record", root }, {})
	assert(output == nil and err:find("does not implement preflight_record", 1, true))
end)

vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(string.format("devcontainer_runtime_spec: %d tests passed", count))
vim.cmd("quitall!")
