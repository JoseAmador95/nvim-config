vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

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

local panel = require("config.review_panel")
local review_lsp = require("config.review_lsp")

local function item(id, sequence, kind, path, first, last)
	return {
		id = id,
		sequence = sequence,
		type = sequence == 1 and "issue" or "praise",
		body = "Body " .. sequence,
		anchor = {
			kind = kind,
			path = path,
			side = path and "right" or nil,
			layer = path and "history" or nil,
			start_line = first,
			end_line = last,
			stale = false,
		},
		reply_to = vim.NIL,
		resolution = "open",
		deliveries = {},
	}
end

local workspace = {
	root = "/tmp/example-repository",
	layout = "split",
	context = "full",
	scope = { label = "base…head", kind = "range" },
	session = {
		id = string.rep("a", 64),
		items = {
			item(string.rep("1", 64), 1, "general"),
			item(string.rep("2", 64), 2, "file", "lua/example.lua"),
			item(string.rep("3", 64), 3, "range", "lua/example.lua", 3, 5),
		},
	},
	model = {
		entries = {
			{
				identity = "history\0lua/old.lua\0lua/example.lua",
				status = "R",
				old_path = "lua/old.lua",
				new_path = "lua/example.lua",
				path = "lua/example.lua",
				renamed = true,
			},
		},
		commits = {
			{ oid = string.rep("a", 40), date = "2026-08-24", author = "A", subject = "First" },
			{ oid = string.rep("b", 40), date = "2026-08-25", author = "B", subject = "Second" },
		},
	},
}

