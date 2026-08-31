vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
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
		"<leader>rR",
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

test("host adapter owns global review commands and mappings without retired publication", function()
	review.setup()
	for _, command in ipairs({
		"ReviewOpen",
		"ReviewPanel",
		"ReviewComment",
		"ReviewFileComment",
		"ReviewGeneralComment",
		"ReviewReanchor",
		"ReviewExport",
		"ReviewClose",
	}) do
		assert(vim.fn.exists(":" .. command) == 2, command .. " is missing from the host adapter")
	end
	for _, command in ipairs({ "ReviewPublish", "ReviewLinkTuicr", "ReviewRoundStart", "TuicrReview" }) do
		assert(vim.fn.exists(":" .. command) == 0, command .. " survived retirement")
	end
	assert(vim.fn.maparg("<leader>ro", "n", false, true).desc == "Open default review", "host review mapping")
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
	local shared = {
		path = "lua/new.lua",
		side = "right",
		layer = "history",
		line = 4,
		refs = {
			{ path = "lua/old.lua", side = "left", layer = "history", line = 4 },
			{ path = "lua/new.lua", side = "right", layer = "history", line = 4 },
		},
	}
	for _, side in ipairs({
		{ path = "lua/old.lua", side = "left" },
		{ path = "lua/new.lua", side = "right" },
	}) do
		assert(review._contains_line({
			kind = "range",
			path = side.path,
			side = side.side,
			layer = "history",
			start_line = 4,
			end_line = 4,
		}, shared))
	end
end)

