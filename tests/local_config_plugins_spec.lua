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
local review_type_defaults = local_config.read().plugins.native_review.comment_types

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
	equal("card", config.plugins.native_review.composer.style, "native review composer default changed")
	equal(review_type_defaults, config.plugins.native_review.comment_types, "native review host types changed")
	equal(
		{ "suggestion", "objection!", "question", "pedantic", "praise" },
		vim.tbl_map(function(definition)
			return definition.id
		end, config.plugins.native_review.comment_types),
		"native review host type order changed"
	)
	equal(
		{ 2, 4, 3, 5, 6 },
		vim.tbl_map(function(definition)
			return definition.rail_rank
		end, config.plugins.native_review.comment_types),
		"native review rail priority changed"
	)
	equal(
		{ "◆", "!", "?", "·", "♥" },
		vim.tbl_map(function(definition)
			return definition.icon
		end, config.plugins.native_review.comment_types),
		"native review type icons changed"
	)
	equal(
		{
			"Proposed improvement.",
			"Challenge to an approach or decision.",
			"Request for clarification.",
			"Minor detail or style nit.",
			"Positive feedback.",
		},
		vim.tbl_map(function(definition)
			return definition.description
		end, config.plugins.native_review.comment_types),
		"native review type descriptions changed"
	)
	equal(
		{
			"NvimReviewCommentSuggestion",
			"NvimReviewCommentObjection",
			"NvimReviewCommentQuestion",
			"NvimReviewCommentPedantic",
			"NvimReviewCommentPraise",
		},
		vim.tbl_map(function(definition)
			return definition.highlight
		end, config.plugins.native_review.comment_types),
		"native review type highlights changed"
	)
	equal(
		{ "DiagnosticSignWarn", "Special", "DiagnosticSignInfo", "DiagnosticSignHint", "DiagnosticSignOk" },
		vim.tbl_map(function(definition)
			return definition.default_link
		end, config.plugins.native_review.comment_types),
		"native review type default highlight links changed"
	)
	equal(
		{
			vim.diagnostic.severity.WARN,
			vim.diagnostic.severity.INFO,
			vim.diagnostic.severity.INFO,
			vim.diagnostic.severity.HINT,
			vim.diagnostic.severity.HINT,
		},
		vim.tbl_map(function(definition)
			return definition.severity
		end, config.plugins.native_review.comment_types),
		"native review type severities changed"
	)
	equal("workspace", config.plugins.tab_first.history.scope, "tab history is not workspace-scoped")
	equal(30000, config.plugins.diagram_view.stage_timeout_ms, "diagram timeout default changed")
	equal(2000, config.plugins.native_review.max_files, "native review file limit default changed")
	equal(4 * 1024 * 1024, config.plugins.native_review.max_file_bytes, "native review file byte limit changed")
	equal(64 * 1024 * 1024, config.plugins.native_review.max_model_bytes, "native review model limit changed")
	equal(5000, config.plugins.terminal_lifecycle.stop_timeout_ms, "terminal stop timeout default changed")
	equal(10000, config.plugins.terminal_lifecycle.max_output_lines, "terminal output limit default changed")
	equal(300, config.plugins.exact_editor.activation_delay_ms, "exact editor activation delay default changed")
	equal(21600, config.plugins.exact_editor.registry_heartbeat_seconds, "exact editor heartbeat default changed")
	equal("docker", config.plugins.devcontainer_editor.docker_path, "Dev Container engine default changed")
	equal(true, config.plugins.devcontainer_editor.ui.progress, "Dev Container progress default changed")
	equal(500, config.plugins.devcontainer_editor.ui.progress_interval_ms, "Dev Container progress interval changed")
	equal(72, config.plugins.devcontainer_editor.ui.log_width, "Dev Container log width changed")
	equal(true, config.plugins.devcontainer_editor.ui.auto_open_log_on_error, "Dev Container error log policy changed")
	equal(64 * 1024, config.plugins.log_workbench.continuity_bytes, "log continuity default changed")
	equal(20000, config.plugins.log_workbench.max_matches, "log match cap default changed")
	equal(1000, config.plugins.log_workbench.scan_lines_per_tick, "log scan budget default changed")
	equal(50 * 1024 * 1024, config.plugins.coverage_workbench.max_report_bytes, "coverage report cap changed")
	equal(16 * 1024 * 1024, config.plugins.coverage_workbench.max_source_bytes, "coverage source cap changed")
	equal(64 * 1024 * 1024, config.plugins.coverage_workbench.max_model_bytes, "coverage model cap changed")
	equal(5, config.plugins.action_palette.recent_limit, "action palette recent limit default changed")
	equal("auto", config.plugins.theme_router.background, "theme background default changed")
	equal("dap-ui", config.dap.ui, "DAP host configuration moved under plugins")
	equal("full", config.ui.redraw_profile, "redraw profile default changed")
	equal(nil, config.ui.inline_diagnostics, "inline diagnostic policy gained a schema default")
	equal(nil, config.ui.full_refresh_ms, "full refresh interval gained a schema default")
	equal(nil, config.ui.noice_progress_throttle_ms, "Noice throttle gained a schema default")
	equal(nil, config.ui.bufferline_diagnostics, "Bufferline diagnostics gained a schema default")
	equal(nil, config.ui.bufferline_hover, "Bufferline hover gained a schema default")
	equal(1024 * 1024, config.clipboard.osc52_max_bytes, "OSC 52 default bound changed")
	equal(4 * 1024 * 1024, config.whitespace.max_bytes, "whitespace byte default changed")
	equal(100000, config.whitespace.max_lines, "whitespace line default changed")
	equal({}, config.env, "env host configuration default changed")
