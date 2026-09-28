vim.o.shadafile = "NONE"
vim.o.swapfile = false

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "could not resolve native-review spec")
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ":p")))
vim.opt.runtimepath:prepend(plugin)

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

local repo = {
	clean_git_command = function(argv)
		return vim.deepcopy(argv)
	end,
	contains = function()
		return false
	end,
	current_root = function()
		return nil
	end,
	git = function()
		return nil, "git fixture is not configured"
	end,
	relative_existing = function()
		return nil
	end,
	resolve_relative = function(root, path)
		return vim.fs.joinpath(root, path)
	end,
	root = function(value)
		return value
	end,
}

local native_review = require("native_review")

local additional_comment_types = {
	{
		id = "suggestion",
		icon = "◆",
		highlight = "NvimReviewCommentSuggestion",
		default_link = "DiagnosticSignWarn",
		rail_rank = 2,
		severity = vim.diagnostic.severity.WARN,
		description = "A useful alternative, not a defect.",
	},
	{
		id = "objection!",
		icon = "!",
		highlight = "NvimReviewCommentObjection",
		default_link = "Special",
		rail_rank = 4,
	},
	{
		id = "question",
		icon = "?",
		highlight = "NvimReviewCommentQuestion",
		default_link = "DiagnosticSignInfo",
		rail_rank = 3,
	},
	{
		id = "pedantic",
		icon = "·",
		highlight = "NvimReviewCommentPedantic",
		default_link = "DiagnosticSignHint",
		rail_rank = 5,
		severity = vim.diagnostic.severity.HINT,
	},
	{
		id = "praise",
		icon = "♥",
		highlight = "NvimReviewCommentPraise",
		default_link = "DiagnosticSignOk",
		rail_rank = 6,
		severity = vim.diagnostic.severity.HINT,
	},
}

local function tabs_fixture(value)
	return {
		acquire_transient = function()
			return value
		end,
		focus_transient = function()
			return value
		end,
		rename_transient = function()
			return value
		end,
		release_transient = function()
			return value
		end,
		valid_transient = function()
			return value
		end,
	}
end

local function setup(overrides)
	overrides = overrides or {}
	return native_review.setup(vim.tbl_extend("force", {
		repo = repo,
		fs = {
			read_binary = function()
				return nil, "fixture"
			end,
			write_binary_atomic = function()
				return nil, "fixture"
			end,
		},
		editor = {
			open_file_in_tab = function() end,
		},
		tabs = tabs_fixture(true),
		lsp_navigation = {},
	}, overrides))
end

test("lifecycle defaults are copied and unknown setup options do not mutate state", function()
	local defaults = native_review.effective_config()
	equal({
		hunk_context = 3,
		max_files = 2000,
		max_file_bytes = 4 * 1024 * 1024,
		max_model_bytes = 64 * 1024 * 1024,
		layout = "inline",
		context = "hunks",
		inline_comments = true,
		comment_types = {},
		composer = { style = "card" },
		panel = { max_width = 200, max_height = 48 },
	}, defaults, "pre-setup defaults")
	assert(native_review.status().configured == false)
	defaults.panel.max_width = 1
	equal(200, native_review.effective_config().panel.max_width, "effective config leaked mutable state")

	local before = native_review.status()
	local ok, err = pcall(native_review.setup, { unknown = true })
	assert(not ok and tostring(err):find("unknown option", 1, true), tostring(err))
	equal(before, native_review.status(), "rejected setup mutated status")
end)

