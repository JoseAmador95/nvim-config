vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
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

local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p", 448) == 1)
local config_path = vim.fs.joinpath(root, "host.lua")
local state_root = vim.fs.joinpath(root, "state")
assert(vim.fn.writefile({ "return {}" }, config_path) == 0)

local original_config = vim.env.NVIM_CONFIG_FILE
local original_state = vim.env.NVIM_CONFIG_TRUST_STATE_ROOT
local original_notify = vim.notify
vim.env.NVIM_CONFIG_FILE = config_path
vim.env.NVIM_CONFIG_TRUST_STATE_ROOT = state_root
vim.notify = function() end

package.loaded["config.local_config"] = nil
local local_config = require("config.local_config")

local plugin_names = {
	"native_review",
	"exact_editor",
	"devcontainer_editor",
	"tab_first",
	"terminal_lifecycle",
	"project_python",
	"action_palette",
	"diagram_view",
	"log_workbench",
	"repo_scratch",
	"coverage_workbench",
	"just_workbench",
	"clangd_compile_db",
	"trusted_workspace",
	"verified_tools",
	"treesitter_runtime",
	"theme_router",
}

test("canonical plugin schema exposes all products and host-only top-level values", function()
	local config = local_config.read()
	local actual = vim.tbl_keys(config.plugins)
	table.sort(actual)
	local expected = vim.deepcopy(plugin_names)
	table.sort(expected)
	equal(expected, actual, "canonical plugin inventory drifted")
	equal("inline", config.plugins.native_review.layout, "native review default changed")
	equal("workspace", config.plugins.tab_first.history.scope, "tab history is not workspace-scoped")
	equal(30000, config.plugins.diagram_view.stage_timeout_ms, "diagram timeout default changed")
	equal(5000, config.plugins.terminal_lifecycle.stop_timeout_ms, "terminal stop timeout default changed")
	equal(21600, config.plugins.exact_editor.registry_heartbeat_seconds, "exact editor heartbeat default changed")
	equal("auto", config.plugins.theme_router.background, "theme background default changed")
	equal("dap-ui", config.dap.ui, "DAP host configuration moved under plugins")
	equal("full", config.ui.redraw_profile, "redraw profile default changed")
	equal({}, config.env, "env host configuration default changed")
end)

test("redraw profile accepts only the documented host values", function()
	assert(vim.fn.writefile({ "return { ui = { redraw_profile = 'low-bandwidth' } }" }, config_path) == 0)
	local config = local_config.reload()
	equal("low-bandwidth", config.ui.redraw_profile, "low-bandwidth redraw profile was rejected")

	assert(vim.fn.writefile({ "return { ui = { redraw_profile = 'automatic' } }" }, config_path) == 0)
	config = local_config.reload()
	equal("full", config.ui.redraw_profile, "invalid redraw profile did not fall back to full")
	assert(
		table.concat(local_config.errors(), "\n"):find("ui.redraw_profile", 1, true),
		"invalid redraw profile did not report its schema path"
	)
end)

test("exact editor heartbeat accepts both inclusive policy bounds", function()
	for _, value in ipairs({ 60, 604800 }) do
		assert(vim.fn.writefile({
			("return { plugins = { exact_editor = { registry_heartbeat_seconds = %d } } }"):format(value),
		}, config_path) == 0)
		local config = local_config.reload()
		equal(value, config.plugins.exact_editor.registry_heartbeat_seconds, "heartbeat boundary was rejected")
	end
end)

test("plugin accessor returns isolated values and does not expose unrelated host data", function()
	local review = local_config.plugin("native_review")
	review.panel.max_width = 1
	equal(200, local_config.plugin("native_review").panel.max_width, "plugin config shares mutable state")
	equal({ sentinel = true }, local_config.plugin("not_registered", { sentinel = true }), "fallback changed")
	local ok = pcall(local_config.plugin, "")
	assert(not ok, "empty plugin name was accepted")
end)

test("retired root namespaces are rejected without compatibility aliases", function()
	assert(vim.fn.writefile({
		"return {",
		"  theme = { background = 'dark' },",
		"  clangd = { path = 'legacy-clangd' },",
		"  review = { hunk_context = 99 },",
		"  log_watch = { max_lines = 5 },",
		"  diagram_cache = { max_bytes = 5 },",
		"  mason = { auto_install = true },",
		"}",
	}, config_path) == 0)
	local config = local_config.reload()
	assert(config.theme == nil and config.clangd == nil and config.review == nil, "legacy namespace escaped validation")
	equal(3, config.plugins.native_review.hunk_context, "legacy review value became an alias")
	equal("clangd", config.plugins.clangd_compile_db.path, "legacy clangd value became an alias")
	local errors = table.concat(local_config.errors(), "\n")
	for _, name in ipairs({ "theme", "clangd", "review", "log_watch", "diagram_cache", "mason" }) do
		assert(errors:find(name .. ": unknown field", 1, true), "missing retirement diagnostic for " .. name)
	end
end)

