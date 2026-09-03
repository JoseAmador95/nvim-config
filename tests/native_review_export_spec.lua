-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/native-review.nvim")
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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

local exporter = require("config.native_review").export
local oid = string.rep("a", 40)

local function session()
	return {
		version = 2,
		revision = 9,
		repo_root = "/tmp/review-export",
		stale = false,
		scope = { kind = "commit", label = "HEAD", commit_oid = oid },
		items = {
			{
				id = "root",
				type = "rationale",
				resolution = "open",
				deliveries = {},
				body = "Why use a tuple instead of the enum directly?",
				reply_to = vim.NIL,
				anchor = {
					kind = "range",
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
				resolution = "open",
				deliveries = {},
				body = "The enum can remain the source of truth.",
				reply_to = "root",
				anchor = { kind = "range", path = "lua/config/example.lua", side = "right", start_line = 8 },
			},
		},
	}
end

test("Markdown includes exact scope, compact anchors, status, and replies", function()
	local markdown, ids = assert(exporter.render(session()))
	assert(markdown:find("Commit: `" .. oid .. "`", 1, true))
	assert(markdown:find("## RATIONALE — lua/config/example.lua:8 [NEW]", 1, true))
	assert(not markdown:find("lua/config/example.lua:8-8", 1, true))
	assert(markdown:find("_draft_", 1, true))
	assert(not markdown:find("Context (`", 1, true))
	assert(not markdown:find("local values = tuple(enum)", 1, true))
	assert(not markdown:find(session().items[1].anchor.context_hash, 1, true))
	assert(not markdown:find("right, historical", 1, true))
	assert(markdown:find("### Reply: RATIONALE — lua/config/example.lua:8 [NEW]", 1, true))
	assert(vim.deep_equal(ids, { "root", "reply" }))
end)

test("Markdown renders old multiline anchors without source context", function()
	local value = session()
	value.items[1].anchor.path = "lua/config/old.lua"
	value.items[1].anchor.side = "left"
	value.items[1].anchor.start_line = 3
	value.items[1].anchor.end_line = 5
	value.items[1].anchor.context = "private old source"
	value.items[1].anchor.context_hash = vim.fn.sha256(value.items[1].anchor.context)
	value.items[2] = nil
	local markdown = assert(exporter.render(value))
	assert(markdown:find("## RATIONALE — lua/config/old.lua:3-5 [OLD]", 1, true))
	assert(not markdown:find("private old source", 1, true))
	assert(not markdown:find(value.items[1].anchor.context_hash, 1, true))
end)

test("Markdown renders file-level comments without inventing a line", function()
	local value = session()
	value.items = {
		{
			id = "file",
			type = "suggestion",
			resolution = "resolved",
			deliveries = {},
			body = "Consider the file-level organization.",
			reply_to = vim.NIL,
			anchor = {
				kind = "file",
				path = "lua/config/example.lua",
				side = "right",
				layer = "historical",
				stale = false,
			},
		},
	}
	local markdown, ids = assert(exporter.render(value))
	assert(markdown:find("## SUGGESTION — lua/config/example.lua [NEW]", 1, true))
	assert(not markdown:find("lua/config/example.lua:1", 1, true))
	assert(vim.deep_equal(ids, { "file" }))
end)

test("Markdown renders review-level comments without a file or side", function()
	local value = session()
	value.items = {
		{
			id = "review",
			type = "praise",
			resolution = "open",
			deliveries = {},
			body = "The review is easy to follow.",
			reply_to = vim.NIL,
			anchor = { kind = "general", stale = false },
		},
	}
	local markdown, ids = assert(exporter.render(value))
	assert(markdown:find("## PRAISE — REVIEW", 1, true))
	assert(not markdown:find("## PRAISE — REVIEW [", 1, true))
	assert(vim.deep_equal(ids, { "review" }))
end)

test("recovery records an intentionally empty live review without changing normal export", function()
	local value = session()
	value.items = {}
	local markdown, export_err = exporter.render(value, true)
	assert(markdown == nil and export_err == "review has no comments to export")
	local recovery, ids = assert(exporter.render_recovery(value))
	assert(recovery:find("Empty live review state", 1, true))
	assert(recovery:find("removed every comment", 1, true))
	assert(vim.deep_equal(ids, {}))
end)

test("normal export refuses stale anchors while bang labels them", function()
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
	assert(not result.previewed and copied[1] == "+" and #result.ids == 0)

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

test("repeated clipboard previews stay in one ordinary tab and replace only their float", function()
	local original_tab = vim.api.nvim_get_current_tabpage()
	local original_win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_get_current_buf()
	local source_lines = {}
	for index = 1, 60 do
		source_lines[index] = "source line " .. index
	end
	vim.bo[original_buf].modifiable = true
	vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, source_lines)
	vim.api.nvim_win_set_cursor(original_win, { 24, 3 })
	vim.api.nvim_win_call(original_win, function()
		vim.cmd("normal! zt")
	end)
	local source_view = vim.api.nvim_win_call(original_win, vim.fn.winsaveview)
	local tab_count = #vim.api.nvim_list_tabpages()
	local first = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	local first_preview = vim.api.nvim_get_current_win()
	local second = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	local second_preview = vim.api.nvim_get_current_win()
	local preview_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_win_set_cursor(second_preview, { 12, 0 })
	vim.api.nvim_win_call(second_preview, function()
		vim.cmd("normal! zt")
	end)
	local preview_view = vim.api.nvim_win_call(second_preview, vim.fn.winsaveview)
	local preview_lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
	assert(first.previewed and second.previewed)
	assert(vim.api.nvim_get_current_tabpage() == original_tab)
	assert(#vim.api.nvim_list_tabpages() == tab_count)
	assert(not vim.api.nvim_win_is_valid(first_preview) and vim.api.nvim_win_is_valid(second_preview))
	assert(vim.api.nvim_buf_get_name(0) == "review-export://markdown")
	assert(vim.bo.readonly and not vim.bo.modifiable)
	local suspended = assert(exporter.suspend_preview())
	assert(suspended.focused and not vim.api.nvim_win_is_valid(second_preview))
	assert(vim.api.nvim_buf_is_valid(preview_buf), "preview buffer was wiped during session serialization")
	assert(not vim.bo[preview_buf].buflisted, "suspended preview could leak into the serialized buffer list")
	assert(#vim.fn.win_findbuf(preview_buf) == 0 and vim.bo[preview_buf].bufhidden == "hide")
	assert(vim.api.nvim_get_current_win() == original_win)
	assert(exporter.restore_preview(suspended))
	local restored_preview = vim.api.nvim_get_current_win()
	assert(restored_preview ~= second_preview and vim.api.nvim_get_current_buf() == preview_buf)
	assert(vim.api.nvim_buf_get_name(0) == "review-export://markdown" and vim.bo[preview_buf].bufhidden == "wipe")
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), preview_lines))
	local restored_view = vim.api.nvim_win_call(restored_preview, vim.fn.winsaveview)
	for _, key in ipairs({ "lnum", "col", "topline", "leftcol", "skipcol", "curswant" }) do
		assert(restored_view[key] == preview_view[key], "preview view changed at " .. key)
	end

	vim.api.nvim_set_current_win(original_win)
	local unfocused = assert(exporter.suspend_preview())
	assert(not unfocused.focused)
	assert(exporter.restore_preview(unfocused))
	assert(vim.api.nvim_get_current_win() == original_win, "unfocused preview stole focus")
	local preview_windows = vim.fn.win_findbuf(preview_buf)
	assert(#preview_windows == 1 and vim.api.nvim_win_is_valid(preview_windows[1]))
	vim.api.nvim_set_current_win(preview_windows[1])
	vim.api.nvim_feedkeys("q", "xt", false)
	assert(vim.api.nvim_get_current_win() == original_win and vim.api.nvim_get_current_buf() == original_buf)
	local restored_source_view = vim.api.nvim_win_call(original_win, vim.fn.winsaveview)
	for _, key in ipairs({ "lnum", "col", "topline", "leftcol", "skipcol", "curswant" }) do
		assert(restored_source_view[key] == source_view[key], "preview source view changed at " .. key)
	end
end)

test("session restoration gives a rebuilt review target to a focused preview", function()
	vim.cmd("only")
	local fallback_win = vim.api.nvim_get_current_win()
	vim.cmd("vnew")
	local old_source_win = vim.api.nvim_get_current_win()
	local result = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	assert(result.previewed)
	local suspended = assert(exporter.suspend_preview())
	assert(suspended.focused and vim.api.nvim_get_current_win() == old_source_win)
	vim.api.nvim_win_close(old_source_win, true)
	assert(exporter.restore_preview(suspended, fallback_win))
	local restored_buf = vim.api.nvim_get_current_buf()
	assert(vim.api.nvim_buf_get_name(restored_buf) == "review-export://markdown")
	vim.api.nvim_feedkeys("q", "xt", false)
	assert(vim.api.nvim_get_current_win() == fallback_win, "preview did not return to the rebuilt review target")
end)

test("failed restore owns its replacement buffer for one exact retry and cleanup", function()
	local source_win = vim.api.nvim_get_current_win()
	local result = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	assert(result.previewed)
	local suspended = assert(exporter.suspend_preview())
	local expired_buf = suspended.buf
	vim.api.nvim_buf_delete(expired_buf, { force = true })
	assert(not vim.api.nvim_buf_is_valid(expired_buf))

	local original_open_win = vim.api.nvim_open_win
	vim.api.nvim_open_win = function()
		error("injected preview open failure")
	end
	local called, restored = pcall(exporter.restore_preview, suspended, source_win)
	vim.api.nvim_open_win = original_open_win
	assert(called and not restored, "injected preview open failure was not reported")

	local replacement_buf = suspended.buf
	assert(replacement_buf ~= expired_buf and vim.api.nvim_buf_is_valid(replacement_buf))
	assert(vim.api.nvim_buf_get_name(replacement_buf) == "review-export://markdown")
	assert(#vim.fn.win_findbuf(replacement_buf) == 0, "failed restore exposed its retained replacement")
	local owned_previews = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == "review-export://markdown" then
			owned_previews[#owned_previews + 1] = buf
		end
	end
	assert(vim.deep_equal(owned_previews, { replacement_buf }), "failed restore orphaned another preview buffer")

	assert(exporter.restore_preview(suspended, source_win), "retained replacement could not be retried")
	assert(vim.api.nvim_get_current_buf() == replacement_buf, "retry created a second replacement buffer")
	vim.api.nvim_feedkeys("q", "xt", false)
	assert(vim.api.nvim_get_current_win() == source_win)
	assert(not vim.api.nvim_buf_is_valid(replacement_buf), "restored replacement was not cleaned up")
end)

test("replacement setup failure removes its allocation and preserves a rival name", function()
	local source_win = vim.api.nvim_get_current_win()
	local result = assert(exporter.deliver(session(), false, { has_clipboard = false }))
	assert(result.previewed)
	local suspended = assert(exporter.suspend_preview())
	vim.api.nvim_buf_delete(suspended.buf, { force = true })

	local rival = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(rival, "review-export://markdown")
	local before = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			before[buf] = true
		end
	end
	local called, restored = pcall(exporter.restore_preview, suspended, source_win)
	assert(called and not restored, "preview name collision was not reported safely")
	assert(vim.api.nvim_buf_is_valid(rival), "replacement setup removed the rival buffer")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		assert(not vim.api.nvim_buf_is_valid(buf) or before[buf], "replacement setup leaked an allocated buffer")
	end

	vim.api.nvim_buf_delete(rival, { force = true })
	assert(exporter.restore_preview(suspended, source_win), "receipt could not retry after setup cleanup")
	local replacement = vim.api.nvim_get_current_buf()
	assert(vim.api.nvim_buf_get_name(replacement) == "review-export://markdown")
	vim.api.nvim_feedkeys("q", "xt", false)
	assert(not vim.api.nvim_buf_is_valid(replacement), "retried replacement was not cleaned up")
end)

test("failed replacement cleanup retains one owned buffer for retry", function()
	local source_win = vim.api.nvim_get_current_win()
	assert(exporter.deliver(session(), false, { has_clipboard = false }).previewed)
	local suspended = assert(exporter.suspend_preview())
	vim.api.nvim_buf_delete(suspended.buf, { force = true })
	local rival = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(rival, "review-export://markdown")

	local original_delete = vim.api.nvim_buf_delete
	vim.api.nvim_buf_delete = function()
		error("injected replacement cleanup failure")
	end
	local called, restored = pcall(exporter.restore_preview, suspended, source_win)
	vim.api.nvim_buf_delete = original_delete
	assert(called and not restored, "double failure was not reported safely")
	local retained = suspended.buf
	assert(vim.api.nvim_buf_is_valid(retained) and retained ~= rival)
	assert(vim.api.nvim_buf_get_name(retained) == "", "partially configured buffer gained the rival name")
	assert(#vim.fn.win_findbuf(retained) == 0, "partially configured buffer became visible")

	vim.api.nvim_buf_delete(rival, { force = true })
	assert(exporter.restore_preview(suspended, source_win), "owned partial buffer could not be retried")
	assert(vim.api.nvim_get_current_buf() == retained, "retry allocated over the retained owned buffer")
	vim.api.nvim_feedkeys("q", "xt", false)
	assert(not vim.api.nvim_buf_is_valid(retained), "retried owned buffer was not cleaned up")
end)

test("clipboard export is complete while legacy delivery history remains inert", function()
	local value = session()
	value.items[1].resolution = "resolved"
	value.items[2].resolution = "legacy_unknown"
	value.items[2].deliveries = {
		{ backend = "tuicr", receipt = "remote-reply", delivered_at = "2026-08-25T10:00:00Z" },
	}
	local result = assert(exporter.deliver(value, false, {
		has_clipboard = true,
		setreg = function() end,
	}))
	assert(result.markdown:find(value.items[1].body, 1, true))
	assert(result.markdown:find(value.items[2].body, 1, true))
	assert(result.markdown:find("resolved", 1, true))
	assert(result.markdown:find("legacy_unknown", 1, true))
	assert(not result.markdown:find("remote%-reply"))
	assert(vim.deep_equal(result.ids, {}))
end)

test("repeated renders and clipboard deliveries are byte-identical and non-mutating", function()
	local value = session()
	local before = vim.deepcopy(value)
	local first_markdown, first_ids = assert(exporter.render(value))
	local second_markdown, second_ids = assert(exporter.render(value))
	assert(first_markdown == second_markdown and vim.deep_equal(first_ids, second_ids))
	local copied = {}
	local first = assert(exporter.deliver(value, false, {
		has_clipboard = true,
		setreg = function(_, markdown)
			copied[#copied + 1] = markdown
		end,
	}))
	local second = assert(exporter.deliver(value, false, {
		has_clipboard = true,
		setreg = function(_, markdown)
			copied[#copied + 1] = markdown
		end,
	}))
	assert(first.markdown == second.markdown and copied[1] == copied[2])
	assert(vim.deep_equal(first.ids, {}) and vim.deep_equal(second.ids, {}))
	assert(vim.deep_equal(value, before) and value.revision == 9)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_export_spec: %d tests passed", count))
vim.cmd("quitall!")
