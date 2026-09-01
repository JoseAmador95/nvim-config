vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
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

local expected = {
	"native-review.nvim",
	"exact-editor.nvim",
	"devcontainer-editor.nvim",
	"tab-first.nvim",
	"terminal-lifecycle.nvim",
	"project-python.nvim",
	"action-palette.nvim",
	"diagram-view.nvim",
	"log-workbench.nvim",
	"repo-scratch.nvim",
	"coverage-workbench.nvim",
	"just-workbench.nvim",
	"clangd-compile-db.nvim",
	"trusted-workspace.nvim",
	"verified-tools.nvim",
	"treesitter-runtime.nvim",
	"theme-router.nvim",
}
local support = { "_shared" }
local local_root = vim.fs.joinpath(repo, "local-plugins")
local modules = {
	["native-review.nvim"] = "native_review",
	["exact-editor.nvim"] = "exact_editor",
	["devcontainer-editor.nvim"] = "devcontainer_editor",
	["tab-first.nvim"] = "tab_first",
	["terminal-lifecycle.nvim"] = "terminal_lifecycle",
	["project-python.nvim"] = "project_python",
	["action-palette.nvim"] = "action_palette",
	["diagram-view.nvim"] = "diagram_view",
	["log-workbench.nvim"] = "log_workbench",
	["repo-scratch.nvim"] = "repo_scratch",
	["coverage-workbench.nvim"] = "coverage_workbench",
	["just-workbench.nvim"] = "just_workbench",
	["clangd-compile-db.nvim"] = "clangd_compile_db",
	["trusted-workspace.nvim"] = "trusted_workspace",
	["verified-tools.nvim"] = "verified_tools",
	["treesitter-runtime.nvim"] = "treesitter_runtime",
	["theme-router.nvim"] = "theme_router",
}

test("local plugin inventory and README boundaries are exact", function()
	local actual = {}
	for name, kind in vim.fs.dir(local_root) do
		if kind == "directory" then
			actual[#actual + 1] = name
		end
	end
	local sorted_expected = vim.list_extend(vim.deepcopy(expected), support)
	table.sort(actual)
	table.sort(sorted_expected)
	equal(sorted_expected, actual, "local plugin directory set drifted")
	equal(expected, require("config.local_plugins").names(), "harness order drifted")
	for _, name in ipairs(sorted_expected) do
		local readme = vim.fs.joinpath(local_root, name, "README.md")
		assert(vim.fn.filereadable(readme) == 1, name .. " has no README")
		local contents = table.concat(vim.fn.readfile(readme), "\n")
		assert(contents:find("Boundary:", 1, true), name .. " README does not identify its boundary")
	end
end)

test("runtimepath harness loads local boundaries early and deterministically", function()
	local init = table.concat(vim.fn.readfile(vim.fs.joinpath(repo, "init.lua")), "\n")
	local harness_call = assert(init:find('require("config.local_plugins").setup()', 1, true))
	local first_host_require = assert(init:find('require("config.local_config").apply_env()', 1, true))
	assert(harness_call < first_host_require, "local plugin harness is not loaded before host modules")

	local harness = require("config.local_plugins")
	local paths = harness.setup()
	assert(#paths == 17, "runtimepath harness must expose exactly 17 products")
	assert(not vim.tbl_contains(paths, vim.fs.joinpath(local_root, "_shared")), "shared library became a runtime")
	assert(harness.shared_lua() == vim.fs.joinpath(local_root, "_shared", "lua"))
	local runtimepath = vim.opt.runtimepath:get()
	for index, path in ipairs(paths) do
		equal(path, runtimepath[index], "local runtimepath order drifted at " .. expected[index])
	end
	equal(paths, harness.setup(), "repeated harness setup changed the canonical paths")
end)

test("local plugin runtime Lua has no host imports or global commands", function()
	local files = vim.fn.globpath(local_root, "*/lua/**/*.lua", false, true)
	assert(#files > 0, "shared contracts module is missing")
	for _, path in ipairs(files) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(
			not contents:match([=[require%s*%(%s*["']config[%.'"]]=])
				and not contents:match([=[require%s+["']config[%.'"]]=])
				and not contents:match([=[require%s*,%s*["']config[%.'"]]=]),
			path .. " imports host config"
		)
		assert(not contents:find("nvim_create_user_command", 1, true), path .. " creates a global user command")
	end
end)

test("every product exposes pure copied status and effective configuration", function()
	for _, name in ipairs(expected) do
		local plugin = require(assert(modules[name], "missing module mapping for " .. name))
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
end)

test("unknown setup options fail before changing product state", function()
	for _, name in ipairs(expected) do
		local plugin = require(modules[name])
		local before = plugin.status()
		local called, result = pcall(plugin.setup, { __unknown_contract_option = true })
		assert(not called or result == nil, name .. " accepted an unknown setup option")
		equal(before, plugin.status(), name .. " mutated state before rejecting an unknown setup option")
	end
end)

test("local plugins never acquire lazy lockfile entries", function()
	local lock = vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(repo, "lazy-lock.json")), "\n"))
	for _, name in ipairs(expected) do
		assert(lock[name] == nil, name .. " unexpectedly has a lazy lockfile entry")
	end
end)

test("shared workspace and action contracts validate and copy values", function()
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
end)

test("Snapshot recursively copies value and validity", function()
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
end)

test("TerminalSpec validates launch data and returns independent tables", function()
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
end)

test("ToolIdentity requires every exact scalar and an absolute install root", function()
	local contracts = require("local_plugins.contracts")
	local identity = assert(contracts.normalize_tool_identity({
		backend = "release",
		name = "plantuml",
		version = "1.2026.6",
		target = "darwin-arm64",
		digest = "sha256:fixture",
		install_root = "/managed/tools",
	}))
	assert(identity.name == "plantuml" and identity.install_root == "/managed/tools")
	assert(not contracts.normalize_tool_identity({
		backend = "release",
		name = "plantuml",
		version = "1.2026.6",
		target = "darwin-arm64",
		digest = "sha256:fixture",
		install_root = "relative",
	}))
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("local_plugins_spec: %d tests passed", count))
vim.cmd("quitall!")
