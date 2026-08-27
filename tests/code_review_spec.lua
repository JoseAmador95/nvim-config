vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "

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

local review = require("config.code_review")

test("ReviewOpen parser keeps the exact native scope vocabulary", function()
	assert(vim.deep_equal(review._parse_open({}), { kind = "branch" }))
	assert(vim.deep_equal(review._parse_open({ "working" }), { kind = "working" }))
	assert(vim.deep_equal(review._parse_open({ "commit", "topic" }), { kind = "commit", rev = "topic" }))
	assert(vim.deep_equal(review._parse_open({ "commit" }), { kind = "commit", rev = "HEAD" }))
	assert(vim.deep_equal(review._parse_open({ "range", "base", "head" }), {
		kind = "range",
		from = "base",
		to = "head",
	}))
	assert(vim.deep_equal(review._parse_open({ "branch", "origin/main", "HEAD" }), {
		kind = "branch",
		base = "origin/main",
		head = "HEAD",
	}))
	assert(review._parse_open({ "range", "missing" }) == nil)
	assert(review._parse_open({ "tuicr", "round" }) == nil)
end)

test("mapping table uses only the approved lowercase review vocabulary", function()
	local expected = {
		"<leader>rr",
		"<leader>ro",
		"<leader>rm",
		"<leader>rs",
		"<leader>rb",
		"<leader>rf",
		"<leader>rh",
		"<leader>rl",
		"<leader>rv",
		"<leader>rw",
		"<leader>ri",
		"<leader>rg",
		"<leader>ra",
		"<leader>rA",
		"<leader>re",
		"<leader>rc",
		"<leader>rd",
		"<leader>rp",
		"<leader>rt",
		"<leader>rE",
		"<leader>ru",
		"<leader>rq",
		"]r",
		"[r",
	}
	local actual = vim.tbl_map(function(mapping)
		assert(not mapping.lhs:find("<leader>R", 1, true), "uppercase review-prefix alias survived")
		return mapping.lhs
	end, review.mapping_specs())
	assert(vim.deep_equal(actual, expected))
	assert(review.help_groups().common == "review")
end)

test("inline comment previews use status, range, first content, and Unicode-safe ellipsis", function()
	local item = {
		type = "suggestion",
		body = "  \n\t  \ná🙂 first content\nsecond line",
		anchor = { kind = "range", start_line = 3, end_line = 5 },
		reply_to = vim.NIL,
		resolution = "open",
		deliveries = {},
	}
	local multiline = review._inline_preview_text(item, 80)
	assert(multiline:find("[suggestion][draft] L3-5", 1, true))
	assert(multiline:find("á🙂 first content", 1, true) and multiline:sub(-3) == "…")
	assert(pcall(vim.str_utfindex, multiline), "multiline preview contains invalid UTF-8")

	item.body = string.rep("á🙂", 80)
	item.anchor.end_line = item.anchor.start_line
	local truncated = review._inline_preview_text(item, 34)
	assert(truncated:find("L3", 1, true) and truncated:sub(-3) == "…")
	assert(pcall(vim.str_utfindex, truncated), "truncated preview contains invalid UTF-8")

	item.body = "short body"
	local short = review._inline_preview_text(item, 80)
	assert(short:find("short body", 1, true) and short:sub(-3) ~= "…")
end)

test("inclusive cursor matching covers multiline overlaps", function()
	local location = { path = "lua/example.lua", side = "right", layer = "history", line = 5 }
	assert(review._contains_line({
		kind = "range",
		path = location.path,
		side = location.side,
		layer = location.layer,
		start_line = 3,
		end_line = 5,
	}, location))
	assert(not review._contains_line({
		kind = "file",
		path = location.path,
		side = location.side,
		layer = location.layer,
	}, location))
end)