test("canonical values validate ranges and the generated file is owner-only", function()
	assert(vim.fn.writefile({
		"return { plugins = {",
		"  native_review = { hunk_context = 7 },",
		"  exact_editor = { workspace_retention = 'visible', registry_heartbeat_seconds = 59 },",
		"  devcontainer_editor = { cli = '' },",
		"  tab_first = { history = { scope = 'global' } },",
		"  terminal_lifecycle = { buffer_mappings = { close = '' } },",
		"  project_python = { repl = { readiness_timeout_ms = 100, poll_interval_ms = 5000 } },",
		"  diagram_view = { cache = { max_age_seconds = 0 } },",
		"  log_workbench = { max_lines = 100001 },",
		"  just_workbench = { binary = '', justfile_names = { '' } },",
		"  clangd_compile_db = { path = '' },",
		"  treesitter_runtime = { languages = { [''] = {}, ['bad\\0key'] = {} } },",
		"  theme_router = { background = 'dark', transparent = true },",
		"} }",
	}, config_path) == 0)
	local config = local_config.reload()
	equal(7, config.plugins.native_review.hunk_context, "canonical review value was ignored")
	equal("visited", config.plugins.exact_editor.workspace_retention, "unsupported retention escaped validation")
	equal(21600, config.plugins.exact_editor.registry_heartbeat_seconds, "unsafe heartbeat escaped validation")
	equal("devcontainer", config.plugins.devcontainer_editor.cli, "empty CLI escaped validation")
	equal("workspace", config.plugins.tab_first.history.scope, "unsupported history scope escaped validation")
	equal("q", config.plugins.terminal_lifecycle.buffer_mappings.close, "empty mapping escaped validation")
	equal(50, config.plugins.project_python.repl.poll_interval_ms, "invalid REPL timing escaped validation")
	equal(30 * 24 * 60 * 60, config.plugins.diagram_view.cache.max_age_seconds, "zero cache age escaped validation")
	equal(100000, config.plugins.log_workbench.max_lines, "unsafe log limit was accepted")
	equal("just", config.plugins.just_workbench.binary, "empty Just binary escaped validation")
	equal(
		{ "justfile", "Justfile", ".justfile" },
		config.plugins.just_workbench.justfile_names,
		"empty Just names escaped validation"
	)
	equal("clangd", config.plugins.clangd_compile_db.path, "empty clangd path escaped validation")
	equal({}, config.plugins.treesitter_runtime.languages, "invalid Tree-sitter language keys escaped validation")
	equal("dark", config.plugins.theme_router.background, "canonical theme value was ignored")
	local errors = table.concat(local_config.errors(), "\n")
	for _, path in ipairs({
		"plugins.exact_editor.workspace_retention",
		"plugins.exact_editor.registry_heartbeat_seconds",
		"plugins.devcontainer_editor.cli",
		"plugins.tab_first.history.scope",
		"plugins.terminal_lifecycle.buffer_mappings.close",
		"plugins.project_python.repl.poll_interval_ms",
		"plugins.diagram_view.cache.max_age_seconds",
		"plugins.log_workbench.max_lines",
		"plugins.just_workbench.binary",
		"plugins.just_workbench.justfile_names",
		"plugins.clangd_compile_db.path",
		"plugins.treesitter_runtime.languages",
	}) do
		assert(errors:find(path, 1, true), "missing validation error for " .. path)
	end

	assert(vim.fn.writefile({
		"return { plugins = {",
		"  terminal_lifecycle = { buffer_mappings = { close = false, open_location = false } },",
		"  coverage_workbench = { signs = 'covered' },",
		"} }",
	}, config_path) == 0)
	config = local_config.reload()
	equal(false, config.plugins.terminal_lifecycle.buffer_mappings.close, "disabled close mapping was rejected")
	equal(
		false,
		config.plugins.terminal_lifecycle.buffer_mappings.open_location,
		"disabled location mapping was rejected"
	)
	equal("covered", config.plugins.coverage_workbench.signs, "covered-only signs were rejected")

	local_config.setup()
	vim.cmd("NvimConfigInit!")
	equal("rw-------", vim.fn.getfperm(config_path), "generated host config is not 0600")
	local generated = table.concat(vim.fn.readfile(config_path), "\n")
	assert(generated:find("plugins = {", 1, true), "generated template omitted canonical plugins table")
	assert(
		generated:find('ui = { redraw_profile = "full" }', 1, true),
		"generated template omitted the host redraw profile"
	)
	assert(
		generated:find("registry_heartbeat_seconds = 21600", 1, true),
		"generated template omitted the exact editor heartbeat policy"
	)
	assert(not generated:find("mason =", 1, true), "generated template retained retired Mason automation")
end)

vim.notify = original_notify
vim.env.NVIM_CONFIG_FILE = original_config
vim.env.NVIM_CONFIG_TRUST_STATE_ROOT = original_state
vim.fn.delete(root, "rf")

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("local_config_plugins_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