test("three core floats preserve the ordinary tab and expose all panel roles", function()
	vim.cmd("only")
	vim.cmd("enew!")
	local source = vim.api.nvim_get_current_win()
	local tabs = #vim.api.nvim_list_tabpages()
	local calls = {}
	local state = panel.new(workspace, {
		select_entry = function(identity)
			calls.entry = identity
		end,
		file_comment = function(identity)
			calls.file_comment = identity
		end,
		apply_commit = function(first, second)
			calls.commit = { first, second }
		end,
		edit_comment = function(id)
			calls.edit = id
		end,
		reanchor_comment = function(id, source_win)
			calls.reanchor = { id = id, source_win = source_win, current_win = vim.api.nvim_get_current_win() }
		end,
	})
	assert(panel.open(state, "files"))
	assert(#vim.api.nvim_list_tabpages() == tabs)
	for _, name in ipairs({ "files", "commits", "comments" }) do
		local pane = state.panes[name]
		assert(vim.api.nvim_win_is_valid(pane.win) and vim.api.nvim_buf_is_valid(pane.buf))
		assert(vim.bo[pane.buf].buftype == "nofile" and not vim.bo[pane.buf].buflisted)
		assert(vim.bo[pane.buf].bufhidden == "wipe" and not vim.bo[pane.buf].swapfile)
		assert(vim.b[pane.buf].nvim_review_panel_role == name and review_lsp.blocked(pane.buf))
	end
	local header = vim.api.nvim_buf_get_lines(state.panes.files.buf, 0, 1, false)[1]
	assert(header:find("repo=example-repository", 1, true))
	assert(header:find("scope=base…head", 1, true) and header:find("comments=3", 1, true))
	local file_row = vim.api.nvim_buf_get_lines(state.panes.files.buf, 3, 4, false)[1]
	assert(file_row:find("[R][history]", 1, true) and file_row:find("lua/old.lua -> lua/example.lua", 1, true))
	assert(file_row:find("(2)", 1, true), "file comment count was not rendered")
	workspace.session.items[2].body = string.rep("á🙂", 40)
	panel.refresh(state)
	local unicode_row = vim.api.nvim_buf_get_lines(state.panes.comments.buf, 3, 4, false)[1]
	assert(pcall(vim.str_utfindex, unicode_row), "comment preview contains invalid UTF-8")
	assert(unicode_row:find("…", 1, true), "long Unicode comment was not truncated")

	vim.api.nvim_win_set_cursor(state.panes.files.win, { 4, 0 })
	vim.api.nvim_set_current_win(state.panes.files.win)
	vim.fn.maparg("<CR>", "n", false, true).callback()
	assert(calls.entry == workspace.model.entries[1].identity)
	vim.fn.maparg("<leader>rA", "n", false, true).callback()
	assert(calls.file_comment == workspace.model.entries[1].identity)

	panel.focus(state, "commits")
	vim.api.nvim_win_set_cursor(state.panes.commits.win, { 3, 0 })
	vim.fn.maparg("<Space>", "n", false, true).callback()
	vim.api.nvim_win_set_cursor(state.panes.commits.win, { 4, 0 })
	vim.fn.maparg("<Space>", "n", false, true).callback()
	vim.fn.maparg("<CR>", "n", false, true).callback()
	assert(calls.commit[1] == workspace.model.commits[1].oid and calls.commit[2] == workspace.model.commits[2].oid)

	panel.focus(state, "comments")
	vim.api.nvim_win_set_cursor(state.panes.comments.win, { 4, 0 })
	vim.fn.maparg("e", "n", false, true).callback()
	assert(calls.edit == workspace.session.items[2].id, "comment callback did not receive a stable ID")
	vim.fn.maparg("m", "n", false, true).callback()
	assert(calls.reanchor.id == workspace.session.items[2].id)
	assert(calls.reanchor.source_win == source, "reanchor did not receive the panel source window")
	assert(calls.reanchor.current_win == state.panes.comments.win, "reanchor changed panel focus before callback")

	local comments_win = state.panes.comments.win
	vim.api.nvim_win_close(comments_win, true)
	assert(panel.hide(state), "partial teardown was not idempotent")
	assert(vim.api.nvim_get_current_win() == source and #vim.api.nvim_list_tabpages() == tabs)
	assert(panel.open(state, "comments"))
	assert(vim.api.nvim_win_get_cursor(state.panes.comments.win)[1] == 4, "comment selection was not restored")
	panel.reflow(state)
	panel.close(state)
	assert(vim.api.nvim_get_current_win() == source and #vim.api.nvim_list_tabpages() == tabs)
end)

test("presentation replacement refreshes reanchor source without accepting panel floats", function()
	vim.cmd("only")
	vim.cmd("enew!")
	local replacement = vim.api.nvim_get_current_win()
	vim.cmd("rightbelow vnew")
	local previous = vim.api.nvim_get_current_win()
	local calls = {}
	local state = panel.new(workspace, {
		reanchor_comment = function(id, source_win)
			calls.reanchor = { id = id, source_win = source_win, current_win = vim.api.nvim_get_current_win() }
		end,
	})
	assert(panel.open(state, "comments"))
	assert(state.source_win == previous, "panel did not capture the current split target")

	vim.api.nvim_win_close(previous, true)
	assert(not vim.api.nvim_win_is_valid(previous), "simulated layout transition retained the old split")
	assert(panel.update_source(state, replacement) == replacement, "new inline target did not replace the stale source")
	local comments_win = state.panes.comments.win
	assert(
		panel.update_source(state, comments_win) == replacement and state.source_win == replacement,
		"panel float/nofile replaced the reviewed-code source"
	)

	vim.api.nvim_set_current_win(replacement)
	vim.cmd("rightbelow new")
	local trouble_like = vim.api.nvim_get_current_win()
	vim.bo.buftype = "nofile"
	assert(panel.open(state, "comments"), "panel did not reopen from an ordinary nofile split")
	assert(state.source_win == replacement, "ordinary nofile split replaced the reviewed-code source")
	vim.b[vim.api.nvim_win_get_buf(trouble_like)].nvim_review_role = "snapshot"
	assert(panel.update_source(state, trouble_like) == trouble_like, "presented snapshot was rejected as a source")
	assert(panel.update_source(state, replacement) == replacement, "real source was not restored after snapshot check")
	vim.api.nvim_win_close(trouble_like, true)

	panel.focus(state, "comments")
	vim.api.nvim_win_set_cursor(state.panes.comments.win, { 4, 0 })
	vim.fn.maparg("m", "n", false, true).callback()
	assert(calls.reanchor.id == workspace.session.items[2].id)
	assert(calls.reanchor.source_win == replacement and vim.api.nvim_win_is_valid(calls.reanchor.source_win))
	assert(calls.reanchor.current_win == comments_win, "source refresh changed panel focus before reanchor")
	panel.close(state)
	assert(vim.api.nvim_get_current_win() == replacement, "panel did not restore the refreshed source")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_panel_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