test("overlapping comment rails render one visible aggregate marker", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
	vim.b[buf].nvim_review_path = "lua/example.lua"
	vim.b[buf].nvim_review_side = "right"
	vim.b[buf].nvim_review_layer = "history"
	local workspace = {
		root = "/tmp/review-aggregate",
		session = {
			items = {
				{
					sequence = 1,
					type = "issue",
					anchor = {
						kind = "range",
						path = "lua/example.lua",
						side = "right",
						layer = "history",
						start_line = 2,
						end_line = 2,
					},
				},
				{
					sequence = 2,
					type = "question",
					anchor = {
						kind = "range",
						path = "lua/example.lua",
						side = "right",
						layer = "history",
						start_line = 1,
						end_line = 3,
					},
				},
			},
		},
	}
	review.decorate_buffer(workspace, buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 1, 0 }, { 1, -1 }, { details = true })
	assert(
		#marks == 1 and vim.trim(marks[1][4].sign_text or "") == "2",
		"overlapping comments did not aggregate: " .. vim.inspect(marks)
	)
	assert(marks[1][4].virt_text[1][1]:find("2 review comments", 1, true))
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("open presents in the ordinary tab, opens the native panel, and close owns no tab", function()
	local scope_module = require("config.review_scope")
	local store = require("config.review_store")
	local changes = require("config.review_changes")
	local mode = require("config.review_mode")
	local presenter = require("config.review_presenter")
	local panel = require("config.review_panel")
	local exporter = require("config.review_export")
	local tuicr = require("config.review_tuicr")
	local editor_module = require("config.review_editor")
	local originals = {
		resolve = scope_module.resolve,
		load = store.load,
		new = store.new,
		save = store.save,
		edit = store.edit,
		mark_tuicr_delivered = store.mark_tuicr_delivered,
		save_recovery = store.save_recovery,
		verify_recovery = store.verify_recovery,
		build = changes.build,
		selection_request = changes.selection_request,
		detect_drift = scope_module.detect_drift,
		mode_new = mode.new,
		enable = mode.enable,
		disable = mode.disable,
		mode_suspend = mode.suspend,
		mode_restore = mode.restore,
		enroll_affected_buffer = mode.enroll_affected_buffer,
		show = presenter.show,
		clear = presenter.clear,
		current_target = presenter.current_target,
		refresh_winbars = presenter.refresh_winbars,
		panel_new = panel.new,
		panel_open = panel.open,
		panel_refresh = panel.refresh,
		panel_update_source = panel.update_source,
		panel_hide = panel.hide,
		panel_close = panel.close,
		panel_suspend = panel.suspend,
		panel_restore = panel.restore,
		deliver = exporter.deliver,
		render = exporter.render,
		render_recovery = exporter.render_recovery,
		suspend_preview = exporter.suspend_preview,
		restore_preview = exporter.restore_preview,
		tuicr_add = tuicr.add,
		tuicr_respond = tuicr.respond,
		editor_compose = editor_module.compose,
		editor_has_active = editor_module.has_active,
	}
	local repository = "/tmp/native-review-controller"
	local scope = {
		id = string.rep("a", 64),
		kind = "commit",
		label = "HEAD",
		root = repository,
	}
	local broken_scope = {
		id = string.rep("b", 64),
		kind = "commit",
		label = "BROKEN",
		root = repository,
	}
	local child_scope = {
		id = string.rep("c", 64),
		kind = "commit",
		label = "CHILD-FROZEN",
		root = repository,
	}
	local function session_for(value)
		return {
			id = value.id,
			repo_root = repository,
			scope = value,
			stale = false,
			revision = 0,
			items = {},
		}
	end
	local entry = {
		identity = "history\0old.lua\0new.lua",
		old_path = "old.lua",
		new_path = "new.lua",
		path = "new.lua",
	}
	local child_entry = {
		identity = "history\0child-old.lua\0child.lua",
		old_path = "child-old.lua",
		new_path = "child.lua",
		path = "child.lua",
		layer = "history",
	}
	local calls = {
		built = 0,
		enabled = 0,
		disabled = 0,
		shown = 0,
		opened = 0,
		closed = 0,
		delivered = 0,
		loaded = 0,
		resolved = 0,
		verified = 0,
		enrolled = 0,
		panel_refreshed = 0,
		source_updates = 0,
		winbars_refreshed = 0,
		trouble_refreshed = 0,
		tuicr = 0,
		composed = {},
	}
	local notifications = {}
	local review_events = {}
	local original_trouble = package.loaded.trouble
	package.loaded.trouble = {
		refresh = function(mode_name)
			assert(mode_name == "review")
			calls.trouble_refreshed = calls.trouble_refreshed + 1
			local snapshot = assert(review.snapshot(true))
			calls.trouble_anchor = snapshot.items[1] and snapshot.items[1].anchor.start_line or nil
		end,
	}
	local original_file_comment = review.file_comment
	local original_notify = vim.notify
	vim.notify = function(value)
		notifications[#notifications + 1] = tostring(value)
	end
	scope_module.resolve = function(root_value, request)
		assert(root_value == repository and request.kind == "commit")
		calls.resolved = calls.resolved + 1
		if request.rev == "BROKEN" then
			return broken_scope
		elseif request.rev == "CHILD" then
			return child_scope
		end
		return scope
	end
	local function load_live(root_value, id)
		assert(root_value == repository)
		calls.loaded = calls.loaded + 1
		local workspace = review._active_workspace()
		if workspace and workspace.session.id == id then
			return vim.deepcopy(workspace.session)
		end
		return nil, "review state file is missing"
	end
	store.load = load_live
	store.new = function(_, value)
		return vim.deepcopy(session_for(value))
	end
	store.save = function(_, value)
		local copy = vim.deepcopy(value)
		copy.revision = copy.revision + 1
		return copy
	end
	store.edit = function(value, id, fields)
		local copy = vim.deepcopy(value)
		for _, item in ipairs(copy.items) do
			if item.id == id then
				item.type = fields.type
				item.body = fields.body
				item.anchor = vim.deepcopy(fields.anchor)
				return copy
			end
		end
		return nil, "review item does not exist"
	end
	changes.build = function(root_value, scope_value)
		assert(
			root_value == repository
				and (scope_value == scope or scope_value == broken_scope or scope_value == child_scope)
		)
		calls.built = calls.built + 1
		return { entries = { scope_value == child_scope and child_entry or entry }, commits = {}, scope = scope_value }
	end
	changes.selection_request = function(_, first, second)
		assert(first == "child-oid" and second == nil)
		return { kind = "commit", rev = "CHILD" }
	end
	mode.new = function(workspace)
		return {
			workspace = workspace,
			origin = { tab = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win() },
			enabled = false,
		}
	end
	mode.enable = function(state)
		calls.enabled = calls.enabled + 1
		if state.workspace.scope.id == broken_scope.id or state.workspace.fail_enable then
			return nil, "simulated activation failure"
		end
		state.enabled = true
		return true
	end
	mode.disable = function(state)
		calls.disabled = calls.disabled + 1
		state.enabled = false
		state.presentation = nil
		if vim.api.nvim_win_is_valid(state.origin.win) then
			vim.api.nvim_set_current_tabpage(state.origin.tab)
			vim.api.nvim_set_current_win(state.origin.win)
		end
	end
	mode.suspend = function(state)
		local snapshot = { enabled = state.enabled }
		state.enabled = false
		return snapshot
	end
	mode.restore = function(state, snapshot)
		if state.workspace.fail_restore then
			return nil, "simulated restore failure"
		end
		state.enabled = snapshot.enabled
		return true
	end
	mode.enroll_affected_buffer = function(state, buf)
		assert(state.workspace == review._active_workspace() and vim.api.nvim_buf_is_valid(buf))
		calls.enrolled = calls.enrolled + 1
		return true
	end
	presenter.show = function(state, selected, options)
		calls.shown = calls.shown + 1
		assert(selected == state.workspace.model.entries[1])
		assert(options.layout == state.workspace.layout and options.context == state.workspace.context)
		vim.api.nvim_set_current_tabpage(state.origin.tab)
		vim.api.nvim_set_current_win(state.origin.win)
		local target = {
			win = vim.api.nvim_get_current_win(),
			buf = vim.api.nvim_get_current_buf(),
			side = "new",
		}
		vim.b[target.buf].nvim_review_path = selected.new_path
		vim.b[target.buf].nvim_review_side = "right"
		vim.b[target.buf].nvim_review_layer = selected.layer or "history"
		state.presentation = { target = target, inline = target, entry = selected }
		return true
	end
	presenter.clear = function(state)
		state.presentation = nil
	end
	presenter.current_target = function(state)
		return state.presentation and state.presentation.target
	end
	presenter.refresh_winbars = function(state)
		assert(state.workspace == review._active_workspace())
		calls.winbars_refreshed = calls.winbars_refreshed + 1
		return state.presentation ~= nil
	end
	panel.new = function(workspace, callbacks)
		return {
			workspace = workspace,
			callbacks = callbacks,
			visible = false,
			focused = "files",
			source_win = vim.api.nvim_get_current_win(),
		}
	end
	panel.open = function(state)
		calls.opened = calls.opened + 1
		state.visible = true
		return true
	end
	panel.refresh = function()
		calls.panel_refreshed = calls.panel_refreshed + 1
		return true
	end
	panel.update_source = function(state, source_win)
		if source_win and vim.api.nvim_win_is_valid(source_win) then
			calls.source_updates = calls.source_updates + 1
			state.source_win = source_win
			return source_win
		end
		return vim.api.nvim_win_is_valid(state.source_win or -1) and state.source_win or nil
	end
	panel.hide = function(state)
		state.visible = false
		return true
	end
	panel.close = function(state)
		calls.closed = calls.closed + 1
		state.visible = false
		return true
	end
	panel.suspend = function(state)
		local snapshot = { visible = state.visible, focused = state.focused }
		state.visible = false
		return snapshot
	end
	panel.restore = function(state, snapshot)
		state.visible = snapshot and snapshot.visible == true
		state.focused = snapshot and snapshot.focused or state.focused
		return true
	end
	exporter.deliver = function(value, force)
		calls.delivered = calls.delivered + 1
		assert(value.id == scope.id)
		return { markdown = "complete", previewed = false, ids = {} }
	end
	exporter.render = function(value, force)
		assert(value.id == scope.id and force)
		return value.stale and "stale exact snapshot" or "unsaved live review", {}
	end
	exporter.render_recovery = function(value)
		assert(value.id == scope.id)
		return value.stale and "stale exact snapshot" or "unsaved live review", {}
	end
	exporter.suspend_preview = function()
		return nil
	end
	exporter.restore_preview = function(state, source_win)
		assert(state == nil)
		local workspace = assert(review._active_workspace())
		assert(source_win == workspace.mode_state.presentation.target.win)
		return true
	end
	store.save_recovery = function(root_value, value, markdown)
		assert(root_value == repository and value.id == scope.id)
		assert(markdown == (value.stale and "stale exact snapshot" or "unsaved live review"))
		return { path = "/tmp/review-recovery.md", digest = string.rep("b", 64) }
	end
	store.verify_recovery = function(root_value, receipt)
		assert(root_value == repository and receipt.path == "/tmp/review-recovery.md")
		calls.verified = calls.verified + 1
		return true
	end
	tuicr.add = function()
		calls.tuicr = calls.tuicr + 1
		error("unexpected TUICR add")
	end
	tuicr.respond = function()
		calls.tuicr = calls.tuicr + 1
		error("unexpected TUICR response")
	end
	editor_module.compose = function(options, callback)
		calls.composed[#calls.composed + 1] = { options = vim.deepcopy(options), callback = callback }
		return true
	end
	review.file_comment = function()
		calls.file_comment = (calls.file_comment or 0) + 1
	end

	local ok, err = xpcall(function()
		vim.cmd("only")
		vim.api.nvim_create_autocmd("User", {
			group = vim.api.nvim_create_augroup("NvimConfigReviewChangedSpec", { clear = true }),
			pattern = "NvimConfigReviewChanged",
			callback = function(event)
				review_events[#review_events + 1] = vim.deepcopy(event.data)
			end,
		})
		local tabs = #vim.api.nvim_list_tabpages()
		local workspace = assert(review.open({ kind = "commit", rev = "HEAD" }, repository))
		assert(#review_events == 1, "open did not emit one stable review state")
		assert(#vim.api.nvim_list_tabpages() == tabs)
		assert(workspace.entry_identity == entry.identity and calls.shown == 1 and calls.opened == 1)
		assert(calls.source_updates == 1 and workspace.panel.source_win == workspace.mode_state.presentation.target.win)
		local status = review.status()
		assert(status.active and status.mode_on and status.scope_kind == "commit" and status.scope_label == "HEAD")
		assert(status.layout == "inline" and status.context == "hunks" and status.inline_comments)
		assert(vim.deep_equal(status.entry, {
			identity = entry.identity,
			path = "new.lua",
			layer = "history",
			side = "CURRENT",
		}))
		status.entry.path = "mutated"
		review_events[1].entry.path = "also mutated"
		assert(review.status().entry.path == "new.lua", "status/event data was not detached")
		assert(workspace.inline_comments == true and workspace.session.inline_comments == nil)
		assert(review.inline_comments("off") and workspace.inline_comments == false)
		workspace = assert(review.open({ kind = "commit", rev = "HEAD" }, repository))
		assert(workspace.inline_comments == false, "same exact workspace lost its transient inline-comment preference")
		assert(workspace.session.inline_comments == nil and calls.shown == 2 and calls.opened == 2)
		local winbars_before_toggle = calls.winbars_refreshed
		assert(review.inline_comments("on") and workspace.inline_comments == true)
		assert(calls.winbars_refreshed == winbars_before_toggle + 1, "inline toggle did not refresh review winbars")
		assert(review.mode("off") and not workspace.mode_on and workspace.panel.visible)
		assert(review_events[#review_events].mode_on == false and review.status().entry.side == "CURRENT")
		local show_before_failure = presenter.show
		local events_before_failed_mode = #review_events
		presenter.show = function()
			return nil, "simulated presentation failure"
		end
		assert(not review.mode("on") and not workspace.mode_on)
		assert(#review_events == events_before_failed_mode, "failed mode activation emitted review state")
		presenter.show = show_before_failure
		assert(review.mode("on") and workspace.mode_on and calls.shown == 3)
		workspace.panel.visible = false
		vim.cmd("tabnew")
		local session_focus_tab = vim.api.nvim_get_current_tabpage()
		local session_focus_win = vim.api.nvim_get_current_win()
		local session_focus_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(session_focus_buf, 0, -1, false, { "outside", "the", "review" })
		vim.api.nvim_win_set_cursor(session_focus_win, { 2, 1 })
		assert(review.suspend_for_session(), "review UI did not suspend from an unrelated tab")
		assert(review.restore_after_session(), "review UI did not restore from an unrelated tab")
		assert(vim.api.nvim_get_current_tabpage() == session_focus_tab, "session restore stole the active tab")
		assert(vim.api.nvim_get_current_win() == session_focus_win, "session restore stole the active window")
		assert(vim.api.nvim_get_current_buf() == session_focus_buf, "session restore replaced the active buffer")
		assert(vim.deep_equal(vim.api.nvim_win_get_cursor(session_focus_win), { 2, 1 }), "session restore lost view")
		vim.cmd("tabclose")
		workspace.panel.visible = true
		workspace.panel.callbacks.file_comment(entry.identity)
		assert(calls.shown == 5 and calls.file_comment == 1 and not workspace.panel.visible)
		review.file_comment = original_file_comment

		local parent = workspace
		local parent_session = parent.session
		local parent_model = parent.model
		local parent_scope = parent.scope
		local parent_panel = parent.panel
		parent.layout = "split"
		parent.context = "full"
		parent.inline_comments = false
		parent.panel.visible = true
		parent.panel.focused = "commits"
		parent.panel.endpoints = { first = "frozen-first", second = "frozen-second" }
		local resolved_before_child = calls.resolved
		local built_before_child = calls.built
		local events_before_child = #review_events
		parent.panel.callbacks.apply_commit("child-oid")
		local child = assert(review._active_workspace())
		assert(child ~= parent and child.scope.id == child_scope.id and child.scope.label == "CHILD-FROZEN")
		assert(#review._scope_history == 1)
		assert(child.layout == "split" and child.context == "full" and child.inline_comments == false)
		assert(calls.resolved == resolved_before_child + 1 and calls.built == built_before_child + 1)
		assert(#review_events == events_before_child + 1, "commit drill-in did not emit one stable state")

		parent.fail_enable = true
		local events_before_failed_back = #review_events
		local backed, back_err = child.panel.callbacks.scope_back()
		assert(backed == nil and back_err:find("simulated activation failure", 1, true))
		assert(review._active_workspace() == child and child.mode_on and #review._scope_history == 1)
		assert(#review_events == events_before_failed_back, "failed parent restore emitted an intermediate state")
		parent.fail_enable = nil
		assert(child.panel.callbacks.scope_back(), "scope back did not restore the frozen parent")
		workspace = assert(review._active_workspace())
		assert(workspace == parent and workspace.session == parent_session and workspace.model == parent_model)
		assert(workspace.scope == parent_scope and workspace.panel == parent_panel and #review._scope_history == 0)
		assert(workspace.entry_identity == entry.identity and workspace.mode_on)
		assert(workspace.layout == "split" and workspace.context == "full" and workspace.inline_comments == false)
		assert(workspace.panel.visible and workspace.panel.focused == "commits")
		assert(vim.deep_equal(workspace.panel.endpoints, { first = "frozen-first", second = "frozen-second" }))
		assert(calls.resolved == resolved_before_child + 1, "scope back resolved moving refs")
		assert(calls.built == built_before_child + 1, "scope back rebuilt the frozen model")

		assert(not review.scope_back())
		assert(notifications[#notifications] == "Already at full review scope")

		workspace.panel.callbacks.apply_commit("child-oid")
		child = assert(review._active_workspace())
		assert(#review._scope_history == 1)
		local events_before_failed_open = #review_events
		local failed_manual = review.open({ kind = "commit", rev = "BROKEN" }, repository)
		assert(failed_manual == nil and review._active_workspace() == child and #review._scope_history == 1)
		assert(#review_events == events_before_failed_open, "failed manual activation emitted review state")
		assert(child.panel.callbacks.scope_back() and review._active_workspace() == parent)

		parent.panel.callbacks.apply_commit("child-oid")
		assert(#review._scope_history == 1)
		workspace = assert(review.open({ kind = "commit", rev = "HEAD" }, repository))
		assert(#review._scope_history == 0, "successful manual open retained nested scope history")
		assert(not review.scope_back() and notifications[#notifications] == "Already at full review scope")
		workspace.fail_restore = true
		assert(review.suspend_for_session())
		local events_before_failed_restore = #review_events
		local restored, restore_err = review.restore_after_session()
		assert(restored == nil and restore_err:find("simulated restore failure", 1, true))
		assert(#review_events == events_before_failed_restore, "failed session restore emitted intermediate state")
		workspace.fail_restore = nil
		assert(review.mode("on"), "review mode did not recover after failed session restore")

		local source_win = workspace.panel.source_win
		local source_buf = vim.api.nvim_win_get_buf(source_win)
		vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "one", "two", "three", "four", "five", "six" })
		vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
		local comment_id = string.rep("c", 64)
		workspace.session.items = {
			{
				id = comment_id,
				type = "issue",
				body = "Move this range",
				anchor = {
					kind = "range",
					path = "new.lua",
					side = "right",
					layer = "history",
					start_line = 1,
					end_line = 2,
					stale = true,
				},
			},
		}
		vim.cmd("botright new")
		local comments_win = vim.api.nvim_get_current_win()
		vim.bo.buftype = "nofile"
		workspace.panel.visible = true
		workspace.panel.callbacks.reanchor_comment(comment_id, source_win)
		local moved = workspace.session.items[1].anchor
		assert(moved.start_line == 3 and moved.end_line == 4, "multiline reanchor did not preserve its range")
		assert(moved.path == "new.lua" and moved.side == "right" and moved.layer == "history")
		assert(not moved.stale and vim.api.nvim_get_current_win() == comments_win)
		vim.api.nvim_win_close(comments_win, true)
		vim.api.nvim_set_current_win(source_win)
		workspace.session.items = {}
		review.setup()
		calls.enrolled = 0
		vim.api.nvim_exec_autocmds("BufEnter", { buffer = vim.api.nvim_get_current_buf() })
		assert(calls.enrolled == 1, "BufEnter did not enroll an affected buffer opened during review mode")

		local command = vim.api.nvim_get_commands({ builtin = false }).ReviewInlineComments
		assert(command and command.nargs == "?", "ReviewInlineComments command is missing or has the wrong arity")
		assert(vim.api.nvim_get_commands({ builtin = false }).ReviewScopeBack, "ReviewScopeBack command is missing")
		local inline_mapping = vim.fn.maparg("<leader>ri", "n", false, true)
		assert((inline_mapping.rhs or ""):lower() == "<cmd>reviewinlinecomments<cr>", vim.inspect(inline_mapping))
		local back_mapping = vim.fn.maparg("<leader>rb", "n", false, true)
		assert((back_mapping.rhs or ""):lower() == "<cmd>reviewscopeback<cr>", vim.inspect(back_mapping))
		vim.cmd("ReviewInlineComments off")
		assert(workspace.inline_comments == false)
		vim.cmd("ReviewInlineComments on")
		assert(workspace.inline_comments == true and workspace.session.inline_comments == nil)

		local function preview_marks()
			return vim.api.nvim_buf_get_extmarks(source_buf, review._preview_namespace, 0, -1, { details = true })
		end
		local function rail_count()
			local count = 0
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })) do
				if mark[4].sign_text and vim.trim(mark[4].sign_text) ~= "" then
					count = count + 1
				end
			end
			return count
		end
		local function preview_item(sequence, type_name, body, first, last)
			return {
				id = string.rep(tostring(sequence), 64),
				sequence = sequence,
				type = type_name,
				body = body,
				anchor = {
					kind = "range",
					path = "new.lua",
					side = "right",
					layer = "history",
					start_line = first,
					end_line = last,
					stale = false,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			}
		end
		local second = preview_item(2, "suggestion", "  \nsecond visible line\ncontinued", 1, 4)
		local first = preview_item(1, "issue", string.rep("á🙂", 80), 2, 4)
		local third = preview_item(3, "praise", "short praise", 3, 5)
		local file_item = {
			id = string.rep("f", 64),
			sequence = 4,
			type = "question",
			body = "file body",
			anchor = { kind = "file", path = "new.lua", side = "right", layer = "history", stale = false },
			reply_to = vim.NIL,
			resolution = "open",
			deliveries = {},
		}
		local unrelated = preview_item(5, "pedantic", "wrong side", 1, 4)
		unrelated.anchor.side = "left"
		workspace.session.items = { second, first, third, file_item, unrelated }
		vim.api.nvim_set_current_win(source_win)
		vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
		review.refresh_marks(workspace)
		local rails = rail_count()
		assert(rails > 0, "range comments did not render rails before passive preview")
		vim.api.nvim_exec_autocmds("CursorHold", { buffer = source_buf, modeline = false })
		local marks = preview_marks()
		assert(#marks == 2 and marks[1][2] == 3 and marks[2][2] == 4, vim.inspect(marks))
		assert(#marks[1][4].virt_lines == 2 and #marks[2][4].virt_lines == 1)
		local first_text = marks[1][4].virt_lines[1][1][1]
		local second_text = marks[1][4].virt_lines[2][1][1]
		assert(first_text:find("[issue][draft] L2-4", 1, true) and first_text:sub(-3) == "…")
		assert(second_text:find("[suggestion][draft] L1-4", 1, true))
		assert(second_text:find("second visible line", 1, true) and second_text:sub(-3) == "…")
		assert(pcall(vim.str_utfindex, first_text) and pcall(vim.str_utfindex, second_text))

		review._clear_inline_preview()
		vim.bo[source_buf].buftype = "nofile"
		vim.b[source_buf].nvim_review_role = "snapshot"
		assert(review._show_inline_preview(), "historical review snapshot did not render passive comments")
		vim.bo[source_buf].buftype = ""
		vim.b[source_buf].nvim_review_role = nil

		vim.cmd("ReviewInlineComments off")
		assert(#preview_marks() == 0 and rail_count() == rails, "preview toggle removed review rails")
		assert(not review._show_inline_preview(), "disabled passive preview was rendered")
		vim.cmd("ReviewInlineComments on")
		for _, event in ipairs({ "CursorMoved", "InsertEnter", "BufLeave", "WinLeave", "TabLeave", "WinScrolled" }) do
			assert(review._show_inline_preview(), event .. " fixture could not render a preview")
			vim.api.nvim_exec_autocmds(event, { modeline = false })
			assert(#preview_marks() == 0, event .. " did not clear passive preview")
			assert(rail_count() == rails, event .. " cleared review rails")
		end

		editor_module.has_active = function()
			return true
		end
		assert(not review._show_inline_preview(), "active composer did not suppress passive preview")
		editor_module.has_active = originals.editor_has_active

		assert(review._show_inline_preview())
		assert(review.mode("off") and #preview_marks() == 0 and rail_count() == rails)
		assert(not review._show_inline_preview(), "mode-off passive preview was rendered")
		assert(review.mode("on"))
		rails = rail_count()

		local all_preview_items = workspace.session.items
		workspace.session.items = { file_item, unrelated }
		assert(not review._show_inline_preview(), "file or unrelated comment produced a passive preview")
		workspace.session.items = all_preview_items
		vim.cmd("botright new")
		local comments_win = vim.api.nvim_get_current_win()
		vim.bo.buftype = "nofile"
		vim.b.nvim_review_panel_role = "comments"
		assert(not review._show_inline_preview(), "panel/nofile buffer produced a passive preview")
		vim.api.nvim_set_current_win(source_win)

		assert(review._show_inline_preview())
		workspace.unsaved_error = "preview refresh fixture"
		local preview_refresh, preview_refresh_err = review.refresh()
		assert(preview_refresh == nil and preview_refresh_err:find("unsaved in-memory changes", 1, true))
		assert(#preview_marks() == 0, "failed refresh retained passive preview")
		workspace.unsaved_error = nil
		assert(review._show_inline_preview() and review.present(entry.identity))
		assert(#preview_marks() == 0, "presentation retained passive preview")
		assert(review._show_inline_preview() and review.suspend_for_session())
		assert(#preview_marks() == 0, "session suspension retained passive preview")
		assert(review.restore_after_session())

		local composed_before = #calls.composed
		vim.api.nvim_set_current_win(source_win)
		vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
		assert(review._show_inline_preview())
		review.comment(2, 3, "question")
		assert(#calls.composed == composed_before + 1 and #preview_marks() == 0)
		local range_options = calls.composed[#calls.composed].options
		assert(range_options.source_win == source_win and range_options.anchor_line == 3)
		assert(range_options.anchor_range.first == 2 and range_options.anchor_range.last == 3)
		assert(range_options.anchor.kind == "range" and range_options.anchor.anchor_line == nil)

		vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
		review.file_comment("praise")
		local file_options = calls.composed[#calls.composed].options
		assert(file_options.source_win == source_win and file_options.anchor_line == 4)
		assert(file_options.anchor_range == nil and file_options.anchor.kind == "file")
		assert(file_options.anchor.start_line == nil and file_options.anchor.anchor_line == nil)

		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.general_comment("rationale")
		local general_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(general_options.source_win == source_win and general_options.anchor_line == 4)
		assert(general_options.anchor.kind == "general" and general_options.anchor.anchor_line == nil)

		workspace.session.items = { first }
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.edit(first.id)
		local edit_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(edit_options.source_win == source_win and edit_options.anchor_line == 4)
		assert(edit_options.anchor_range.first == 2 and edit_options.anchor_range.last == 4)

		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.reply(first.id)
		local reply_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(reply_options.source_win == source_win and reply_options.anchor_line == 4)
		assert(reply_options.anchor_range.first == 2 and reply_options.anchor_range.last == 4)

		local saved_presentation = workspace.mode_state.presentation
		local saved_source = workspace.panel.source_win
		workspace.mode_state.presentation = nil
		workspace.panel.source_win = -1
		vim.api.nvim_set_current_win(comments_win)
		local composed_without_source = #calls.composed
		review.general_comment("issue")
		assert(#calls.composed == composed_without_source, "general comment opened without reviewed source")
		workspace.mode_state.presentation = saved_presentation
		workspace.panel.source_win = saved_source
		vim.api.nvim_win_close(comments_win, true)
		vim.api.nvim_set_current_win(source_win)
		workspace.session.items = {}
		workspace.panel.visible = false
		review.refresh_marks(workspace)

		vim.cmd("tabnew")
		local invocation_tab = vim.api.nvim_get_current_tabpage()
		local invocation_win = vim.api.nvim_get_current_win()
		workspace.panel.visible = true
		local failed, activation_err = review.open({ kind = "commit", rev = "BROKEN" }, repository)
		assert(failed == nil and activation_err == "simulated activation failure")
		assert(review._active_workspace() == workspace, "failed activation replaced the previous review")
		assert(workspace.mode_on and workspace.panel.visible and workspace.mode_state.presentation)
		assert(
			vim.api.nvim_get_current_tabpage() == invocation_tab and vim.api.nvim_get_current_win() == invocation_win
		)
		assert(#vim.api.nvim_list_tabpages() == tabs + 1, "activation rollback changed tabs")
		assert(review._workspaces[repository .. "\0" .. broken_scope.id] == nil)
		vim.cmd("tabclose")
		assert(review.export(false) and calls.delivered == 1)

		-- Export and publication must fail closed if the persisted session is no
		-- longer byte-for-byte represented by the live workspace. All external
		-- delivery functions are stubs so these assertions have no side effects.
		workspace.session.items = {
			{
				id = string.rep("e", 64),
				sequence = 1,
				type = "issue",
				body = "eligible for remote delivery",
				anchor = {
					kind = "range",
					path = "new.lua",
					side = "right",
					layer = "history",
					start_line = 2,
					end_line = 2,
					stale = false,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
		}
		workspace.session.bridge = {
			backend = "tuicr",
			round = "123e4567-e89b-12d3-a456-426614174000",
			trusted_scope_id = workspace.session.id,
			linked_at = "2026-08-25T12:00:00Z",
		}
		local live_reference = workspace.session
		local live_contents = vim.deepcopy(workspace.session)
		local function assert_persistence_blocked(label, command)
			workspace.unsaved_error = nil
			workspace.recovery = nil
			local loads_before = calls.loaded
			local delivered_before = calls.delivered
			local tuicr_before = calls.tuicr
			assert(command() == nil, label .. " unexpectedly succeeded")
			assert(calls.loaded == loads_before + 1, label .. " did not reload persisted state")
			assert(calls.delivered == delivered_before, label .. " reached clipboard or preview delivery")
			assert(calls.tuicr == tuicr_before, label .. " reached TUICR")
			assert(workspace.session == live_reference, label .. " replaced the live session")
			assert(vim.deep_equal(workspace.session, live_contents), label .. " changed live review contents")
			assert(workspace.unsaved_error == nil and workspace.recovery == nil, label .. " invented unsaved state")
		end

		local remote = vim.deepcopy(live_contents)
		remote.revision = remote.revision + 1
		store.load = function(root_value, id)
			assert(root_value == repository and id == live_contents.id)
			calls.loaded = calls.loaded + 1
			return vim.deepcopy(remote)
		end
		assert_persistence_blocked("normal export after revision drift", function()
			return review.export(false)
		end)
		assert_persistence_blocked("forced export after revision drift", function()
			return review.export(true)
		end)
		assert_persistence_blocked("normal publish after revision drift", function()
			return review.publish(false)
		end)
		assert_persistence_blocked("forced publish after revision drift", function()
			return review.publish(true)
		end)

		workspace.unsaved_error = nil
		workspace.recovery = nil
		local staged_loads = 0
		store.load = function()
			calls.loaded = calls.loaded + 1
			staged_loads = staged_loads + 1
			return vim.deepcopy(staged_loads == 1 and live_contents or remote)
		end
		local delivered_before_step = calls.delivered
		assert(review.publish(false), "publication did not reach its per-item persistence check")
		assert(staged_loads == 2, "publication did not recheck persistence immediately before TUICR")
		assert(calls.tuicr == 0, "drift after publication preflight reached TUICR")
		assert(calls.delivered == delivered_before_step, "publication drift reached local export delivery")
		assert(workspace.session == live_reference and vim.deep_equal(workspace.session, live_contents))
		assert(workspace.unsaved_error == nil and workspace.recovery == nil, "mid-publication drift invented state")

		-- The adapter's status request is asynchronous. Recheck the exact persisted
		-- item at its internal preflight boundary, freeze local transitions while a
		-- write is pending, and never attach an in-flight receipt to newer content.
		local controller_load = store.load
		local controller_save = store.save
		local controller_mark = store.mark_tuicr_delivered
		local controller_save_recovery = store.save_recovery
		local controller_verify_recovery = store.verify_recovery
		local controller_render_recovery = exporter.render_recovery
		local controller_build = changes.build
		local controller_add = tuicr.add
		local controller_respond = tuicr.respond
		local persisted = vim.deepcopy(live_contents)
		persisted.items[1].body = "body before status"
		workspace.session = vim.deepcopy(persisted)
		workspace.scope = workspace.session.scope
		local recovery_sessions = {}
		store.load = function(root_value, id)
			assert(root_value == repository and id == persisted.id)
			calls.loaded = calls.loaded + 1
			return vim.deepcopy(persisted)
		end
		store.save = function(root_value, value)
			assert(root_value == repository)
			if value.revision ~= persisted.revision then
				return nil, "simulated cross-process revision conflict"
			end
			local copy = vim.deepcopy(value)
			copy.revision = copy.revision + 1
			persisted = vim.deepcopy(copy)
			return copy
		end
		store.mark_tuicr_delivered = function(value, id, receipt)
			local copy = vim.deepcopy(value)
			for _, item in ipairs(copy.items) do
				if item.id == id then
					item.deliveries[#item.deliveries + 1] = {
						backend = "tuicr",
						receipt = receipt,
						delivered_at = "2026-08-27T12:00:00Z",
					}
					return copy
				end
			end
			return nil, "review item does not exist"
		end
		exporter.render_recovery = function(value)
			return "exact publication recovery for " .. value.items[1].body
		end
		store.save_recovery = function(root_value, value, markdown)
			assert(root_value == repository)
			assert(markdown == "exact publication recovery for " .. value.items[1].body)
			recovery_sessions[#recovery_sessions + 1] = vim.deepcopy(value)
			return { path = "/tmp/review-publication-recovery.md", digest = string.rep("c", 64) }
		end
		store.verify_recovery = function(root_value, receipt)
			assert(root_value == repository and receipt.path == "/tmp/review-publication-recovery.md")
			return true
		end
		changes.build = function(root_value, scope_value)
			assert(root_value == repository and scope_value.id == scope.id)
			calls.built = calls.built + 1
			return { entries = { entry }, commits = {}, scope = scope_value }
		end

		local pending
		local remote_writes = 0
		local function defer_operation(action)
			return function(root_value, round, values, options, callback)
				assert(root_value == repository and round == persisted.bridge.round)
				assert(type(options) == "table" and type(options.preflight) == "function")
				assert(not pending, "more than one TUICR operation was in flight")
				pending = {
					action = action,
					values = vim.deepcopy(values),
					options = options,
					callback = callback,
				}
			end
		end
		tuicr.add = defer_operation("add")
		tuicr.respond = defer_operation("respond")

		assert(review.publish(false) and pending, "publication did not reach TUICR status")
		local stale_pending = pending
		pending = nil
		persisted.revision = persisted.revision + 1
		persisted.items[1].body = "body changed during status"
		local allowed, guard_err = stale_pending.options.preflight()
		assert(not allowed and guard_err:find("another Neovim", 1, true))
		assert(remote_writes == 0, "stale status preflight caused a TUICR write")
		stale_pending.callback(nil, { code = "preflight_failed", message = guard_err })
		assert(workspace.session.items[1].body == "body before status")
		assert(#workspace.session.items[1].deliveries == 0 and #recovery_sessions == 0)
		assert(review.refresh(), "review did not reload the authoritative post-status change")
		assert(workspace.session.items[1].body == "body changed during status")

		local resolves_before_publish = calls.resolved
		local loads_before_publish = calls.loaded
		assert(review.publish(false) and pending, "publication did not wait at the second TUICR status")
		local in_flight = pending
		pending = nil
		local refreshed, refresh_err = review.refresh()
		assert(refreshed == nil and refresh_err:find("publication is still in progress", 1, true))
		local opened, open_err = review.open({ kind = "commit", rev = "HEAD" }, repository)
		assert(opened == nil and open_err:find("publication is still in progress", 1, true))
		review.resolve(workspace.session.items[1].id)
		assert(not review.close(true), "close replaced an in-flight review")
		assert(calls.loaded == loads_before_publish + 2, "blocked transitions reloaded persisted review state")
		assert(calls.resolved == resolves_before_publish, "blocked open resolved another review scope")
		assert(workspace.session.items[1].resolution == "open", "blocked mutation changed the review item")
		local write_allowed, write_err = in_flight.options.preflight()
		assert(write_allowed, write_err)
		remote_writes = remote_writes + 1
		local in_flight_key = in_flight.values.delivery_key
		persisted.revision = persisted.revision + 1
		persisted.items[1].body = "body changed while add was in flight"
		in_flight.callback({ id = "receipt-for-old-body" })
		assert(remote_writes == 1, "the authorized in-flight TUICR write was not represented")
		assert(workspace.session.items[1].body == "body changed during status")
		assert(#workspace.session.items[1].deliveries == 0, "receipt was attached to a changed live item")
		assert(#recovery_sessions == 1, "in-flight receipt did not create one exact recovery")
		assert(recovery_sessions[1].items[1].body == "body changed during status")
		assert(recovery_sessions[1].items[1].deliveries[1].receipt == "receipt-for-old-body")

		assert(review.refresh(), "review did not reload after preserving the in-flight receipt")
		assert(workspace.session.items[1].body == "body changed while add was in flight")
		assert(review.publish(false) and pending, "corrected content was not publishable")
		local corrected = pending
		pending = nil
		local corrected_allowed, corrected_err = corrected.options.preflight()
		assert(corrected_allowed, corrected_err)
		assert(corrected.values.delivery_key ~= in_flight_key, "changed content reused the old delivery key")
		assert(#corrected.values.delivery_key <= 256, "content-bound delivery key exceeds TUICR's contract")
		remote_writes = remote_writes + 1
		corrected.callback({ id = "receipt-for-corrected-body" })
		assert(persisted.items[1].body == "body changed while add was in flight")
		assert(persisted.items[1].deliveries[1].receipt == "receipt-for-corrected-body")

		local function publishable_item(id, sequence, body, reply_to)
			return {
				id = id,
				sequence = sequence,
				type = sequence == 3 and "praise" or "question",
				body = body,
				anchor = vim.deepcopy(live_contents.items[1].anchor),
				reply_to = reply_to or vim.NIL,
				resolution = "open",
				deliveries = {},
			}
		end
		local parent_id = string.rep("1", 64)
		local reply_id = string.rep("2", 64)
		local independent_id = string.rep("3", 64)
		local multiple = vim.deepcopy(workspace.session)
		multiple.revision = multiple.revision + 1
		multiple.items = {
			publishable_item(parent_id, 1, "parent", nil),
			publishable_item(reply_id, 2, "reply", parent_id),
			publishable_item(independent_id, 3, "independent", nil),
		}
		persisted = vim.deepcopy(multiple)
		workspace.session = vim.deepcopy(multiple)
		workspace.scope = workspace.session.scope
		local operations = {}
		local function complete_operation(action)
			return function(_, _, values, options, callback)
				local operation_allowed, operation_err = options.preflight()
				assert(operation_allowed, operation_err)
				local receipt = "receipt-" .. tostring(#operations + 1)
				operations[#operations + 1] = {
					action = action,
					values = vim.deepcopy(values),
					receipt = receipt,
				}
				remote_writes = remote_writes + 1
				callback({ id = receipt })
			end
		end
		tuicr.add = complete_operation("add")
		tuicr.respond = complete_operation("respond")
		assert(review.publish(false), "multi-item TUICR publication did not start")
		assert(#operations == 3, "multi-item publication did not serialize all items")
		assert(operations[1].action == "add" and operations[2].action == "respond" and operations[3].action == "add")
		assert(operations[2].values.reply_to == operations[1].receipt, "reply did not use the delivered parent receipt")
		local delivery_keys = {}
		for index, operation in ipairs(operations) do
			assert(
				not delivery_keys[operation.values.delivery_key],
				"two distinct remote effects shared a delivery key"
			)
			delivery_keys[operation.values.delivery_key] = true
			assert(#operation.values.delivery_key <= 256, "multi-item delivery key exceeds TUICR's contract")
			assert(persisted.items[index].deliveries[1].receipt == operation.receipt)
		end

		store.load = controller_load
		store.save = controller_save
		store.mark_tuicr_delivered = controller_mark
		store.save_recovery = controller_save_recovery
		store.verify_recovery = controller_verify_recovery
		exporter.render_recovery = controller_render_recovery
		changes.build = controller_build
		tuicr.add = controller_add
		tuicr.respond = controller_respond
		workspace.session = live_reference
		workspace.scope = live_reference.scope
		workspace.unsaved_error = nil
		workspace.recovery = nil

		store.load = function()
			calls.loaded = calls.loaded + 1
			return nil, "session.bridge.trusted_scope_id must match session.id"
		end
		assert_persistence_blocked("persisted link load error", function()
			return review.publish(false)
		end)

		local wrong_identity = vim.deepcopy(live_contents)
		wrong_identity.id = broken_scope.id
		store.load = function()
			calls.loaded = calls.loaded + 1
			return vim.deepcopy(wrong_identity)
		end
		assert_persistence_blocked("persisted identity mismatch", function()
			return review.export(false)
		end)

		local wrong_link = vim.deepcopy(live_contents)
		wrong_link.bridge.round = "22222222-2222-2222-2222-222222222222"
		store.load = function()
			calls.loaded = calls.loaded + 1
			return vim.deepcopy(wrong_link)
		end
		assert_persistence_blocked("persisted link mismatch", function()
			return review.publish(true)
		end)

		local wrong_content = vim.deepcopy(live_contents)
		wrong_content.items[1].body = "same revision, different persisted content"
		store.load = function()
			calls.loaded = calls.loaded + 1
			return vim.deepcopy(wrong_content)
		end
		assert_persistence_blocked("same-revision content mismatch", function()
			return review.export(false)
		end)
		assert(calls.tuicr == 0, "a persistence conflict caused a TUICR side effect")

		workspace.unsaved_error = nil
		workspace.recovery = nil
		workspace.session.items = {}
		workspace.session.bridge = vim.NIL
		store.load = load_live
		calls.verified = 0
		workspace.scope.kind = "working"
		workspace.session.scope.kind = "working"
		scope_module.detect_drift = function()
			return { stale = true }
		end
		assert(review.export(false) == nil and calls.delivered == 1, "normal stale export was delivered")
		local forced = assert(review.export(true))
		assert(calls.delivered == 2 and forced.recovery.path == "/tmp/review-recovery.md")
		assert(calls.verified == 1, "forced stale export did not verify its recovery")
		assert(not workspace.session.stale, "forced export mutated live review state")
		workspace.scope.kind = "commit"
		workspace.session.scope.kind = "commit"
		workspace.session.items = { { anchor = { stale = true } } }
		workspace.session.bridge = { backend = "tuicr" }
		assert(review.export(false) == nil, "normal export ignored a stale comment anchor")
		assert(review.publish(false) == nil, "normal TUICR publication ignored a stale comment anchor")
		local anchor_forced = assert(review.export(true))
		assert(anchor_forced.recovery.path == "/tmp/review-recovery.md" and calls.verified == 2)
		assert(review.publish(true), "forced TUICR publication did not accept a verified stale-anchor recovery")
		assert(calls.verified == 3, "forced TUICR publication did not verify its recovery")
		local live_comment_id = string.rep("d", 64)
		workspace.session.items = {
			{
				id = live_comment_id,
				type = "question",
				body = "This comment exists only in memory",
				anchor = {
					kind = "range",
					path = "new.lua",
					side = "right",
					layer = "history",
					start_line = 2,
					end_line = 2,
					stale = false,
				},
			},
		}
		workspace.session.bridge = vim.NIL
		review.refresh_marks(workspace)
		local function visible_review_lines()
			local lines = {}
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })) do
				if mark[4].sign_text and vim.trim(mark[4].sign_text) ~= "" then
					lines[#lines + 1] = mark[2] + 1
				end
			end
			table.sort(lines)
			return lines
		end
		assert(vim.deep_equal(visible_review_lines(), { 2 }), "pre-conflict rail was not anchored at line 2")
		store.save = function(_, value)
			assert(value.items[1].anchor.start_line == 4)
			return nil, "simulated revision conflict"
		end
		vim.api.nvim_set_current_win(source_win)
		assert(review.present(entry.identity))
		vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
		local panel_refreshes_before = calls.panel_refreshed
		local trouble_refreshes_before = calls.trouble_refreshed
		review.reanchor(live_comment_id, source_win)
		assert(workspace.unsaved_error == "simulated revision conflict", "failed mutation was not kept live")
		assert(workspace.recovery and workspace.recovery.path == "/tmp/review-recovery.md")
		assert(workspace.session.items[1].anchor.start_line == 4, "failed save lost the live reanchor")
		assert(vim.deep_equal(visible_review_lines(), { 4 }), "failed save left the rail at the persisted anchor")
		assert(calls.panel_refreshed == panel_refreshes_before + 1, "failed save did not refresh the panel")
		assert(calls.trouble_refreshed == trouble_refreshes_before + 1, "failed save did not refresh Trouble")
		assert(calls.trouble_anchor == 4, "Trouble refreshed from the persisted anchor instead of the live session")
		local delivered_before_recovery = calls.delivered
		local loaded_before_recovery = calls.loaded
		local first_recovery_export = assert(review.export(false), "live recovery could not be exported")
		local second_recovery_export = assert(review.export(false), "live recovery export was not repeatable")
		assert(calls.delivered == delivered_before_recovery + 2, "live recovery was not delivered twice")
		assert(calls.loaded == loaded_before_recovery, "live recovery export reloaded and replaced persisted state")
		assert(
			first_recovery_export.recovery and second_recovery_export.recovery,
			"live export lacked recovery receipt"
		)
		assert(workspace.session.items[1].anchor.start_line == 4, "live export replaced the recovered anchor")
		local live_session = workspace.session
		local live_contents = vim.deepcopy(live_session)
		local review_key = repository .. "\0" .. scope.id
		local calls_before_guard = {
			built = calls.built,
			loaded = calls.loaded,
			resolved = calls.resolved,
		}
		local refreshed, refresh_err = review.refresh()
		assert(refreshed == nil and refresh_err:find("unsaved in-memory changes", 1, true))
		local reopened, reopen_err = review.open({ kind = "commit", rev = "HEAD" }, repository)
		assert(reopened == nil and reopen_err:find("unsaved in-memory changes", 1, true))
		local replaced, replace_err = review.open({ kind = "commit", rev = "BROKEN" }, repository)
		assert(replaced == nil and replace_err:find("unsaved in-memory changes", 1, true))
		assert(calls.built == calls_before_guard.built, "unsaved guard rebuilt a review model")
		assert(calls.loaded == calls_before_guard.loaded, "unsaved guard reloaded persisted state")
		assert(calls.resolved == calls_before_guard.resolved, "unsaved guard resolved a replacement scope")
		assert(review._active_workspace() == workspace, "unsaved guard replaced the active workspace")
		assert(review._workspaces[review_key] == workspace, "unsaved guard changed the workspace registry")
		assert(workspace.session == live_session, "unsaved guard replaced the live session reference")
		assert(vim.deep_equal(workspace.session, live_contents), "unsaved guard changed live comment contents")
		local closes_before = calls.closed
		store.verify_recovery = function()
			calls.verified = calls.verified + 1
			return false, "simulated digest mismatch"
		end
		assert(not review.close(true), "forced close accepted an unverified recovery")
		assert(review._active_workspace() == workspace and calls.closed == closes_before)
		store.verify_recovery = function(root_value, receipt)
			assert(root_value == repository and receipt.path == "/tmp/review-recovery.md")
			calls.verified = calls.verified + 1
			return true
		end
		assert(not review.close(), "normal close discarded an unsaved review")
		assert(review._active_workspace() == workspace and calls.closed == closes_before)
		local events_before_close = #review_events
		assert(review.close(true) and calls.closed == closes_before + 1)
		assert(#vim.api.nvim_list_tabpages() == tabs and review._active_workspace() == nil)
		assert(#review_events == events_before_close + 1 and review_events[#review_events].active == false)
		assert(vim.deep_equal(review.status(), { active = false, mode_on = false }))
	end, debug.traceback)
	for name, value in pairs(originals) do
		if name == "resolve" then
			scope_module.resolve = value
		elseif
			name == "load"
			or name == "new"
			or name == "save"
			or name == "edit"
			or name == "mark_tuicr_delivered"
			or name == "save_recovery"
			or name == "verify_recovery"
		then
			store[name] = value
		elseif name == "build" or name == "selection_request" then
			changes[name] = value
		elseif name == "detect_drift" then
			scope_module.detect_drift = value
		elseif name == "mode_new" then
			mode.new = value
		elseif
			name == "enable"
			or name == "disable"
			or name == "enroll_affected_buffer"
			or name == "mode_suspend"
			or name == "mode_restore"
		then
			mode[name:gsub("^mode_", "")] = value
		elseif name == "show" or name == "clear" or name == "current_target" or name == "refresh_winbars" then
			presenter[name] = value
		elseif name:sub(1, 6) == "panel_" then
			panel[name:sub(7)] = value
		elseif
			name == "deliver"
			or name == "render"
			or name == "render_recovery"
			or name == "suspend_preview"
			or name == "restore_preview"
		then
			exporter[name] = value
		elseif name == "tuicr_add" then
			tuicr.add = value
		elseif name == "tuicr_respond" then
			tuicr.respond = value
		elseif name == "editor_compose" or name == "editor_has_active" then
			editor_module[name:sub(8)] = value
		end
	end
	review.file_comment = original_file_comment
	vim.notify = original_notify
	package.loaded.trouble = original_trouble
	assert(ok, err)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("code_review_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