end)

test("Dev Container UI policy accepts only inclusive host bounds", function()
	for _, values in ipairs({
		{ progress_interval_ms = 200, log_width = 30 },
		{ progress_interval_ms = 5000, log_width = 160 },
	}) do
		assert(vim.fn.writefile({
			("return { plugins = { devcontainer_editor = { ui = { progress = false, progress_interval_ms = %d, log_width = %d, auto_open_log_on_error = false } } } }"):format(
				values.progress_interval_ms,
				values.log_width
			),
		}, config_path) == 0)
		local ui = local_config.reload().plugins.devcontainer_editor.ui
		equal(false, ui.progress, "Dev Container progress disable was rejected")
		equal(values.progress_interval_ms, ui.progress_interval_ms, "valid progress interval was rejected")
		equal(values.log_width, ui.log_width, "valid log width was rejected")
		equal(false, ui.auto_open_log_on_error, "Dev Container auto-open disable was rejected")
		equal({}, local_config.errors(), "valid Dev Container UI policy produced a diagnostic")
	end

	assert(vim.fn.writefile({
		"return { plugins = { devcontainer_editor = { ui = { progress = 'yes', progress_interval_ms = 199, log_width = 161, auto_open_log_on_error = 1 } } } }",
	}, config_path) == 0)
	local ui = local_config.reload().plugins.devcontainer_editor.ui
	equal(true, ui.progress, "invalid progress toggle escaped validation")
	equal(500, ui.progress_interval_ms, "invalid progress interval escaped validation")
	equal(72, ui.log_width, "invalid log width escaped validation")
	equal(true, ui.auto_open_log_on_error, "invalid auto-open toggle escaped validation")
	local errors = table.concat(local_config.errors(), "\n")
	for _, path in ipairs({
		"plugins.devcontainer_editor.ui.progress",
		"plugins.devcontainer_editor.ui.progress_interval_ms",
		"plugins.devcontainer_editor.ui.log_width",
		"plugins.devcontainer_editor.ui.auto_open_log_on_error",
	}) do
		assert(errors:find(path, 1, true), "missing Dev Container UI diagnostic for " .. path)
	end
end)