test("plugin defaults to issue and configured types own cycle, rail, icon, severity, and description", function()
	local catalogue = native_review.comment_types or require("native_review.comment_types")
	equal({ "issue" }, catalogue.ids(), "issue must be the only plugin default")
	equal("Defect or concern that needs action.", catalogue.get("issue").description, "issue description")
	equal({ "issue" }, catalogue.rail_ids(), "issue must be the only default rail type")
	equal("issue", catalogue.cycle("issue", 1), "single-type forward cycle")
	equal("issue", catalogue.cycle("issue", -1), "single-type reverse cycle")
	assert(not catalogue.contains("objection!"), "configured type is active by default")
	equal("objection!", catalogue.get("rationale").id, "legacy type compatibility")
	setup({ comment_types = additional_comment_types })
	equal(
		{ "issue", "suggestion", "objection!", "question", "pedantic", "praise" },
		catalogue.ids(),
		"comment type cycle order"
	)
	equal(
		{ "issue", "suggestion", "question", "objection!", "pedantic", "praise" },
		catalogue.rail_ids(),
		"comment sign rail priority"
	)
	for _, definition in ipairs(catalogue.all()) do
		assert(definition.icon ~= "" and definition.highlight:match("^NvimReviewComment"))
		assert(catalogue.contains(definition.id))
	end
	assert(not catalogue.contains("rationale"), "retired type remains selectable")
	equal("objection!", catalogue.canonical("rationale"), "saved type compatibility")
	equal("!", catalogue.get("objection!").icon, "objection badge")
	equal(vim.diagnostic.severity.INFO, catalogue.get("objection!").severity, "optional severity default")
	equal("A useful alternative, not a defect.", catalogue.get("suggestion").description, "configured description")
	assert(catalogue.get("objection!").description == nil, "description unexpectedly required")
	equal("suggestion", catalogue.cycle("issue", 1), "forward cycle")
	equal("praise", catalogue.cycle("issue", -1), "reverse cycle")
	local config = native_review.effective_config()
	equal(
		{ "suggestion", "objection!", "question", "pedantic", "praise" },
		vim.tbl_map(function(definition)
			return definition.id
		end, config.comment_types),
		"configured types missing from effective config"
	)
	config.comment_types[1].id = "mutated"
	equal("suggestion", native_review.effective_config().comment_types[1].id, "effective config leaked types")
	local definitions = catalogue.all()
	definitions[2].id = "mutated"
	definitions[2].description = "mutated"
	equal("suggestion", catalogue.ids()[2], "catalogue leaked mutable definitions")
	equal(
		"A useful alternative, not a defect.",
		catalogue.get("suggestion").description,
		"catalogue leaked description"
	)
	local before = native_review.status()
	for _, bad in ipairs({
		{ id = "rationale", icon = "!", highlight = "ReviewRationale", default_link = "Special", rail_rank = 2 },
		{ id = "custom", icon = "", highlight = "ReviewCustom", default_link = "Special", rail_rank = 2 },
		{ id = "custom", icon = "!", highlight = "Bad Group", default_link = "Special", rail_rank = 2 },
	}) do
		local ok = pcall(setup, { comment_types = { bad } })
		assert(not ok, "invalid comment type was accepted")
		equal(before, native_review.status(), "rejected type changed active review config")
	end
	for _, invalid_description in ipairs({
		"",
		"   ",
		string.rep("a", 161),
		"first\nsecond",
		"first\rsecond",
		"control" .. string.char(0xC2, 0x85),
		"separator" .. string.char(0xE2, 0x80, 0xA8),
		string.char(0xC3, 0x28),
		42,
	}) do
		local definition = vim.deepcopy(additional_comment_types[1])
		definition.description = invalid_description
		local ok, err = pcall(setup, { comment_types = { definition } })
		assert(not ok and tostring(err):find(".description", 1, true), "invalid description was accepted")
		equal(before, native_review.status(), "rejected description changed active review config")
	end
	local described = vim.deepcopy(additional_comment_types[1])
	described.description = "Análisis útil " .. string.rep("a", 144)
	setup({ comment_types = { described } })
	equal(described.description, catalogue.get("suggestion").description, "valid UTF-8 description was changed")
	setup()
	equal({ "issue" }, catalogue.ids(), "repeated setup retained stale custom types")
end)

test("composer style accepts only card or minimal without mutating rejected config", function()
	local before = native_review.status()
	for _, composer in ipairs({ { style = "animated" }, { style = "card", extra = true } }) do
		local ok, err = pcall(setup, { composer = composer })
		assert(not ok and tostring(err):find("composer", 1, true), tostring(err))
		equal(before, native_review.status(), "rejected composer config mutated status")
	end
end)

test("model limits are positive integers and rejected setup is transactional", function()
	local before = native_review.status()
	for _, limits in ipairs({
		{ max_files = 0 },
		{ max_file_bytes = -1 },
		{ max_model_bytes = 1.5 },
	}) do
		local ok, err = pcall(setup, limits)
		assert(not ok and tostring(err):find("positive integer", 1, true), tostring(err))
		equal(before, native_review.status(), "rejected model limits mutated status")
	end
	setup({ max_files = 7, max_file_bytes = 11, max_model_bytes = 13 })
	local configured = native_review.effective_config()
	equal(7, configured.max_files, "configured file count was lost")
	equal(11, configured.max_file_bytes, "configured file bytes were lost")
	equal(13, configured.max_model_bytes, "configured model bytes were lost")
	configured.max_files = 99
	equal(7, native_review.effective_config().max_files, "effective model limits leaked mutable state")
	setup()
end)

