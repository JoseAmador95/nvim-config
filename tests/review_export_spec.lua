vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

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

local exporter = require("config.review_export")
local oid = string.rep("a", 40)

local function session()
	return {
		repo_root = "/tmp/review-export",
		stale = false,
		scope = { kind = "commit", label = "HEAD", commit_oid = oid },
		items = {
			{
				id = "root",
				type = "rationale",
				status = "draft",
				body = "Why use a tuple instead of the enum directly?",
				reply_to = vim.NIL,
				anchor = {
					path = "lua/config/example.lua",
					side = "right",
					layer = "historical",
					start_line = 8,
					end_line = 8,
					context = "local values = tuple(enum)",
					context_hash = vim.fn.sha256("local values = tuple(enum)"),
					stale = false,
				},
			},
			{
				id = "reply",
				type = "rationale",
				status = "reply",
				body = "The enum can remain the source of truth.",
				reply_to = "root",
				anchor = { path = "lua/config/example.lua", side = "right", start_line = 8 },
			},
		},
	}
end

test("Markdown includes exact scope, context, type, status, and replies", function()
	local markdown, ids = assert(exporter.render(session()))
	assert(markdown:find("Commit: `" .. oid .. "`", 1, true))
	assert(markdown:find("## RATIONALE — lua/config/example.lua:8", 1, true))
	assert(markdown:find("rationale, draft, right, historical", 1, true))
	assert(markdown:find("Context (`", 1, true))
	assert(markdown:find("### Reply: RATIONALE", 1, true))
	assert(vim.deep_equal(ids, { "root", "reply" }))
end)

test("normal export refuses stale unresolved anchors while bang labels them", function()
	local value = session()
	value.items[1].anchor.stale = true
	local markdown, err = exporter.render(value)
	assert(not markdown and err:find("ReviewExport!", 1, true))
	markdown = assert(exporter.render(value, true))
	assert(markdown:find("stale", 1, true))
	value.items[1].anchor.stale = false
	value.stale = true
	markdown = assert(exporter.render(value, true))
	assert(markdown:find("stale", 1, true), "scope drift was not labeled")
end)

test("clipboard failure previews without returning ids to lock", function()
	local previewed
	local result = assert(exporter.deliver(session(), false, {
		has_clipboard = false,
		preview = function(markdown)
			previewed = markdown
		end,
	}))
	assert(result.previewed and #result.ids == 0 and previewed == result.markdown)

	local copied
	result = assert(exporter.deliver(session(), false, {
		has_clipboard = true,
		setreg = function(register, markdown)
			copied = { register, markdown }
		end,
	}))
	assert(not result.previewed and copied[1] == "+" and #result.ids == 2)

	result = assert(exporter.deliver(session(), false, {
		has_clipboard = true,
		setreg = function()
			return 1
		end,
		preview = function(markdown)
			previewed = markdown
		end,
	}))
	assert(result.previewed and #result.ids == 0 and previewed == result.markdown)
end)

test("repeated clipboard previews reuse the existing tab", function()
	local original_tab = vim.api.nvim_get_current_tabpage()
	local first = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	local preview_tab = vim.api.nvim_get_current_tabpage()
	local tab_count = #vim.api.nvim_list_tabpages()
	local second = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	assert(first.previewed and second.previewed)
	assert(vim.api.nvim_get_current_tabpage() == preview_tab)
	assert(#vim.api.nvim_list_tabpages() == tab_count)
	assert(require("config.tabs").is_transient(preview_tab))
	assert(vim.bo.readonly and not vim.bo.modifiable)
	local suspended = assert(exporter.suspend_preview())
	assert(suspended.focused and not vim.api.nvim_tabpage_is_valid(preview_tab))
	assert(exporter.restore_preview(suspended))
	assert(vim.api.nvim_buf_get_name(0) == "review-export://markdown")
	assert(exporter.suspend_preview())
	vim.api.nvim_set_current_tabpage(original_tab)
end)

test("forced clipboard export includes exported comments without relocking them", function()
	local value = session()
	value.items[1].status = "exported"
	value.items[1].export_id = "clipboard:earlier"
	value.items[1].exported_at = "2026-08-25T10:00:00Z"
	local result = assert(exporter.deliver(value, true, {
		has_clipboard = true,
		setreg = function() end,
	}))
	assert(result.markdown:find(value.items[1].body, 1, true))
	assert(vim.deep_equal(result.ids, { "reply" }))
end)

test("incremental export keeps an exported parent as reply context", function()
	local value = session()
	value.items[1].status = "exported"
	value.items[1].export_id = "tuicr:parent"
	value.items[1].exported_at = "2026-08-25T10:00:00Z"
	local markdown, ids = assert(exporter.render(value))
	assert(markdown:find(value.items[1].body, 1, true))
	assert(markdown:find("### Reply: RATIONALE", 1, true))
	assert(vim.deep_equal(ids, { "reply" }))
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_export_spec: %d tests passed", count))
vim.cmd("quitall!")