test("action palette recent limit accepts only its inclusive host bounds", function()
	for _, value in ipairs({ 0, 20 }) do
		assert(vim.fn.writefile({
			("return { plugins = { action_palette = { recent_limit = %d } } }"):format(value),
		}, config_path) == 0)
		local config = local_config.reload()
		equal(value, config.plugins.action_palette.recent_limit, "valid action palette recent limit was rejected")
		equal({}, local_config.errors(), "valid action palette recent limit produced a diagnostic")
	end

	for _, value in ipairs({ -1, 21, 1.5 }) do
		assert(vim.fn.writefile({
			("return { plugins = { action_palette = { recent_limit = %s } } }"):format(value),
		}, config_path) == 0)
		local config = local_config.reload()
		equal(5, config.plugins.action_palette.recent_limit, "invalid action palette recent limit escaped validation")
		assert(
			table.concat(local_config.errors(), "\n"):find("plugins.action_palette.recent_limit", 1, true),
			"invalid action palette recent limit omitted its diagnostic"
		)
	end
end)

test("coverage host byte limits accept only their inclusive schema bounds", function()
	for _, limits in ipairs({
		{ max_report_bytes = 1024, max_source_bytes = 1, max_model_bytes = 1 },
		{
			max_report_bytes = 256 * 1024 * 1024,
			max_source_bytes = 16 * 1024 * 1024,
			max_model_bytes = 64 * 1024 * 1024,
		},
	}) do
		assert(vim.fn.writefile({
			("return { plugins = { coverage_workbench = { max_report_bytes = %d, max_source_bytes = %d, max_model_bytes = %d } } }"):format(
				limits.max_report_bytes,
				limits.max_source_bytes,
				limits.max_model_bytes
			),
		}, config_path) == 0)
		local actual = local_config.reload().plugins.coverage_workbench
		equal(limits.max_report_bytes, actual.max_report_bytes, "coverage report boundary was rejected")
		equal(limits.max_source_bytes, actual.max_source_bytes, "coverage source boundary was rejected")
		equal(limits.max_model_bytes, actual.max_model_bytes, "coverage model boundary was rejected")
		equal({}, local_config.errors(), "valid coverage boundaries produced a diagnostic")
	end
end)

test("log workbench host cost controls accept their inclusive schema bounds", function()
	for _, limits in ipairs({
		{ continuity_bytes = 1024, max_matches = 1, scan_lines_per_tick = 1 },
		{ continuity_bytes = 1024 * 1024, max_matches = 100000, scan_lines_per_tick = 10000 },
	}) do
		assert(vim.fn.writefile({
			("return { plugins = { log_workbench = { continuity_bytes = %d, max_matches = %d, scan_lines_per_tick = %d } } }"):format(
				limits.continuity_bytes,
				limits.max_matches,
				limits.scan_lines_per_tick
			),
		}, config_path) == 0)
		local actual = local_config.reload().plugins.log_workbench
		equal(limits.continuity_bytes, actual.continuity_bytes, "continuity boundary was rejected")
		equal(limits.max_matches, actual.max_matches, "match boundary was rejected")
		equal(limits.scan_lines_per_tick, actual.scan_lines_per_tick, "scan boundary was rejected")
		equal({}, local_config.errors(), "valid log boundaries produced a diagnostic")
	end
end)

test("native review composer style is host-configurable and schema-validated", function()
	for _, style in ipairs({ "card", "minimal" }) do
		assert(vim.fn.writefile({
			("return { plugins = { native_review = { composer = { style = %q } } } }"):format(style),
		}, config_path) == 0)
		equal(style, local_config.reload().plugins.native_review.composer.style, "valid composer style was rejected")
		equal({}, local_config.errors(), "valid composer style produced a diagnostic")
	end

	assert(vim.fn.writefile({
		"return { plugins = { native_review = { composer = { style = 'animated' } } } }",
	}, config_path) == 0)
	equal(
		"card",
		local_config.reload().plugins.native_review.composer.style,
		"invalid composer style escaped validation"
	)
	assert(
		table.concat(local_config.errors(), "\n"):find("plugins.native_review.composer.style", 1, true),
		"invalid composer style omitted its schema warning"
	)
end)