test("comment rails compact each line and type with stable priorities", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
	vim.b[buf].nvim_review_path = "lua/example.lua"
	vim.b[buf].nvim_review_side = "right"
	vim.b[buf].nvim_review_layer = "history"
	local items = {}
	local sequence = 0
	local function range_item(item_type, first, last, fields)
		sequence = sequence + 1
		local value = {
			id = ("%064d"):format(sequence),
			sequence = sequence,
			type = item_type,
			body = item_type .. " body",
			anchor = {
				kind = "range",
				path = "lua/example.lua",
				side = "right",
				layer = "history",
				start_line = first,
				end_line = last,
			},
			reply_to = vim.NIL,
			resolution = "open",
			deliveries = {},
		}
		for name, field in pairs(fields or {}) do
			value[name] = field
		end
		items[#items + 1] = value
	end
	range_item("issue", 1, 1, { deliveries = { { backend = "tuicr" } } })
	range_item("suggestion", 1, 1, { resolution = "resolved" })
	range_item("question", 2, 2)
	range_item("question", 2, 2, { reply_to = items[3].id })
	for _ = 1, 9 do
		range_item("rationale", 3, 3)
	end
	range_item("pedantic", 1, 3)
	range_item("praise", 4, 5)
	range_item("praise", 3, 4)
	for _ = 1, 10 do
		range_item("issue", 4, 5)
	end
	items[#items + 1] = {
		id = string.rep("f", 64),
		sequence = sequence + 1,
		type = "issue",
		anchor = { kind = "file", path = "lua/example.lua", side = "right", layer = "history" },
	}
	items[#items + 1] = {
		id = string.rep("g", 64),
		sequence = sequence + 2,
		type = "praise",
		anchor = { kind = "general" },
	}
	local workspace = {
		root = "/tmp/review-aggregate",
		session = { items = items },
	}
	local external_namespace = vim.api.nvim_create_namespace("code_review_spec_external_sign")
	vim.api.nvim_buf_set_extmark(buf, external_namespace, 0, 0, {
		priority = 100,
		sign_hl_group = "WarningMsg",
		sign_text = "X",
	})
	review.decorate_buffer(workspace, buf)
	local expected = {
		[1] = {
			NvimReviewCommentIssue = "●",
			NvimReviewCommentSuggestion = "◆",
			NvimReviewCommentPedantic = "╭·",
		},
		[2] = { NvimReviewCommentQuestion = "2", NvimReviewCommentPedantic = "│" },
		[3] = {
			NvimReviewCommentRationale = "9",
			NvimReviewCommentPedantic = "╰",
			NvimReviewCommentPraise = "╭♥",
		},
		[4] = { NvimReviewCommentIssue = "9+", NvimReviewCommentPraise = "2" },
		[5] = { NvimReviewCommentIssue = "╰", NvimReviewCommentPraise = "╰" },
	}
	local priorities = {
		NvimReviewCommentIssue = 89,
		NvimReviewCommentSuggestion = 88,
		NvimReviewCommentQuestion = 87,
		NvimReviewCommentRationale = 86,
		NvimReviewCommentPedantic = 85,
		NvimReviewCommentPraise = 84,
	}
	local seen = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
		local details = mark[4]
		if priorities[details.sign_hl_group] then
			local line = mark[2] + 1
			local sign_text = vim.trim(details.sign_text)
			seen[line] = seen[line] or {}
			assert(seen[line][details.sign_hl_group] == nil, "line/type rail emitted more than one sign")
			seen[line][details.sign_hl_group] = sign_text
			assert(details.priority == priorities[details.sign_hl_group], "review type priority changed")
			assert(vim.fn.strdisplaywidth(sign_text) <= 2, "review sign exceeds two display cells")
			assert(details.virt_text == nil, "review rail retained an EOL summary")
		end
	end
	assert(vim.deep_equal(seen, expected), "unexpected compact rail projection: " .. vim.inspect(seen))
	local external = vim.api.nvim_buf_get_extmarks(buf, external_namespace, 0, -1, { details = true })
	assert(
		#external == 1 and vim.trim(external[1][4].sign_text or "") == "X",
		"review rails replaced another sign provider"
	)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("file comments render as virtual line zero only on their exact side", function()
	local function comment(sequence, item_type, body, anchor)
		return {
			id = ("%064d"):format(sequence),
			sequence = sequence,
			type = item_type,
			body = body,
			anchor = anchor,
			reply_to = vim.NIL,
			resolution = "open",
			deliveries = {},
		}
	end
	local workspace = {
		root = "/tmp/review-file-comments",
		session = {
			items = {
				comment(1, "issue", string.rep("á🙂", 80) .. "\ncontinued", {
					kind = "file",
					path = "lua/example.lua",
					side = "right",
					layer = "history",
				}),
				comment(2, "praise", "second current comment", {
					kind = "file",
					path = "lua/example.lua",
					side = "right",
					layer = "history",
				}),
				comment(3, "question", "old-only comment", {
					kind = "file",
					path = "lua/example.lua",
					side = "left",
					layer = "history",
				}),
				comment(4, "rationale", "review-only comment", { kind = "general" }),
			},
		},
	}
	local function decorated(side)
		local buf = vim.api.nvim_create_buf(false, true)
		local original = { "first", "second" }
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
		vim.b[buf].nvim_review_path = "lua/example.lua"
		vim.b[buf].nvim_review_side = side
		vim.b[buf].nvim_review_layer = "history"
		review.decorate_buffer(workspace, buf)
		local virtual
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
			if mark[4].virt_lines then
				assert(virtual == nil, "file comments emitted multiple line-zero extmarks")
				virtual = mark[4].virt_lines
				assert(mark[2] == 0 and mark[4].virt_lines_above and mark[4].virt_lines_leftcol)
			end
		end
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original))
		return buf, assert(virtual, "matching file comment did not render line zero")
	end
	local right_buf, right = decorated("right")
	assert(#right == 2, "CURRENT line zero included an opposite-side or review-level comment")
	local right_first = table.concat(vim.tbl_map(function(chunk)
		return chunk[1]
	end, right[1]))
	local right_second = table.concat(vim.tbl_map(function(chunk)
		return chunk[1]
	end, right[2]))
	assert(right_first:find("0 │ [NEW][issue][draft]", 1, true) == 1 and right_first:sub(-3) == "…")
	assert(pcall(vim.str_utfindex, right_first), "line-zero excerpt contains invalid UTF-8")
	assert(right_second:find("0 │ [NEW][praise][draft] second current comment", 1, true) == 1)
	assert(not right_first:find("old-only", 1, true) and not right_first:find("review-only", 1, true))

	local left_buf, left = decorated("left")
	assert(#left == 1, "OLD line zero included CURRENT comments")
	local left_text = table.concat(vim.tbl_map(function(chunk)
		return chunk[1]
	end, left[1]))
	assert(left_text == "0 │ [OLD][question][draft] old-only comment")
	vim.api.nvim_buf_delete(right_buf, { force = true })
	vim.api.nvim_buf_delete(left_buf, { force = true })
end)

test("comment sign highlights are theme-linked, restored, and user-overridable", function()
	local links = {
		NvimReviewCommentIssue = "DiagnosticSignError",
		NvimReviewCommentSuggestion = "DiagnosticSignWarn",
		NvimReviewCommentQuestion = "DiagnosticSignInfo",
		NvimReviewCommentRationale = "Special",
		NvimReviewCommentPedantic = "DiagnosticSignHint",
		NvimReviewCommentPraise = "DiagnosticSignOk",
	}
	for group, link in pairs(links) do
		assert(vim.api.nvim_get_hl(0, { name = group, link = true }).link == link, group .. " link changed")
	end
	vim.api.nvim_set_hl(0, "NvimReviewCommentIssue", { link = "String" })
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "review-comment-user-override" })
	assert(vim.api.nvim_get_hl(0, { name = "NvimReviewCommentIssue", link = true }).link == "String")
	vim.cmd("highlight clear NvimReviewCommentIssue")
	vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "review-comment-default-link" })
	assert(vim.api.nvim_get_hl(0, { name = "NvimReviewCommentIssue", link = true }).link == "DiagnosticSignError")
