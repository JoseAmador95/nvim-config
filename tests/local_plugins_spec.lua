vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local T = MiniTest.new_set()

local equal = require("tests.helpers").equal

local harness = require("config.local_plugins")
local products = harness.products()

T["local runtimes are registered once and stay independently loadable"] = function()
	local paths = harness.setup()
	local registered = vim.opt.runtimepath:get()
	assert(#paths > 0, "no local products were registered")
	for _, path in ipairs(paths) do
		local count = 0
		for _, entry in ipairs(registered) do
			count = count + (entry == path and 1 or 0)
		end
		assert(count == 1, "runtime is missing or duplicated: " .. path)
	end
	equal(paths, harness.setup(), "repeated setup changed runtime paths")
	equal(registered, vim.opt.runtimepath:get(), "repeated setup duplicated runtimes")
	local names = harness.names()
	names[1] = "changed"
	assert(harness.names()[1] ~= "changed", "inventory shares mutable state")

	local original_require = require
	local original_command = vim.api.nvim_create_user_command
	_G.require = function(name)
		assert(not name:match("^config[%.]"), "local product imported host module " .. name)
		return original_require(name)
	end
	vim.api.nvim_create_user_command = function(name)
		error("local product registered global command " .. name)
	end
	local ok, err = xpcall(function()
		for _, product in ipairs(products) do
			assert(type(require(product.module)) == "table", product.name .. " is not independently loadable")
		end
	end, debug.traceback)
	_G.require = original_require
	vim.api.nvim_create_user_command = original_command
	assert(ok, err)
end

T["every product exposes pure copied status and effective configuration"] = function()
	for _, product in ipairs(products) do
		local name = product.name
		local plugin = require(product.module)
		assert(type(plugin.setup) == "function", name .. " has no setup()")
		assert(type(plugin.status) == "function", name .. " has no status()")
		assert(type(plugin.effective_config) == "function", name .. " has no effective_config()")

		local first_status = plugin.status()
		local first_config = plugin.effective_config()
		assert(type(first_status) == "table", name .. " status() did not return a table")
		assert(type(first_config) == "table", name .. " effective_config() did not return a table")
		first_status.__mutation_probe = true
		first_config.__mutation_probe = true
		assert(plugin.status().__mutation_probe == nil, name .. " status() shares mutable state")
		assert(plugin.effective_config().__mutation_probe == nil, name .. " effective_config() shares mutable state")
	end
end

T["unknown setup options fail before changing product state"] = function()
	for _, product in ipairs(products) do
		local name = product.name
		local plugin = require(product.module)
		local before = plugin.status()
		local called, result = pcall(plugin.setup, { __unknown_contract_option = true })
		assert(not called or result == nil, name .. " accepted an unknown setup option")
		equal(before, plugin.status(), name .. " mutated state before rejecting an unknown setup option")
	end
end

T["local plugins never acquire lazy lockfile entries"] = function()
	local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(repo, "lazy-lock.json")), "\n"))
	for _, product in ipairs(products) do
		local name = product.name
		assert(lock[name] == nil, name .. " unexpectedly has a lazy lockfile entry")
	end
end

T["shared workspace and action contracts validate and copy values"] = function()
	local contracts = require("local_plugins.contracts")
	local workspace = assert(contracts.normalize_workspace_key({
		runtime = "host",
		root = "/repo",
		repo_identity = "origin:example/repo",
	}))
	equal({ runtime = "host", root = "/repo", repo_identity = "origin:example/repo" }, workspace, "WorkspaceKey")
	assert(not contracts.normalize_workspace_key({ runtime = "host", root = "relative", repo_identity = "repo" }))

	local cursor = { line = 7, col = 3 }
	local target = assert(contracts.normalize_action_target({
		bufnr = 1,
		winid = 2,
		tabpage = 3,
		cursor = cursor,
		changedtick = 4,
	}))
	cursor.line = 99
	equal({ line = 7, col = 3 }, target.cursor, "ActionTarget cursor was not copied")
	assert(not contracts.normalize_action_target({
		bufnr = 1,
		winid = 2,
		tabpage = 3,
		cursor = { line = 1, col = 0 },
		changedtick = 4,
		injected = true,
	}))
end

T["Snapshot recursively copies value and validity"] = function()
	local contracts = require("local_plugins.contracts")
	local input = {
		generation = 2,
		source = "project",
		validity = { valid = true, errors = {} },
		value = { nested = { label = "original" } },
	}
	local snapshot = assert(contracts.normalize_snapshot(input))
	input.validity.errors[1] = "late"
	input.value.nested.label = "changed"
	assert(#snapshot.validity.errors == 0, "Snapshot validity shares input tables")
	assert(snapshot.value.nested.label == "original", "Snapshot value shares input tables")

	local second = assert(contracts.normalize_snapshot(snapshot))
	second.value.nested.label = "second"
	assert(snapshot.value.nested.label == "original", "normalized Snapshots share nested tables")
	assert(not contracts.normalize_snapshot({ generation = -1, source = "host", validity = true, value = {} }))
end

T["TerminalSpec validates launch data and returns independent tables"] = function()
	local contracts = require("local_plugins.contracts")
	local input = {
		key = '["host","/repo","shell"]',
		launch = { argv = { "/bin/sh", "-c", "" }, cwd = "/repo", env = { TERM = "xterm" } },
		policy = { dispose_on_success = true },
		view = { layout = "bottom" },
		metadata = { owner = { name = "host" } },
	}
	local spec = assert(contracts.normalize_terminal_spec(input))
	input.key = "changed"
	input.launch.argv[1] = "changed"
	input.policy.dispose_on_success = false
	input.metadata.owner.name = "changed"
	assert(spec.key == '["host","/repo","shell"]', "TerminalSpec key changed")
	assert(spec.launch.argv[1] == "/bin/sh", "TerminalSpec argv was not copied")
	assert(spec.launch.argv[3] == "", "TerminalSpec dropped an empty argument")
	assert(spec.policy.dispose_on_success == true, "TerminalSpec policy was not copied")
	assert(spec.metadata.owner.name == "host", "TerminalSpec metadata was not copied")
	local invalid_program = vim.deepcopy(spec)
	invalid_program.launch.argv[1] = ""
	assert(not contracts.normalize_terminal_spec(invalid_program))
	local invalid_argument = vim.deepcopy(spec)
	invalid_argument.launch.argv[2] = "bad\0value"
	assert(not contracts.normalize_terminal_spec(invalid_argument))
	assert(not contracts.normalize_terminal_spec(vim.tbl_deep_extend("force", {}, input, {
		launch = { argv = {}, cwd = "/repo", env = {} },
	})))
	assert(not contracts.normalize_terminal_spec(vim.tbl_deep_extend("force", {}, input, { key = { id = "shell" } })))
end

return T