test("setup requires every transient tab lease method atomically", function()
	local before = native_review.status()
	for _, method in ipairs({
		"acquire_transient",
		"focus_transient",
		"rename_transient",
		"release_transient",
		"valid_transient",
	}) do
		local adapter = tabs_fixture(true)
		adapter[method] = nil
		local ok, err = pcall(setup, { tabs = adapter })
		assert(not ok and tostring(err):find("tabs." .. method, 1, true), tostring(err))
		equal(before, native_review.status(), "rejected tabs adapter mutated setup state")
	end
end)

test("clipboard adapter is optional, strict, and replaced through its stable proxy", function()
	local before = native_review.status()
	for _, adapter in ipairs({ true, {}, { available = function() end }, { setreg = function() end } }) do
		local ok, err = pcall(setup, { clipboard = adapter })
		assert(not ok and tostring(err):find("clipboard", 1, true), tostring(err))
		equal(before, native_review.status(), "rejected clipboard adapter mutated setup state")
	end

	local first_available = function()
		return true
	end
	setup({ clipboard = {
		available = first_available,
		setreg = function()
			return 0
		end,
	} })
	local proxy = require("native_review.dependencies").get("clipboard")
	assert(proxy.available(), "injected clipboard was unavailable")
	setup({ clipboard = {
		available = function()
			return false
		end,
		setreg = function()
			return 1
		end,
	} })
	assert(not proxy.available() and proxy.setreg("+", "review") == 1, "clipboard proxy retained a stale adapter")
	setup()
end)

setup()

test("plugin setup creates no global commands or mappings and imports no host module", function()
	native_review.controller.setup()
	for _, command in ipairs({
		"ReviewOpen",
		"ReviewPanel",
		"ReviewComment",
		"ReviewExport",
		"ReviewPublish",
		"ReviewLinkTuicr",
	}) do
		equal(0, vim.fn.exists(":" .. command), command .. " was registered by the plugin")
	end
	equal({}, vim.fn.maparg("<leader>ro", "n", false, true), "plugin registered a global review mapping")
	for name in pairs(package.loaded) do
		assert(not name:match("^config%."), "plugin imported host module " .. name)
	end
	assert(native_review.controller.publish == nil, "TUICR publication API survived")
	assert(native_review.controller.link_tuicr == nil, "TUICR linking API survived")
end)