local function configured_review_types(definitions)
	assert(vim.fn.writefile({
		"return { plugins = { native_review = { comment_types = " .. definitions .. " } } }",
	}, config_path) == 0)
	return local_config.reload().plugins.native_review.comment_types, local_config.errors()
end

test("additional native review comment types keep order and default INFO severity", function()
	local definitions = "{{ id = 'objection!', icon = '!', description = 'Challenge to a decision.', highlight = 'NvimReviewCommentObjection', default_link = 'Special', rail_rank = 4 }, "
		.. "{ id = 'insight', icon = '◆', highlight = 'NvimReviewCommentInsight', default_link = 'DiagnosticSignInfo', rail_rank = 2, severity = 4 }}"
	local types, errors = configured_review_types(definitions)
	equal({}, errors, "valid review types produced a diagnostic")
	equal({ "objection!", "insight" }, { types[1].id, types[2].id }, "configured type order changed")
	equal("Challenge to a decision.", types[1].description, "configured type description was lost")
	equal(nil, types[2].description, "optional type description became mandatory")
	equal(vim.diagnostic.severity.INFO, types[1].severity, "review type INFO default changed")
	equal(vim.diagnostic.severity.HINT, types[2].severity, "review type severity was ignored")
	types[1].id = "mutated"
	equal("objection!", local_config.plugin("native_review").comment_types[1].id, "review types leaked mutable state")
end)

test("host type list can select issue-only and rejects invalid replacements atomically", function()
	local issue_only, issue_only_errors = configured_review_types("{}")
	equal({}, issue_only, "explicit empty type list did not select issue-only")
	equal({}, issue_only_errors, "explicit empty type list produced a diagnostic")
	local valid =
		"{ id = 'objection!', icon = '!', highlight = 'NvimReviewCommentObjection', default_link = 'Special', rail_rank = 4 }"
	local invalid = {
		{ "{" .. valid .. ", { id = 'missing', icon = '?', highlight = 'Missing', rail_rank = 5 }}", "default_link" },
		{ "{{ id = 'Issue', icon = '!', highlight = 'ReviewIssue', default_link = 'Special', rail_rank = 4 }}", "id" },
		{
			"{{ id = 'issue', icon = '!', highlight = 'ReviewIssue', default_link = 'Special', rail_rank = 4 }}",
			"reserved",
		},
		{
			"{{ id = 'rationale', icon = '!', highlight = 'ReviewRationale', default_link = 'Special', rail_rank = 4 }}",
			"reserved",
		},
		{ "{" .. valid .. ", " .. valid .. "}", "duplicate" },
		{
			"{{ id = 'odd', icon = string.char(255), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"icon",
		},
		{
			"{{ id = 'odd', icon = '界界', highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"icon",
		},
		{ "{{ id = 'odd', icon = '\\n', highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}", "icon" },
		{
			"{{ id = 'odd', icon = '!', highlight = 'Bad Group', default_link = 'Special', rail_rank = 4 }}",
			"highlight",
		},
		{
			"{{ id = 'odd', icon = '!', highlight = 'ReviewOdd', default_link = 'Bad Group', rail_rank = 4 }}",
			"default_link",
		},
		{
			"{{ id = 'odd', icon = '!', highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 1 }}",
			"rail_rank",
		},
		{
			"{{ id = 'odd', icon = '!', highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4, severity = 5 }}",
			"severity",
		},
		{
			"{{ id = 'odd', icon = '!', description = string.char(10), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{
			"{{ id = 'odd', icon = '!', description = string.char(9), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{
			"{{ id = 'odd', icon = '!', description = string.char(127), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{
			"{{ id = 'odd', icon = '!', description = string.rep('x', 161), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{
			"{{ id = 'odd', icon = '!', description = string.char(255), highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{
			"{{ id = 'odd', icon = '!', description = '   ', highlight = 'ReviewOdd', default_link = 'Special', rail_rank = 4 }}",
			"description",
		},
		{ "{ [2] = " .. valid .. " }", "dense list" },
	}
	for _, case in ipairs(invalid) do
		local types, errors = configured_review_types(case[1])
		equal(review_type_defaults, types, "invalid review type escaped atomic fallback")
		assert(table.concat(errors, "\n"):find(case[2], 1, true), "missing diagnostic for " .. case[2])
	end
	local many = {}
	for index = 1, 33 do
		many[index] = ("{ id = 'type%d', icon = '!', highlight = 'ReviewType%d', default_link = 'Special', rail_rank = %d }"):format(
			index,
			index,
			index + 1
		)
	end
	local types, errors = configured_review_types("{" .. table.concat(many, ",") .. "}")
	equal(review_type_defaults, types, "oversized review type list escaped validation")
	assert(table.concat(errors, "\n"):find("at most 32", 1, true), "oversized list omitted its diagnostic")
end)

