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

local native_review = require("native_review").setup({
	repo = repo,
	fs = {},
	editor = {
		open_file_in_tab = function() end,
	},
	local_config = {
		get = function(_, defaults)
			return vim.deepcopy(defaults)
		end,
	},
	lsp_navigation = {},
})

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

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("native_review_spec: %d tests passed", count))
vim.cmd("quitall!")