test("unified projection keeps shared context once and orders OLD before NEW", function()
	local projection = assert(native_review.projection.build({
		old_path = "sample.lua",
		new_path = "sample.lua",
		old_text = "keep\nold-a\nold-b\ntail\n",
		new_text = "keep\nnew-a\ntail\n",
		hunks = { { 2, 2, 2, 1 } },
	}))
	local rows = {}
	for _, row in ipairs(projection.rows) do
		rows[#rows + 1] = { row.kind, row.text, row.old_line, row.new_line }
	end
	equal({
		{ "context", "keep", 1, 1 },
		{ "old", "old-a", 2 },
		{ "old", "old-b", 3 },
		{ "new", "new-a", nil, 2 },
		{ "context", "tail", 4, 3 },
	}, rows, "OLD/NEW projection order changed")
	local crossed, crossed_err = native_review.projection.resolve_range(projection, 3, 4)
	assert(crossed == nil and crossed_err:find("crosses OLD-only and NEW-only", 1, true), crossed_err)
end)

test("CURRENT mapping accepts unchanged lines and rejects changed rows", function()
	local snapshot = { "one", "two", "three", "four" }
	local current = { "zero", "one", "changed", "three", "four" }
	equal(2, native_review.lsp.map_line(snapshot, current, 1), "unchanged CURRENT row did not map")
	local mapped, err = native_review.lsp.map_line(snapshot, current, 2)
	assert(mapped == nil and err:find("changed hunk", 1, true), err)
	equal(4, native_review.lsp.map_line(snapshot, current, 3), "trailing unchanged CURRENT row did not map")
end)

test("historical OLD buffers remain LSP-blocked with buffer-local guards", function()
	local buf = vim.api.nvim_create_buf(false, true)
	assert(native_review.lsp.mark(buf, "old"), "OLD buffer was not marked")
	assert(native_review.lsp.blocked(buf), "OLD buffer was not blocked")
	local mapping = vim.fn.maparg("gd", "n", false, true)
	equal({}, mapping, "OLD guard leaked into the global mapping table")
	local local_mapping = vim.api.nvim_buf_call(buf, function()
		return vim.fn.maparg("gd", "n", false, true)
	end)
	assert(local_mapping.buffer == 1, "OLD guard was not buffer-local")
	native_review.lsp.clear(buf)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("discarding a suspended export preview wipes only its private receipt buffer", function()
	local preview_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(preview_buf, "review-export://markdown")
	vim.bo[preview_buf].bufhidden = "hide"
	assert(native_review.export.discard_preview({ buf = preview_buf }))
	assert(not vim.api.nvim_buf_is_valid(preview_buf), "discard retained the suspended preview buffer")

	local unrelated = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(unrelated, "review-export://not-the-preview")
	assert(not native_review.export.discard_preview({ buf = unrelated }), "discard accepted an unrelated buffer")
	assert(vim.api.nvim_buf_is_valid(unrelated), "discard deleted an unrelated buffer")
	vim.api.nvim_buf_delete(unrelated, { force = true })
end)

test("legacy bridge and delivery metadata stay renderable but never drive the controller", function()
	local session = {
		version = 2,
		id = string.rep("a", 64),
		repo_root = "/tmp/native-review-legacy",
		scope = {
			kind = "commit",
			label = "legacy",
			commit_oid = string.rep("b", 40),
		},
		stale = false,
		bridge = {
			backend = "tuicr",
			round = "123e4567-e89b-12d3-a456-426614174000",
		},
		items = {
			{
				id = string.rep("c", 64),
				sequence = 1,
				type = "issue",
				body = "legacy delivered finding",
				anchor = { kind = "general", stale = false },
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {
					{ backend = "tuicr", receipt = "legacy-receipt", delivered_at = "2026-08-25T12:00:00Z" },
				},
			},
		},
	}
	local before = vim.deepcopy(session)
	local markdown = assert(native_review.export.render(session, true))
	assert(markdown:find("legacy delivered finding", 1, true), "legacy item disappeared from export")
	equal(before, session, "rendering rewrote legacy bridge or delivery metadata")
	assert(native_review.controller.publish == nil and native_review.controller.link_tuicr == nil)
	assert(native_review.store.link_tuicr == nil and native_review.store.mark_tuicr_delivered == nil)
	assert(native_review.store.mark_exported == nil and native_review.store.item_status(session.items[1]) == "draft")
end)

test("session preferences override normalized defaults", function()
	equal(
		{ layout = "inline", context = "hunks", inline_comments = true },
		native_review.controller._workspace_preferences(nil, nil),
		"normalized defaults"
	)
	equal(
		{ layout = "split", context = "full", inline_comments = false },
		native_review.controller._workspace_preferences(nil, {
			layout = "split",
			context = "full",
			inline_comments = false,
		}),
		"session preference override"
	)
end)

test("repeated setup replaces adapters, copied status is pure, and teardown is repeatable", function()
	local first = require("native_review.dependencies").get("repo")
	local first_tabs = require("native_review.dependencies").get("tabs")
	equal("first", first.root("first"), "initial adapter")
	local replacement_repo = vim.tbl_extend("force", {}, repo)
	replacement_repo.root = function()
		return "replacement"
	end
	setup({ repo = replacement_repo, tabs = tabs_fixture("replacement-tab"), layout = "split" })
	equal("replacement", first.root("ignored"), "stable adapter proxy did not observe replacement")
	equal("replacement-tab", first_tabs.focus_transient({}), "stable tabs proxy did not observe replacement")

	local status = native_review.status()
	assert(status.configured and status.config.layout == "split")
	status.config.layout = "changed"
	equal("split", native_review.status().config.layout, "status leaked mutable config")
	assert(native_review.teardown())
	assert(native_review.teardown())
	assert(not native_review.status().configured)
	equal("inline", native_review.effective_config().layout, "teardown did not restore defaults")
	setup()
	assert(native_review.status().configured)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("native_review_spec: %d tests passed", count))
vim.cmd("quitall!")