test("native review construction limits are positive host settings", function()
	assert(vim.fn.writefile({
		"return { plugins = { native_review = { max_files = 7, max_file_bytes = 11, max_model_bytes = 13 } } }",
	}, config_path) == 0)
	local review = local_config.reload().plugins.native_review
	equal(7, review.max_files, "native review file limit was rejected")
	equal(11, review.max_file_bytes, "native review file byte limit was rejected")
	equal(13, review.max_model_bytes, "native review model limit was rejected")
	equal({}, local_config.errors(), "valid native review limits produced a diagnostic")

	assert(vim.fn.writefile({
		"return { plugins = { native_review = { max_files = 0, max_file_bytes = -1, max_model_bytes = 1.5 } } }",
	}, config_path) == 0)
	review = local_config.reload().plugins.native_review
	equal(2000, review.max_files, "zero native review file limit escaped validation")
	equal(4 * 1024 * 1024, review.max_file_bytes, "negative native review byte limit escaped validation")
	equal(64 * 1024 * 1024, review.max_model_bytes, "fractional native review model limit escaped validation")
end)

test("Tree-sitter language options remain partial for global inheritance", function()
	assert(vim.fn.writefile({
		"return { plugins = { treesitter_runtime = {",
		"  max_bytes = 32768,",
		"  languages = { lua = { max_bytes = 65536 }, markdown = { indent = false } },",
		"} } }",
	}, config_path) == 0)
	local policy = local_config.reload().plugins.treesitter_runtime
	equal(32768, policy.max_bytes, "global Tree-sitter maximum was rejected")
	equal({ max_bytes = 65536 }, policy.languages.lua, "absent language indentation gained a default")
	equal({ indent = false }, policy.languages.markdown, "absent language maximum gained a default")
	equal({}, local_config.errors(), "valid partial language policies produced a diagnostic")
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

test("inline diagnostics accepts only explicit host presenter values", function()
	for _, mode in ipairs({ "current-line", "settled-line", "off" }) do
		assert(vim.fn.writefile({ ("return { ui = { inline_diagnostics = %q } }"):format(mode) }, config_path) == 0)
		local config = local_config.reload()
		equal(mode, config.ui.inline_diagnostics, "valid inline diagnostic presenter was rejected")
		equal({}, local_config.errors(), "valid inline diagnostic presenter produced a diagnostic")
	end

	assert(vim.fn.writefile({ "return { ui = { inline_diagnostics = 'automatic' } }" }, config_path) == 0)
	local config = local_config.reload()
	equal(nil, config.ui.inline_diagnostics, "invalid inline diagnostic presenter did not remain unset")
	assert(
		table.concat(local_config.errors(), "\n"):find("ui.inline_diagnostics", 1, true),
		"invalid inline diagnostic presenter did not report its schema path"
	)
end)

test("redraw cost controls are optional host-only overrides", function()
	assert(vim.fn.writefile({
		"return { ui = {",
		"  full_refresh_ms = 8,",
		"  noice_progress_throttle_ms = 5000,",
		"  bufferline_diagnostics = false,",
		"  bufferline_hover = true,",
		"} }",
	}, config_path) == 0)
	local config = local_config.reload()
	equal(8, config.ui.full_refresh_ms, "valid full refresh interval was rejected")
	equal(5000, config.ui.noice_progress_throttle_ms, "valid Noice throttle was rejected")
	equal(false, config.ui.bufferline_diagnostics, "false Bufferline diagnostics override was rejected")
	equal(true, config.ui.bufferline_hover, "true Bufferline hover override was rejected")
	equal({}, local_config.errors(), "valid redraw cost controls produced a diagnostic")

	assert(vim.fn.writefile({
		"return { ui = {",
		"  full_refresh_ms = 7,",
		"  noice_progress_throttle_ms = 5001,",
		"  bufferline_diagnostics = 'yes',",
		"  bufferline_hover = 1,",
		"} }",
	}, config_path) == 0)
	config = local_config.reload()
	equal(nil, config.ui.full_refresh_ms, "invalid full refresh interval escaped validation")
	equal(nil, config.ui.noice_progress_throttle_ms, "invalid Noice throttle escaped validation")
	equal(nil, config.ui.bufferline_diagnostics, "invalid Bufferline diagnostics override escaped validation")
	equal(nil, config.ui.bufferline_hover, "invalid Bufferline hover override escaped validation")
	local errors = table.concat(local_config.errors(), "\n")
	for _, path in ipairs({
		"ui.full_refresh_ms",
		"ui.noice_progress_throttle_ms",
		"ui.bufferline_diagnostics",
		"ui.bufferline_hover",
	}) do
		assert(errors:find(path, 1, true), "missing redraw cost diagnostic for " .. path)
	end
end)

test("clipboard and whitespace host bounds are schema validated", function()
	assert(vim.fn.writefile({
		"return {",
		"  clipboard = { osc52_max_bytes = 16777216 },",
		"  whitespace = { max_bytes = 1, max_lines = 1000000 },",
		"}",
	}, config_path) == 0)
	local config = local_config.reload()
	equal(16 * 1024 * 1024, config.clipboard.osc52_max_bytes, "OSC 52 upper bound was rejected")
	equal(1, config.whitespace.max_bytes, "whitespace byte lower bound was rejected")
	equal(1000000, config.whitespace.max_lines, "whitespace line upper bound was rejected")
	equal({}, local_config.errors(), "valid host bounds produced a diagnostic")

	assert(vim.fn.writefile({
		"return {",
		"  clipboard = { osc52_max_bytes = 16777217 },",
		"  whitespace = { max_bytes = 0, max_lines = 1000001 },",
		"}",
	}, config_path) == 0)
	config = local_config.reload()
	equal(1024 * 1024, config.clipboard.osc52_max_bytes, "invalid OSC 52 bound escaped validation")
	equal(4 * 1024 * 1024, config.whitespace.max_bytes, "invalid whitespace byte bound escaped validation")
	equal(100000, config.whitespace.max_lines, "invalid whitespace line bound escaped validation")
	local errors = table.concat(local_config.errors(), "\n")
	for _, path in ipairs({ "clipboard.osc52_max_bytes", "whitespace.max_bytes", "whitespace.max_lines" }) do
		assert(errors:find(path, 1, true), "missing host-bound diagnostic for " .. path)
	end
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

test("exact editor activation delay accepts both inclusive policy bounds", function()
	for _, value in ipairs({ 0, 5000 }) do
		assert(vim.fn.writefile({
			("return { plugins = { exact_editor = { activation_delay_ms = %d } } }"):format(value),
		}, config_path) == 0)
		local config = local_config.reload()
		equal(value, config.plugins.exact_editor.activation_delay_ms, "activation delay boundary was rejected")
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

test("host plugin accessor never reads the project-local file", function()
	assert(vim.fn.writefile({
		"return { plugins = { devcontainer_editor = { docker_path = '/host/podman' } } }",
	}, config_path) == 0)
	local_config.reload()
	local project = vim.fs.joinpath(root, "project-host-only")
	assert(vim.fn.mkdir(project, "p", 448) == 1)
	assert(vim.fn.writefile({
		"return { plugins = { devcontainer_editor = { docker_path = '/project/podman' } } }",
	}, vim.fs.joinpath(project, ".nvim-local.lua")) == 0)
	local old_cwd = vim.fn.getcwd()
	local old_secure_read = vim.secure.read
	vim.cmd.cd(vim.fn.fnameescape(project))
	vim.secure.read = function()
		error("project config must not be read")
	end
	local called, value = xpcall(function()
		return local_config.host_plugin("devcontainer_editor", { docker_path = "docker" })
	end, debug.traceback)
	vim.secure.read = old_secure_read
	vim.cmd.cd(vim.fn.fnameescape(old_cwd))
	assert(called, value)
	equal("/host/podman", value.docker_path, "project-local engine overrode host-only policy")
	value.docker_path = "mutated"
	equal(
		"/host/podman",
		local_config.host_plugin("devcontainer_editor", { docker_path = "docker" }).docker_path,
		"host plugin accessor leaked mutable cache state"
	)
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
		"  exact_editor = { activation_delay_ms = 5001, workspace_retention = 'visible', registry_heartbeat_seconds = 59 },",
		"  devcontainer_editor = { cli = 'devcontainer', docker_path = '', ui = { progress_interval_ms = 199, log_width = 161 } },",
		"  tab_first = { history = { scope = 'global' } },",
		"  terminal_lifecycle = { max_output_lines = 100001, buffer_mappings = { close = '' } },",
		"  project_python = { repl = { readiness_timeout_ms = 100, poll_interval_ms = 5000 } },",
		"  diagram_view = { cache = { max_age_seconds = 0 } },",
		"  log_workbench = { max_lines = 100001, continuity_bytes = 1023, max_matches = 100001, scan_lines_per_tick = 10001 },",
		"  coverage_workbench = { max_report_bytes = 268435457, max_source_bytes = 16777217, max_model_bytes = 67108865 },",
		"  just_workbench = { binary = '', justfile_names = { '' } },",
		"  clangd_compile_db = { path = '' },",
		"  treesitter_runtime = { languages = { [''] = {}, ['bad\\0key'] = {} } },",
		"  theme_router = { background = 'dark', transparent = true },",
		"} }",
	}, config_path) == 0)
	local config = local_config.reload()
	equal(7, config.plugins.native_review.hunk_context, "canonical review value was ignored")
	equal(300, config.plugins.exact_editor.activation_delay_ms, "unsafe activation delay escaped validation")
	equal("visited", config.plugins.exact_editor.workspace_retention, "unsupported retention escaped validation")
	equal(21600, config.plugins.exact_editor.registry_heartbeat_seconds, "unsafe heartbeat escaped validation")
	equal("docker", config.plugins.devcontainer_editor.docker_path, "empty engine path escaped validation")
	equal(
		500,
		config.plugins.devcontainer_editor.ui.progress_interval_ms,
		"unsafe progress interval escaped validation"
	)
	equal(72, config.plugins.devcontainer_editor.ui.log_width, "unsafe log width escaped validation")
	equal("workspace", config.plugins.tab_first.history.scope, "unsupported history scope escaped validation")
	equal("q", config.plugins.terminal_lifecycle.buffer_mappings.close, "empty mapping escaped validation")
	equal(10000, config.plugins.terminal_lifecycle.max_output_lines, "unsafe terminal output limit escaped validation")
	equal(50, config.plugins.project_python.repl.poll_interval_ms, "invalid REPL timing escaped validation")
	equal(30 * 24 * 60 * 60, config.plugins.diagram_view.cache.max_age_seconds, "zero cache age escaped validation")
	equal(100000, config.plugins.log_workbench.max_lines, "unsafe log limit was accepted")
	equal(64 * 1024, config.plugins.log_workbench.continuity_bytes, "unsafe continuity limit was accepted")
	equal(20000, config.plugins.log_workbench.max_matches, "unsafe match limit was accepted")
	equal(1000, config.plugins.log_workbench.scan_lines_per_tick, "unsafe scan budget was accepted")
	equal(50 * 1024 * 1024, config.plugins.coverage_workbench.max_report_bytes, "unsafe report cap was accepted")
	equal(16 * 1024 * 1024, config.plugins.coverage_workbench.max_source_bytes, "unsafe source cap was accepted")
	equal(64 * 1024 * 1024, config.plugins.coverage_workbench.max_model_bytes, "unsafe model cap was accepted")
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
		"plugins.exact_editor.activation_delay_ms",
		"plugins.exact_editor.workspace_retention",
		"plugins.exact_editor.registry_heartbeat_seconds",
		"plugins.devcontainer_editor.docker_path",
		"plugins.devcontainer_editor.cli",
		"plugins.devcontainer_editor.ui.progress_interval_ms",
		"plugins.devcontainer_editor.ui.log_width",
		"plugins.tab_first.history.scope",
		"plugins.terminal_lifecycle.buffer_mappings.close",
		"plugins.terminal_lifecycle.max_output_lines",
		"plugins.project_python.repl.poll_interval_ms",
		"plugins.diagram_view.cache.max_age_seconds",
		"plugins.log_workbench.max_lines",
		"plugins.log_workbench.continuity_bytes",
		"plugins.log_workbench.max_matches",
		"plugins.log_workbench.scan_lines_per_tick",
		"plugins.coverage_workbench.max_report_bytes",
		"plugins.coverage_workbench.max_source_bytes",
		"plugins.coverage_workbench.max_model_bytes",
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
	assert(generated:find("recent_limit = 5", 1, true), "generated template omitted the action palette recent limit")
	assert(generated:find('redraw_profile = "full"', 1, true), "generated template omitted the host redraw profile")
	assert(
		generated:find('-- inline_diagnostics = "settled-line"', 1, true),
		"generated template omitted the optional host inline diagnostic policy"
	)
	for _, field in ipairs({
		"-- full_refresh_ms = 50",
		"-- noice_progress_throttle_ms = 100",
		"-- bufferline_diagnostics = false",
		"-- bufferline_hover = false",
	}) do
		assert(generated:find(field, 1, true), "generated template omitted redraw control: " .. field)
	end
	assert(generated:find("clipboard = { osc52_max_bytes", 1, true), "generated template omitted clipboard bounds")
	assert(generated:find("whitespace = {", 1, true), "generated template omitted whitespace bounds")
	assert(
		generated:find("registry_heartbeat_seconds = 21600", 1, true),
		"generated template omitted the exact editor heartbeat policy"
	)
	assert(
		generated:find("activation_delay_ms = 300", 1, true),
		"generated template omitted the exact editor activation delay"
	)
	for _, field in ipairs({
		"progress = true",
		"progress_interval_ms = 500",
		"log_width = 72",
		"auto_open_log_on_error = true",
	}) do
		assert(generated:find(field, 1, true), "generated template omitted Dev Container UI field: " .. field)
	end
	for _, field in ipairs({ "continuity_bytes = 64 * 1024", "max_matches = 20000", "scan_lines_per_tick = 1000" }) do
		assert(generated:find(field, 1, true), "generated template omitted log control: " .. field)
	end
	for _, field in ipairs({
		"max_files = 2000",
		"max_file_bytes = 4 * 1024 * 1024",
		"max_model_bytes = 64 * 1024 * 1024",
	}) do
		assert(generated:find(field, 1, true), "generated template omitted native review control: " .. field)
	end
	for _, field in ipairs({
		"max_report_bytes = 50 * 1024 * 1024",
		"max_source_bytes = 16 * 1024 * 1024",
		"max_model_bytes = 64 * 1024 * 1024",
	}) do
		assert(generated:find(field, 1, true), "generated template omitted coverage limit: " .. field)
	end
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