end)

test("open presents in the ordinary tab, opens the native panel, and close owns no tab", function()
	local native_review = require("config.native_review")
	local scope_module = native_review.scope
	local store = native_review.store
	local changes = native_review.changes
	local mode = native_review.mode
	local presenter = native_review.presenter
	local panel = native_review.panel
	local exporter = native_review.export
	local editor_module = native_review.editor
	local originals = {
		resolve = scope_module.resolve,
		load = store.load,
		new = store.new,
		save = store.save,
		edit = store.edit,
		delete = store.delete,
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
	local old_lines = {
		"old one",
		"old two",
		"old three",
		"old four",
		"old five",
		"old six",
		"old seven",
		"old eight",
	}
	local new_lines = vim.deepcopy(old_lines)
	new_lines[4] = "new four"
	local old_text = table.concat(old_lines, "\n") .. "\n"
	local new_text = table.concat(new_lines, "\n") .. "\n"
	local entry = {
		identity = "history\0old.lua\0new.lua",
		status = "R",
		layer = "history",
		old_path = "old.lua",
		new_path = "new.lua",
		path = "new.lua",
		old_text = old_text,
		new_text = new_text,
		hunks = vim.diff(old_text, new_text, { result_type = "indices" }),
		metadata_only = false,
		binary = false,
		submodule = false,
		added = false,
		deleted = false,
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
	local original_select = vim.ui.select
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
	store.delete = function(value, id)
		calls.delete_session = value
		local copy = vim.deepcopy(value)
		for index, item in ipairs(copy.items) do
			if item.id == id then
				table.remove(copy.items, index)
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
		local side = "new"
		local target = {
			win = vim.api.nvim_get_current_win(),
			buf = vim.api.nvim_get_current_buf(),
			side = side,
		}
		vim.b[target.buf].nvim_review_path = side == "old" and selected.old_path or selected.new_path
		vim.b[target.buf].nvim_review_side = side == "old" and "left" or "right"
		vim.b[target.buf].nvim_review_layer = selected.layer or "history"
		state.presentation = {
			target = target,
			inline = options.layout == "inline" and target or nil,
			entry = selected,
			layout = options.layout,
		}
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
		assert(status.layout == "inline" and status.context == "hunks")
		assert(status.inline_comments)
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

		assert(review.layout("split"))
		assert(review.layout("inline"))
		workspace.panel.visible = false
		vim.cmd("tabnew")
		local session_focus_tab = vim.api.nvim_get_current_tabpage()
		local session_focus_win = vim.api.nvim_get_current_win()
		local session_focus_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(session_focus_buf, 0, -1, false, { "outside", "the", "review" })
		vim.api.nvim_win_set_cursor(session_focus_win, { 2, 1 })
		assert(review.suspend_for_session(), "review UI did not suspend from an unrelated tab")
		assert(review.restore_after_session(), "review UI did not restore from an unrelated tab")
		assert(workspace.mode_state.presentation.target.side == "new")
		assert(vim.api.nvim_get_current_tabpage() == session_focus_tab, "session restore stole the active tab")
		assert(vim.api.nvim_get_current_win() == session_focus_win, "session restore stole the active window")
		assert(vim.api.nvim_get_current_buf() == session_focus_buf, "session restore replaced the active buffer")
		assert(vim.deep_equal(vim.api.nvim_win_get_cursor(session_focus_win), { 2, 1 }), "session restore lost view")
		vim.cmd("tabclose")
		workspace.panel.visible = true
		local shown_before_file_comment = calls.shown
		workspace.panel.callbacks.file_comment(entry.identity)
		assert(calls.shown == shown_before_file_comment + 1 and calls.file_comment == 1 and not workspace.panel.visible)
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
		assert(child.layout == "split" and child.context == "full")
		assert(child.inline_comments == false)
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
		assert(workspace.layout == "split" and workspace.context == "full")
		assert(workspace.inline_comments == false)
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

		local integration_origin_win = workspace.panel.source_win
		vim.api.nvim_set_current_win(integration_origin_win)
		local stub_mode_state = workspace.mode_state
		local stub_presenter = {
			show = presenter.show,
			clear = presenter.clear,
			current_target = presenter.current_target,
		}
		local integration_state = originals.mode_new(workspace)
		assert(originals.enable(integration_state), "actual review mode could not enable for old-side integration")
		workspace.mode_state = integration_state
		workspace.mode_on = true
		workspace.layout = "split"
		workspace.context = "full"
		presenter.show = originals.show
		presenter.clear = originals.clear
		presenter.current_target = originals.current_target
		local composed_before_old_side = #calls.composed
		assert(review.present(entry.identity), "actual split presenter could not render the controller fixture")
		local left = assert(integration_state.presentation.left, "split presentation did not expose an old side")
		assert(vim.b[left.buf].nvim_review_side == "left" and vim.b[left.buf].nvim_review_path == entry.old_path)
		assert(vim.api.nvim_buf_get_lines(left.buf, 3, 4, false)[1] == "old four", "old line was not real text")
		vim.api.nvim_set_current_win(left.win)
		vim.api.nvim_win_set_cursor(left.win, { 4, 0 })
		review.comment(4, 4, "question")
		assert(#calls.composed == composed_before_old_side + 1, "old-side comment did not reach the composer")
		local old_options = calls.composed[#calls.composed].options
		local old_anchor = old_options.anchor
		assert(old_options.source_win == left.win and old_options.anchor_line == 4)
		assert(old_anchor.path == entry.old_path and old_anchor.side == "left" and old_anchor.layer == "history")
		assert(old_anchor.start_line == 4 and old_anchor.end_line == 4)
		local expected_old_context = table.concat(vim.list_slice(old_lines, 1, 7), "\n")
		assert(old_anchor.context == expected_old_context, "old-side anchor captured the wrong context")
		assert(old_anchor.context_hash == vim.fn.sha256(expected_old_context):lower())
		local old_comment_id = string.rep("9", 64)
		workspace.session.items = {
			{
				id = old_comment_id,
				sequence = 9,
				type = "question",
				body = "Old-side controller proof",
				anchor = vim.deepcopy(old_anchor),
				reply_to = vim.NIL,
				resolution = "resolved",
				deliveries = { { backend = "tuicr", receipt = "old-side-proof" } },
			},
		}
		review.refresh_marks(workspace)
		local old_rails = vim.api.nvim_buf_get_extmarks(left.buf, -1, { 3, 0 }, { 3, -1 }, { details = true })
		local rendered_old_rail = false
		for _, mark in ipairs(old_rails) do
			if mark[4].sign_hl_group == "NvimReviewCommentQuestion" and vim.trim(mark[4].sign_text or "") == "?" then
				rendered_old_rail = true
			end
		end
		assert(rendered_old_rail, "old-side anchor could not render its comment rail")
		workspace.session.items[1].deliveries = {}

		local confirmations = {}
		vim.ui.select = function(choices, options, callback)
			confirmations[#confirmations + 1] = {
				choices = vim.deepcopy(choices),
				options = vim.deepcopy(options),
				callback = callback,
			}
		end
		for _, cancellation in ipairs({ vim.NIL, "Cancel" }) do
			review.delete(old_comment_id)
			local confirmation = confirmations[#confirmations]
			assert(vim.deep_equal(confirmation.choices, { "Cancel", "Delete" }))
			assert(confirmation.options.prompt:find("#09 [question] [OLD] old.lua:4", 1, true))
			confirmation.callback(cancellation == vim.NIL and nil or cancellation)
			assert(#workspace.session.items == 1, "cancelled deletion changed the review")
		end
		review.delete(old_comment_id)
		local latest_session = vim.deepcopy(workspace.session)
		latest_session.items[1].body = "Latest old-side body"
		workspace.session = latest_session
		confirmations[#confirmations].callback("Delete")
		assert(calls.delete_session == latest_session, "delete did not refetch the latest active session")
		assert(#workspace.session.items == 0, "confirmed deletion did not save")
		vim.ui.select = original_select

		local current_comment_id = string.rep("8", 64)
		local current_anchor = vim.deepcopy(old_anchor)
		current_anchor.path = entry.new_path
		current_anchor.side = "right"
		workspace.session.items = {
			{
				id = old_comment_id,
				sequence = 9,
				type = "question",
				body = "Old inline jump",
				anchor = vim.deepcopy(old_anchor),
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = current_comment_id,
				sequence = 10,
				type = "suggestion",
				body = "Current inline jump",
				anchor = current_anchor,
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
		}
		workspace.layout = "inline"
		assert(review.present(entry.identity))
		local inline = integration_state.presentation.inline
		local composed_before_unified = #calls.composed
		vim.api.nvim_set_current_win(inline.win)

		vim.api.nvim_win_set_cursor(inline.win, { 4, 0 })
		review.comment(4, 4, "issue")
		local old_inline_options = calls.composed[#calls.composed].options
		assert(#calls.composed == composed_before_unified + 1)
		assert(old_inline_options.source_win == inline.win and old_inline_options.anchor_line == 4)
		assert(vim.deep_equal(old_inline_options.anchor_range, { first = 4, last = 4 }))
		assert(old_inline_options.anchor.path == entry.old_path and old_inline_options.anchor.side == "left")
		assert(old_inline_options.anchor.start_line == 4 and old_inline_options.anchor.end_line == 4)
		assert(old_inline_options.anchor.context:find("old four", 1, true))
		assert(not old_inline_options.anchor.context:find("new four", 1, true))

		vim.api.nvim_win_set_cursor(inline.win, { 5, 0 })
		review.comment(5, 5, "suggestion")
		local new_inline_options = calls.composed[#calls.composed].options
		assert(new_inline_options.anchor_line == 5 and new_inline_options.anchor.side == "right")
		assert(new_inline_options.anchor.path == entry.new_path and new_inline_options.anchor.start_line == 4)
		assert(new_inline_options.anchor.context:find("new four", 1, true))
		assert(not new_inline_options.anchor.context:find("old four", 1, true))

		vim.api.nvim_win_set_cursor(inline.win, { 3, 0 })
		review.comment(3, 3, "rationale")
		local shared_options = calls.composed[#calls.composed].options
		assert(shared_options.anchor.side == "right" and shared_options.anchor.start_line == 3)
		review.comment(3, 4, "question")
		local old_range_options = calls.composed[#calls.composed].options
		assert(old_range_options.anchor.side == "left")
		assert(old_range_options.anchor.start_line == 3 and old_range_options.anchor.end_line == 4)
		assert(vim.deep_equal(old_range_options.anchor_range, { first = 3, last = 4 }))
		review.comment(5, 6, "praise")
		local new_range_options = calls.composed[#calls.composed].options
		assert(new_range_options.anchor.side == "right")
		assert(new_range_options.anchor.start_line == 4 and new_range_options.anchor.end_line == 5)
		assert(vim.deep_equal(new_range_options.anchor_range, { first = 5, last = 6 }))
		local composed_before_mixed = #calls.composed
		review.comment(4, 5, "issue")
		assert(#calls.composed == composed_before_mixed, "mixed OLD/NEW selection opened the composer")
		assert(notifications[#notifications]:find("OLD-only and NEW-only", 1, true))
		vim.api.nvim_win_set_cursor(inline.win, { 4, 0 })
		review.file_comment("praise")
		local old_file_options = calls.composed[#calls.composed].options
		assert(old_file_options.anchor.kind == "file")
		assert(old_file_options.anchor.side == "left" and old_file_options.anchor.path == entry.old_path)
		vim.api.nvim_win_set_cursor(inline.win, { 3, 0 })
		review.file_comment("issue")
		local shared_file_options = calls.composed[#calls.composed].options
		assert(shared_file_options.anchor.kind == "file")
		assert(shared_file_options.anchor.side == "right" and shared_file_options.anchor.path == entry.new_path)

		local direct_items = vim.deepcopy(workspace.session.items)
		workspace.session.items = {
			{
				id = string.rep("4", 64),
				sequence = 4,
				type = "question",
				body = "OLD mapped rail",
				anchor = {
					kind = "range",
					path = entry.old_path,
					side = "left",
					layer = "history",
					start_line = 4,
					end_line = 5,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = string.rep("5", 64),
				sequence = 5,
				type = "suggestion",
				body = "NEW mapped rail",
				anchor = {
					kind = "range",
					path = entry.new_path,
					side = "right",
					layer = "history",
					start_line = 3,
					end_line = 4,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = string.rep("6", 64),
				sequence = 6,
				type = "praise",
				body = "OLD file",
				anchor = { kind = "file", path = entry.old_path, side = "left", layer = "history" },
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = string.rep("7", 64),
				sequence = 7,
				type = "issue",
				body = "NEW file",
				anchor = { kind = "file", path = entry.new_path, side = "right", layer = "history" },
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = string.rep("a", 64),
				sequence = 8,
				type = "rationale",
				body = "Panel only",
				anchor = { kind = "general" },
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
		}
		review.refresh_marks(workspace)
		local rail_rows = { question = {}, suggestion = {} }
		local file_text = ""
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(inline.buf, -1, 0, -1, { details = true })) do
			local details = mark[4]
			if details.sign_hl_group == "NvimReviewCommentQuestion" then
				rail_rows.question[mark[2] + 1] = true
			elseif details.sign_hl_group == "NvimReviewCommentSuggestion" then
				rail_rows.suggestion[mark[2] + 1] = true
			end
			for _, virtual in ipairs(details.virt_lines or {}) do
				file_text = file_text
					.. table.concat(vim.tbl_map(function(chunk)
						return chunk[1]
					end, virtual))
			end
		end
		assert(rail_rows.question[4] and rail_rows.question[6] and not rail_rows.question[5])
		assert(rail_rows.suggestion[3] and rail_rows.suggestion[5] and not rail_rows.suggestion[4])
		assert(file_text:find("[OLD][praise][draft]", 1, true))
		assert(file_text:find("[NEW][issue][draft]", 1, true))
		assert(not file_text:find("Panel only", 1, true))
		workspace.session.items = direct_items
		review.refresh_marks(workspace)

		local shared_old_id = string.rep("d", 64)
		local shared_new_id = string.rep("e", 64)
		workspace.session.items = {
			{
				id = shared_old_id,
				sequence = 11,
				type = "question",
				body = "OLD shared lookup",
				anchor = {
					kind = "range",
					path = entry.old_path,
					side = "left",
					layer = "history",
					start_line = 3,
					end_line = 3,
					stale = false,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
			{
				id = shared_new_id,
				sequence = 12,
				type = "suggestion",
				body = "NEW shared lookup",
				anchor = {
					kind = "range",
					path = entry.new_path,
					side = "right",
					layer = "history",
					start_line = 3,
					end_line = 3,
					stale = false,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
		}
		vim.api.nvim_win_set_cursor(inline.win, { 3, 0 })
		local local_choices
		vim.ui.select = function(choices)
			local_choices = vim.deepcopy(choices)
		end
		review.edit()
		assert(#local_choices == 2, "shared display row did not query both source anchors")
		vim.ui.select = original_select
		workspace.inline_comments = true
		assert(review._show_inline_preview(), "shared display row did not show both inline previews")
		local preview = vim.api.nvim_buf_get_extmarks(
			inline.buf,
			review._preview_namespace,
			{ 2, 0 },
			{ 2, -1 },
			{ details = true }
		)
		assert(#preview == 1 and #(preview[1][4].virt_lines or {}) == 2)
		review._clear_inline_preview()
		review.reanchor(shared_old_id, inline.win)
		local preferred_anchor = assert(workspace.session.items[1]).anchor
		assert(preferred_anchor.side == "left" and preferred_anchor.path == entry.old_path)
		assert(preferred_anchor.start_line == 3, "shared-row reanchor did not preserve the existing OLD side")
		workspace.session.items = direct_items
		review.refresh_marks(workspace)
		local hidden_id = string.rep("f", 64)
		workspace.session.items = {
			{
				id = hidden_id,
				sequence = 13,
				type = "issue",
				body = "Hidden context jump",
				anchor = {
					kind = "range",
					path = entry.new_path,
					side = "right",
					layer = "history",
					start_line = 8,
					end_line = 8,
					stale = false,
				},
				reply_to = vim.NIL,
				resolution = "open",
				deliveries = {},
			},
		}
		workspace.context = "hunks"
		assert(review.present(entry.identity))
		assert(review.jump(hidden_id), "comment in concealed unified context did not open")
		assert(integration_state.presentation.inline.side == "unified")
		assert(vim.api.nvim_win_get_cursor(integration_state.presentation.inline.win)[1] == 9)
		workspace.context = "full"
		workspace.session.items = direct_items

		assert(review.jump(old_comment_id), "OLD inline comment did not open")
		assert(workspace.layout == "inline")
		assert(integration_state.presentation.inline.side == "unified")
		assert(vim.api.nvim_win_get_cursor(integration_state.presentation.inline.win)[1] == 4)
		assert(review.jump(current_comment_id), "CURRENT inline comment did not open")
		assert(workspace.layout == "inline")
		assert(integration_state.presentation.inline.side == "unified")
		assert(vim.api.nvim_win_get_cursor(integration_state.presentation.inline.win)[1] == 5)
		workspace.session.items = {}

		originals.disable(integration_state)
		presenter.show = stub_presenter.show
		presenter.clear = stub_presenter.clear
		presenter.current_target = stub_presenter.current_target
		workspace.mode_state = stub_mode_state
		workspace.mode_on = true
		workspace.panel.source_win = integration_origin_win
		vim.api.nvim_set_current_win(integration_origin_win)
		assert(review.present(entry.identity), "stub presentation did not return to CURRENT")
		review.refresh_marks(workspace)

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
		review.reanchor(comment_id, source_win)
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
		assert(
			vim.api.nvim_get_commands({ builtin = false }).ReviewGeneralComment,
			"ReviewGeneralComment command is missing"
		)
		assert(vim.api.nvim_get_commands({ builtin = false }).ReviewScopeBack, "ReviewScopeBack command is missing")
		local inline_mapping = vim.fn.maparg("<leader>ri", "n", false, true)
		assert((inline_mapping.rhs or ""):lower() == "<cmd>reviewinlinecomments<cr>", vim.inspect(inline_mapping))
		local back_mapping = vim.fn.maparg("<leader>rb", "n", false, true)
		assert((back_mapping.rhs or ""):lower() == "<cmd>reviewscopeback<cr>", vim.inspect(back_mapping))
		local review_comment_mapping = vim.fn.maparg("<leader>rR", "n", false, true)
		assert(
			(review_comment_mapping.rhs or ""):lower() == "<cmd>reviewgeneralcomment<cr>",
			vim.inspect(review_comment_mapping)
		)
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
		local general_item = {
			id = string.rep("e", 64),
			sequence = 6,
			type = "rationale",
			body = "general body",
			anchor = { kind = "general", stale = false },
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
		local picker
		vim.ui.select = function(choices, options)
			picker = { choices = choices, options = options }
		end
		workspace.panel.visible = true
		workspace.session.items = { first, unrelated, general_item }
		review.edit()
		assert(picker and #picker.choices == 3, "review action did not open the shared comment picker")
		local picker_labels = {}
		for _, choice in ipairs(picker.choices) do
			picker_labels[choice.id] = picker.options.format_item(choice)
		end
		assert(picker_labels[first.id]:find("[CURRENT] new.lua:2-4", 1, true))
		assert(picker_labels[unrelated.id]:find("[OLD] new.lua:1-4", 1, true))
		assert(
			not picker_labels[general_item.id]:find("[OLD]", 1, true)
				and not picker_labels[general_item.id]:find("[CURRENT]", 1, true),
			"review-level picker item invented a review side"
		)
		assert(
			picker_labels[general_item.id]:find("review", 1, true),
			"review-level item retained internal terminology"
		)
		vim.ui.select = original_select
		workspace.panel.visible = false
		workspace.session.items = all_preview_items
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
		local function assert_modal_options(options, kind)
			assert(options.source_win == source_win and options.anchor.kind == kind)
			assert(options.anchor_line == nil, kind .. " composer received an incidental anchor line")
			assert(options.anchor_range == nil, kind .. " composer received an incidental anchor range")
		end
		vim.api.nvim_set_current_win(source_win)
		vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
		assert(review._show_inline_preview())
		review.comment(2, 3, "question")
		assert(#calls.composed == composed_before + 1 and #preview_marks() == 0)
		local range_options = calls.composed[#calls.composed].options
		assert(range_options.title == "New")
		assert(range_options.source_win == source_win and range_options.anchor_line == 3)
		assert(range_options.anchor_range.first == 2 and range_options.anchor_range.last == 3)
		assert(range_options.anchor.kind == "range" and range_options.anchor.anchor_line == nil)

		vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
		review.file_comment("praise")
		local file_options = calls.composed[#calls.composed].options
		assert(file_options.title == "New file comment" and file_options.selected_type == "praise")
		assert_modal_options(file_options, "file")
		assert(file_options.anchor.start_line == nil and file_options.anchor.anchor_line == nil)

		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		workspace.panel.callbacks.general_comment("rationale")
		local general_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(general_options.title == "New review-level comment" and general_options.selected_type == "rationale")
		assert_modal_options(general_options, "general")
		assert(general_options.anchor.kind == "general" and general_options.anchor.anchor_line == nil)

		workspace.session.items = { first }
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.edit(first.id)
		local edit_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(edit_options.title == "Edit")
		assert(edit_options.source_win == source_win and edit_options.anchor_line == 4)
		assert(edit_options.anchor_range.first == 2 and edit_options.anchor_range.last == 4)

		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.reply(first.id)
		local reply_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(reply_options.title == "Reply" and reply_options.selected_type == nil)
		assert(reply_options.source_win == source_win and reply_options.anchor_line == 4)
		assert(reply_options.anchor_range.first == 2 and reply_options.anchor_range.last == 4)

		workspace.session.items = { file_item }
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.edit(file_item.id)
		local file_edit_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(file_edit_options.title == "Edit file comment" and file_edit_options.selected_type == file_item.type)
		assert_modal_options(file_edit_options, "file")
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.reply(file_item.id)
		local file_reply_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(
			file_reply_options.title == "Reply to file comment" and file_reply_options.selected_type == file_item.type
		)
		assert_modal_options(file_reply_options, "file")

		workspace.session.items = { general_item }
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.edit(general_item.id)
		local general_edit_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(
			general_edit_options.title == "Edit review-level comment"
				and general_edit_options.selected_type == general_item.type
		)
		assert_modal_options(general_edit_options, "general")
		workspace.panel.visible = true
		vim.api.nvim_set_current_win(comments_win)
		review.reply(general_item.id)
		local general_reply_options = calls.composed[#calls.composed].options
		assert(not workspace.panel.visible and vim.api.nvim_get_current_win() == source_win)
		assert(
			general_reply_options.title == "Reply to review-level comment"
				and general_reply_options.selected_type == general_item.type
		)
		assert_modal_options(general_reply_options, "general")

		local saved_presentation = workspace.mode_state.presentation
		local saved_source = workspace.panel.source_win
		workspace.mode_state.presentation = nil
		workspace.panel.source_win = -1
		vim.api.nvim_set_current_win(comments_win)
		local composed_without_source = #calls.composed
		review.general_comment("issue")
		assert(#calls.composed == composed_without_source, "review-level comment opened without reviewed source")
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
			or name == "delete"
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
		elseif name == "editor_compose" or name == "editor_has_active" then
			editor_module[name:sub(8)] = value
		end
	end
	review.file_comment = original_file_comment
	vim.notify = original_notify
	vim.ui.select = original_select
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
