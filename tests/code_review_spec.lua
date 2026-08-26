vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.g.mapleader = " "

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

local review = require("config.code_review")
local installed_controller

test("ReviewOpen parser keeps explicit scope vocabulary", function()
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
	assert(vim.deep_equal(review._parse_open({ "tuicr", "round-id" }), { kind = "tuicr", round = "round-id" }))
	assert(review._parse_open({ "range", "missing-end" }) == nil)
	for _, arguments in ipairs({
		{ "working", "extra" },
		{ "commit", "HEAD", "extra" },
		{ "range", "base", "head", "extra" },
		{ "branch", "base", "head", "extra" },
		{ "tuicr", "round-id", "extra" },
	}) do
		assert(review._parse_open(arguments) == nil)
	end
end)

test("review mapping specs build normalized Diffview help groups", function()
	local groups = review.help_groups()
	local common = review.help_mappings("common")
	local diff_line = review.help_mappings("diff_line")
	local file = review.help_mappings("file")
	assert(groups.common == "review" and groups.diff_line == "review_diff" and groups.file == "review_file")
	assert(#review.mapping_specs() == 19 and #common == 15 and #diff_line == 3 and #file == 1)
	local help_mappings = vim.list_extend(vim.deepcopy(common), diff_line)
	vim.list_extend(help_mappings, file)
	for _, mapping in ipairs(help_mappings) do
		assert(mapping[1] == "n" and type(mapping[2]) == "string" and mapping[2] ~= "")
		assert(type(mapping[3]) == "string" and mapping[3] ~= "")
		assert(type(mapping[4]) == "table" and type(mapping[4].desc) == "string" and mapping[4].desc ~= "")
	end
	assert(vim.deep_equal(
		vim.tbl_map(function(mapping)
			return mapping[2]
		end, diff_line),
		{ "<leader>Ra", "<leader>Rc", "<leader>Rd" }
	))
	assert(file[1][2] == "<leader>RA")
	assert(diff_line[1][4].desc:find("Visual range", 1, true))
end)

test("review comments preserve normalized inclusive line ranges and context", function()
	local diffview = require("config.review_diffview")
	local editor = require("config.review_editor")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local root = "/tmp/review-multiline-comment"
	local workspace = {
		root = root,
		view_mode = "files",
		scope = { kind = "commit" },
		session = {
			id = "multiline",
			repo_root = root,
			scope = { kind = "commit" },
			stale = false,
			items = {},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		current_target = diffview.current_target,
		update_title = diffview.update_title,
		compose = editor.compose,
		detect_drift = scope.detect_drift,
		edit = store.edit,
		add = store.add,
		save = store.save,
		refresh_marks = review.refresh_marks,
	}
	local captured
	local lines = { "one", "two", "three", "four", "five", "six" }
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	diffview.workspace = function()
		return workspace
	end
	diffview.current_target = function()
		return {
			path = "lua/config/example.lua",
			side = "left",
			layer = "historical",
			bufnr = vim.api.nvim_get_current_buf(),
		}
	end
	diffview.update_title = function() end
	editor.compose = function(options, callback)
		assert(options.title == "New" and options.selected_type == "issue")
		assert(callback("Range body", false, "issue"))
		return true
	end
	scope.detect_drift = function()
		return { stale = false }
	end
	store.add = function(session, values)
		captured = vim.deepcopy(values.anchor)
		local copy = vim.deepcopy(session)
		copy.items[#copy.items + 1] = values
		return copy
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end

	local ok, err = xpcall(function()
		review.comment(5, 2, "issue")
		assert(captured.path == "lua/config/example.lua")
		assert(captured.side == "left" and captured.layer == "historical")
		assert(captured.start_line == 2 and captured.end_line == 5)
		assert(captured.start_column == nil and captured.end_column == nil)
		assert(captured.context == table.concat(lines, "\n"))
		assert(captured.context_hash == vim.fn.sha256(captured.context):lower())
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.current_target = originals.current_target
	diffview.update_title = originals.update_title
	editor.compose = originals.compose
	scope.detect_drift = originals.detect_drift
	store.add = originals.add
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	assert(ok, err)
end)

test("file comments use path-only anchors and comments open directly with a cyclable default type", function()
	local diffview = require("config.review_diffview")
	local editor = require("config.review_editor")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local workspace = {
		root = "/tmp/review-file-comment",
		view_mode = "files",
		scope = { kind = "commit" },
		session = {
			id = "file-comment",
			repo_root = "/tmp/review-file-comment",
			scope = { kind = "commit" },
			stale = false,
			items = {},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		current_target = diffview.current_target,
		update_title = diffview.update_title,
		compose = editor.compose,
		detect_drift = scope.detect_drift,
		add = store.add,
		save = store.save,
		refresh_marks = review.refresh_marks,
		notify = vim.notify,
	}
	local captured
	local target_options
	local compose_calls = 0
	local notices = {}
	diffview.workspace = function()
		return workspace
	end
	diffview.current_target = function(options)
		target_options = options
		return { path = "lua/config/example.lua", side = "right", layer = "working" }
	end
	diffview.update_title = function() end
	scope.detect_drift = function()
		return { stale = false }
	end
	editor.compose = function(options, callback)
		compose_calls = compose_calls + 1
		assert(options.title == "New" and options.selected_type == "issue")
		assert(
			vim.deep_equal(options.type_cycle, { "issue", "suggestion", "rationale", "question", "pedantic", "praise" })
		)
		assert(callback("File body", false, "suggestion"))
		return true
	end
	store.add = function(session, values)
		captured = vim.deepcopy(values)
		return vim.deepcopy(session)
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, title = options and options.title }
	end

	local ok, err = xpcall(function()
		review.file_comment(nil)
		assert(compose_calls == 1 and captured.type == "suggestion")
		assert(target_options.allow_panel, "file-tree focus was not accepted for file comments")
		assert(vim.deep_equal(captured.anchor, {
			path = "lua/config/example.lua",
			side = "right",
			layer = "working",
			stale = false,
		}))
		review.comment(1, 1, "unknown")
		assert(compose_calls == 1, "invalid explicit type opened a composer")
		assert(notices[#notices].message:find("Usage: ReviewComment", 1, true))
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.current_target = originals.current_target
	diffview.update_title = originals.update_title
	editor.compose = originals.compose
	scope.detect_drift = originals.detect_drift
	store.add = originals.add
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	vim.notify = originals.notify
	assert(ok, err)
end)

test("edit and reply recheck drift before opening and submitting composers", function()
	local diffview = require("config.review_diffview")
	local editor = require("config.review_editor")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local root = "/tmp/review-composer-drift"
	local workspace = {
		root = root,
		scope = { kind = "commit" },
		session = {
			id = "session",
			repo_root = root,
			scope = { kind = "commit" },
			stale = false,
			items = {
				{ id = "parent", type = "question", status = "draft", body = "Why?", anchor = {} },
			},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		update_title = diffview.update_title,
		compose = editor.compose,
		detect_drift = scope.detect_drift,
		edit = store.edit,
		reply = store.reply,
		save = store.save,
		refresh_marks = review.refresh_marks,
	}
	local drifted = false
	local callback
	local mutations = 0
	diffview.workspace = function()
		return workspace
	end
	diffview.update_title = function() end
	review.refresh_marks = function() end
	editor.compose = function(_, submitted)
		callback = submitted
		return true
	end
	scope.detect_drift = function()
		return { stale = drifted }
	end
	store.save = function(_, session)
		return session
	end
	store.edit = function(session)
		assert(session.stale)
		mutations = mutations + 1
		return vim.deepcopy(session)
	end
	store.reply = store.edit

	local ok, err = xpcall(function()
		review.edit("parent")
		assert(type(callback) == "function")
		drifted = true
		assert(callback("Changed", false) == false)
		assert(workspace.session.stale and mutations == 0)
		assert(callback("Changed", true) == false and mutations == 0)

		workspace.session.stale = false
		drifted = false
		callback = nil
		review.reply("parent")
		assert(type(callback) == "function")
		drifted = true
		assert(callback("Answer", false) == false)
		assert(workspace.session.stale and mutations == 0)
		assert(callback("Answer", true) == true and mutations == 1)

		workspace.session.stale = false
		callback = nil
		review.reply("parent")
		assert(callback == nil, "stale reply opened a composer")
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.update_title = originals.update_title
	editor.compose = originals.compose
	scope.detect_drift = originals.detect_drift
	store.edit = originals.edit
	store.reply = originals.reply
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	assert(ok, err)
end)

test("edit picker revalidates the logical session before opening the composer", function()
	local diffview = require("config.review_diffview")
	local editor = require("config.review_editor")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local workspace = {
		root = "/tmp/review-edit-picker",
		scope = { kind = "commit" },
		session = {
			id = "original-session",
			repo_root = "/tmp/review-edit-picker",
			scope = { kind = "commit" },
			stale = false,
			items = {
				{
					id = "file-comment",
					sequence = 1,
					type = "issue",
					status = "draft",
					body = "File",
					anchor = { path = "a.lua", side = "right", layer = "working", stale = false },
				},
			},
		},
	}
	local current_workspace = workspace
	local originals = {
		workspace = diffview.workspace,
		update_title = diffview.update_title,
		compose = editor.compose,
		detect_drift = scope.detect_drift,
		edit = store.edit,
		save = store.save,
		refresh_marks = review.refresh_marks,
		select = vim.ui.select,
		notify = vim.notify,
	}
	local picker_callback
	local compose_calls = 0
	local submit
	local mutations = 0
	local notices = {}
	diffview.workspace = function()
		return current_workspace
	end
	diffview.update_title = function() end
	local editor_options
	editor.compose = function(options, callback)
		compose_calls = compose_calls + 1
		editor_options = options
		submit = callback
	end
	scope.detect_drift = function()
		return { stale = false }
	end
	vim.ui.select = function(items, options, callback)
		assert(#items == 1 and items[1].id == "file-comment")
		assert(options.format_item(items[1]):find("a.lua [file]", 1, true))
		picker_callback = callback
	end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, title = options and options.title }
	end
	local edited_values
	store.edit = function(session, id, values)
		mutations = mutations + 1
		edited_values = values
		return vim.deepcopy(session)
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end

	local ok, err = xpcall(function()
		review.edit()
		assert(type(picker_callback) == "function")
		current_workspace = vim.deepcopy(workspace)
		current_workspace.session.id = "replacement-session"
		picker_callback(workspace.session.items[1])
		assert(compose_calls == 0, "replacement review opened the captured edit")
		assert(
			notices[#notices].message == "Active review changed while choosing a comment to edit; no changes were made"
		)

		current_workspace = workspace
		review.edit("file-comment")
		assert(compose_calls == 1 and type(submit) == "function")
		assert(editor_options.title == "Edit" and editor_options.selected_type == "issue")
		assert(
			vim.deep_equal(
				editor_options.type_cycle,
				{ "issue", "suggestion", "rationale", "question", "pedantic", "praise" }
			)
		)
		current_workspace = vim.deepcopy(workspace)
		current_workspace.session.id = "replacement-after-compose"
		assert(submit("Changed again", false, "question") == false)
		assert(mutations == 0, "replacement review received the captured edit")
		assert(notices[#notices].message == "Active review changed while editing a comment; no changes were made")

		current_workspace = workspace
		review.edit("file-comment")
		assert(compose_calls == 2)
		assert(submit("Changed", false, "rationale"))
		assert(mutations == 1 and vim.deep_equal(edited_values, { body = "Changed", type = "rationale" }))
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.update_title = originals.update_title
	editor.compose = originals.compose
	scope.detect_drift = originals.detect_drift
	store.edit = originals.edit
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	vim.ui.select = originals.select
	vim.notify = originals.notify
	assert(ok, err)
end)

test("TUICR publication serializes writes and blocks review mutations", function()
	local diffview = require("config.review_diffview")
	local store = require("config.review_store")
	local tuicr = require("config.review_tuicr")
	local editor = require("config.review_editor")
	local root = "/tmp/review-publication"
	local item = {
		id = "finding",
		type = "issue",
		status = "draft",
		body = "Finding body",
		reply_to = vim.NIL,
		anchor = {},
	}
	local workspace = {
		root = root,
		session = {
			id = "session",
			repo_root = root,
			stale = false,
			scope = { kind = "commit", label = "HEAD", commit_oid = string.rep("a", 40) },
			bridge = { round = "11111111-1111-1111-1111-111111111111" },
			items = { item },
		},
	}
	local originals = {
		workspace = diffview.workspace,
		update_title = diffview.update_title,
		add = tuicr.add,
		delete = store.delete,
		mark_exported = store.mark_exported,
		save = store.save,
		refresh_marks = review.refresh_marks,
		has_active = editor.has_active,
	}
	local calls = 0
	local pending
	local deleted = false
	diffview.workspace = function()
		return workspace
	end
	diffview.update_title = function() end
	review.refresh_marks = function() end
	tuicr.add = function(_, _, _, callback)
		calls = calls + 1
		pending = callback
	end
	store.delete = function()
		deleted = true
	end
	store.mark_exported = function(session, id, receipt)
		local copy = vim.deepcopy(session)
		copy.items[1].status = "exported"
		copy.items[1].export_id = receipt
		assert(id == "finding")
		return copy
	end
	store.save = function(_, session)
		return session
	end

	local ok, err = xpcall(function()
		editor.has_active = function()
			return true
		end
		review.export(false)
		assert(calls == 0, "TUICR publication started while the comment editor was open")
		editor.has_active = originals.has_active
		review.export(false)
		review.export(false)
		review.delete("finding")
		assert(calls == 1 and not deleted and type(pending) == "function")
		local suspended, suspend_err = review.suspend_for_session()
		assert(not suspended and suspend_err:find("publication", 1, true))
		pending({ id = "remote-finding" })
		assert(workspace.session.items[1].status == "exported")
		workspace.session.items[1].status = "draft"
		workspace.session.items[1].export_id = nil
		review.export(false)
		assert(calls == 2, "publication lock was not released")
		pending(nil, { message = "fixture stop" })
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.update_title = originals.update_title
	tuicr.add = originals.add
	store.delete = originals.delete
	store.mark_exported = originals.mark_exported
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	editor.has_active = originals.has_active
	assert(ok, err)
end)

test("TUICR publication sends unresolved reply ancestors before their children", function()
	local diffview = require("config.review_diffview")
	local store = require("config.review_store")
	local tuicr = require("config.review_tuicr")
	local root = "/tmp/review-publication-ancestors"
	local workspace = {
		root = root,
		session = {
			id = "ancestor-session",
			repo_root = root,
			stale = false,
			scope = { kind = "commit", label = "HEAD", commit_oid = string.rep("a", 40) },
			bridge = { round = "11111111-1111-1111-1111-111111111111" },
			items = {
				{
					id = "parent",
					type = "rationale",
					status = "resolved",
					body = "Why this structure?",
					reply_to = vim.NIL,
					anchor = {},
				},
				{
					id = "reply",
					type = "rationale",
					status = "reply",
					body = "Use the smaller interface.",
					reply_to = "parent",
					anchor = {},
				},
			},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		update_title = diffview.update_title,
		add = tuicr.add,
		respond = tuicr.respond,
		mark_exported = store.mark_exported,
		save = store.save,
		refresh_marks = review.refresh_marks,
	}
	local operations = {}
	diffview.workspace = function()
		return workspace
	end
	diffview.update_title = function() end
	review.refresh_marks = function() end
	tuicr.add = function(_, _, values, callback)
		operations[#operations + 1] = { action = "add", values = values }
		callback({ id = "remote-parent" })
	end
	tuicr.respond = function(_, _, values, callback)
		operations[#operations + 1] = { action = "respond", values = values }
		callback({ id = "remote-reply" })
	end
	store.mark_exported = function(session, id, receipt)
		local copy = vim.deepcopy(session)
		for _, item in ipairs(copy.items) do
			if item.id == id then
				item.status = "exported"
				item.export_id = receipt
				return copy
			end
		end
	end
	store.save = function(_, session)
		return session
	end

	local ok, err = xpcall(function()
		review.export(false)
		assert(#operations == 2)
		assert(operations[1].action == "add" and operations[1].values.delivery_key == "parent")
		assert(operations[2].action == "respond" and operations[2].values.delivery_key == "reply")
		assert(operations[2].values.reply_to == "remote-parent")
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.update_title = originals.update_title
	tuicr.add = originals.add
	tuicr.respond = originals.respond
	store.mark_exported = originals.mark_exported
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	assert(ok, err)
end)

test("TUICR recovery publishes the full queue and requires a forced complete export before discard", function()
	local diffview = require("config.review_diffview")
	local store = require("config.review_store")
	local tuicr = require("config.review_tuicr")
	local originals = {
		workspace = diffview.workspace,
		update_title = diffview.update_title,
		add = tuicr.add,
		mark_exported = store.mark_exported,
		save = store.save,
		refresh_marks = review.refresh_marks,
	}
	local function run(force)
		local root = "/tmp/review-publication-recovery-" .. tostring(force)
		local workspace = {
			root = root,
			session = {
				id = "recovery-session-" .. tostring(force),
				repo_root = root,
				stale = false,
				scope = { kind = "commit", label = "HEAD", commit_oid = string.rep("a", 40) },
				bridge = { round = "11111111-1111-1111-1111-111111111111" },
				items = {
					{ id = "first", type = "issue", status = "draft", body = "First", reply_to = vim.NIL, anchor = {} },
					{
						id = "second",
						type = "suggestion",
						status = "draft",
						body = "Second",
						reply_to = vim.NIL,
						anchor = {},
					},
				},
			},
		}
		local delivered = {}
		local save_calls = 0
		diffview.workspace = function()
			return workspace
		end
		tuicr.add = function(_, _, values, callback)
			delivered[#delivered + 1] = values.delivery_key
			callback({ id = "remote-" .. values.delivery_key })
		end
		store.mark_exported = function(session, id, receipt)
			local copy = vim.deepcopy(session)
			for _, item in ipairs(copy.items) do
				if item.id == id then
					item.status = "exported"
					item.export_id = receipt
					return copy
				end
			end
		end
		store.save = function()
			save_calls = save_calls + 1
			return nil, "fixture concurrent save"
		end
		review.export(force)
		assert(vim.deep_equal(delivered, { "first", "second" }), "recovery stopped before the full TUICR queue")
		assert(save_calls == 1, "recovery retried a known-conflicting local save")
		assert(workspace.unsaved_error and workspace.session.items[2].status == "exported")
		assert(workspace.recovery_exported == (force and true or nil))
		if not force then
			review.export(true)
			assert(vim.deep_equal(delivered, { "first", "second" }), "forced recovery duplicated TUICR comments")
			assert(workspace.recovery_exported, "forced retry did not recognize complete TUICR receipts")
		end
	end

	local ok, err = xpcall(function()
		diffview.update_title = function() end
		review.refresh_marks = function() end
		run(false)
		run(true)
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.update_title = originals.update_title
	tuicr.add = originals.add
	store.mark_exported = originals.mark_exported
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	assert(ok, err)
end)

test("an explicit TUICR UUID is verified for the repository before it is persisted", function()
	local diffview = require("config.review_diffview")
	local store = require("config.review_store")
	local tuicr = require("config.review_tuicr")
	local root = "/tmp/review-link-tuicr"
	local round = "11111111-1111-1111-1111-111111111111"
	local workspace = {
		root = root,
		session = { id = "session", scope = { kind = "commit" }, items = {} },
		scope = { kind = "commit" },
	}
	review._workspaces[root] = workspace
	local originals = {
		list_rounds = tuicr.list_rounds,
		link_tuicr = store.link_tuicr,
		save = store.save,
		update_title = diffview.update_title,
		refresh_marks = review.refresh_marks,
		notify = vim.notify,
	}
	local rounds = {}
	local links = 0
	tuicr.list_rounds = function(value, callback)
		assert(value == root)
		callback(rounds)
	end
	store.link_tuicr = function(session, selected)
		links = links + 1
		local copy = vim.deepcopy(session)
		copy.bridge = { round = selected }
		return copy
	end
	store.save = function(_, session)
		return session
	end
	diffview.update_title = function() end
	review.refresh_marks = function() end

	local ok, err = xpcall(function()
		review.link_tuicr(round, root)
		assert(links == 0, "unknown explicit round was persisted")
		rounds = { { round = round, repo_root = root } }
		review.link_tuicr(round, root)
		assert(links == 1 and workspace.session.bridge.round == round)

		local messages = {}
		vim.notify = function(message)
			messages[#messages + 1] = message
		end
		store.save = function()
			return nil, "fixture save conflict"
		end
		review.link_tuicr(round, root)
		assert(#messages == 1 and messages[1]:find("fixture save conflict", 1, true))
		assert(not messages[1]:find("Could not link TUICR round", 1, true))
	end, debug.traceback)
	tuicr.list_rounds = originals.list_rounds
	store.link_tuicr = originals.link_tuicr
	store.save = originals.save
	diffview.update_title = originals.update_title
	review.refresh_marks = originals.refresh_marks
	vim.notify = originals.notify
	review._workspaces[root] = nil
	assert(ok, err)
end)

test("session suspension vetoes close failures and restores the original focus", function()
	local diffview = require("config.review_diffview")
	local original_close = diffview.close
	local original_open = diffview.open
	local original_workspace = diffview.workspace
	local normal_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local review_tab = vim.api.nvim_get_current_tabpage()
	local root = "/tmp/review-session-lifecycle"
	local workspace = {
		root = root,
		tabpage = review_tab,
		view_mode = "files",
		scope = { kind = "commit" },
		session = { id = "lifecycle" },
	}
	review._workspaces[root] = workspace
	vim.api.nvim_set_current_tabpage(normal_tab)
	diffview.workspace = function(tabpage)
		return tabpage == workspace.tabpage and workspace or nil
	end

	local ok, err = xpcall(function()
		diffview.close = function()
			return nil, "fixture close failed"
		end
		local suspended, suspend_err = review.suspend_for_session()
		assert(not suspended and suspend_err:find("fixture close failed", 1, true))
		assert(vim.api.nvim_get_current_tabpage() == normal_tab and not workspace.suspending)

		diffview.close = function()
			vim.cmd("tabclose")
			workspace.tabpage = nil
			return true
		end
		diffview.open = function(value, mode)
			assert(value == workspace and mode == "files")
			vim.cmd("tabnew")
			workspace.tabpage = vim.api.nvim_get_current_tabpage()
			return true
		end
		assert(review.suspend_for_session())
		assert(vim.api.nvim_get_current_tabpage() == normal_tab)
		assert(review.restore_after_session())
		assert(vim.api.nvim_get_current_tabpage() == normal_tab)
		assert(vim.api.nvim_tabpage_is_valid(workspace.tabpage))
	end, debug.traceback)
	if workspace.tabpage and vim.api.nvim_tabpage_is_valid(workspace.tabpage) then
		vim.api.nvim_set_current_tabpage(workspace.tabpage)
		vim.cmd("tabclose")
	end
	review._workspaces[root] = nil
	diffview.close = original_close
	diffview.open = original_open
	diffview.workspace = original_workspace
	assert(ok, err)
end)

test("ReviewCode returns inherited external navigation to the exact review target", function()
	local diffview = require("config.review_diffview")
	local review_source = require("config.review_source")
	local root = vim.fn.tempname() .. "-review-root"
	local external = vim.fn.tempname() .. "-external-source.lua"
	assert(vim.fn.mkdir(root, "p") == 1)
	assert(vim.fn.writefile({ "return true" }, external) == 0)
	pcall(vim.cmd, "silent! tabonly!")
	vim.cmd("edit! " .. vim.fn.fnameescape(external))
	local source_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local review_tab = vim.api.nvim_get_current_tabpage()
	local workspace = {
		root = root,
		tabpage = review_tab,
		view_mode = "files",
		scope = { kind = "branch" },
		session = { id = "external-navigation", items = {} },
	}
	local target = {
		current_path = "lua/config/original.lua",
		layer = "working",
		revision = "LOCAL",
		side = "right",
		line = 41,
		column = 7,
	}
	review._workspaces[root] = workspace
	assert(review_source.set(source_tab, workspace, target))
	vim.api.nvim_set_current_tabpage(source_tab)
	local original_workspace = diffview.workspace
	local original_select_file = diffview.select_file
	local selected
	diffview.workspace = function()
		return nil
	end
	diffview.select_file = function(path, layer, value)
		selected = { path = path, layer = layer, target = value }
		return true
	end

	local ok, err = xpcall(function()
		review.code()
		assert(vim.api.nvim_get_current_tabpage() == review_tab, "ReviewCode did not return to the review tab")
		assert(selected and selected.path == target.current_path and selected.layer == target.layer)
		assert(vim.deep_equal(selected.target, target), "ReviewCode did not restore the captured exact target")
	end, debug.traceback)
	diffview.workspace = original_workspace
	diffview.select_file = original_select_file
	review_source.clear_workspace(workspace)
	review._workspaces[root] = nil
	pcall(vim.cmd, "silent! tabonly!")
	vim.fn.delete(external)
	vim.fn.delete(root, "d")
	assert(ok, err)
end)

test("ReviewCode preserves current-repository fallback without explicit lineage", function()
	local diffview = require("config.review_diffview")
	local repo_module = require("config.repo")
	local review_source = require("config.review_source")
	pcall(vim.cmd, "silent! tabonly!")
	vim.cmd("enew!")
	local source_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local review_tab = vim.api.nvim_get_current_tabpage()
	local root = "/tmp/review-repository-fallback"
	local workspace = {
		root = root,
		tabpage = review_tab,
		view_mode = "files",
		scope = { kind = "branch" },
		session = { id = "repository-fallback", items = {} },
	}
	review._workspaces[root] = workspace
	review_source.clear(source_tab)
	vim.api.nvim_set_current_tabpage(source_tab)
	local originals = {
		workspace = diffview.workspace,
		select_file = diffview.select_file,
		current_root = repo_module.current_root,
		relative_existing = repo_module.relative_existing,
	}
	local selected
	diffview.workspace = function()
		return nil
	end
	diffview.select_file = function(path, layer, target)
		selected = { path = path, layer = layer, target = target }
		return true
	end
	repo_module.current_root = function()
		return root
	end
	repo_module.relative_existing = function(value, path)
		assert(value == root and type(path) == "string")
		return "lua/config/current.lua"
	end

	local ok, err = xpcall(function()
		review.code()
		assert(vim.api.nvim_get_current_tabpage() == review_tab)
		assert(selected and selected.path == "lua/config/current.lua")
		assert(selected.layer == nil and selected.target == nil)
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.select_file = originals.select_file
	repo_module.current_root = originals.current_root
	repo_module.relative_existing = originals.relative_existing
	review._workspaces[root] = nil
	pcall(vim.cmd, "silent! tabonly!")
	assert(ok, err)
end)

test("overlap deletion uses stable IDs and rejects replacement sessions", function()
	local diffview = require("config.review_diffview")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local root = "/tmp/review-line-delete"
	local function anchor(values)
		return vim.tbl_extend("force", {
			path = "lua/config/example.lua",
			side = "right",
			layer = "historical",
			start_line = 12,
			end_line = 16,
			stale = false,
		}, values or {})
	end
	local function item(id, values)
		values = values or {}
		return {
			id = id,
			sequence = values.sequence or 1,
			type = values.type or "issue",
			status = values.status or "draft",
			body = values.body or id,
			reply_to = vim.NIL,
			anchor = values.anchor or anchor(),
		}
	end
	local workspace = {
		root = root,
		tabpage = vim.api.nvim_get_current_tabpage(),
		view_mode = "files",
		scope = { kind = "commit" },
		session = {
			id = "session",
			repo_root = root,
			scope = { kind = "commit" },
			stale = false,
			items = {},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		current_target = diffview.current_target,
		update_title = diffview.update_title,
		detect_drift = scope.detect_drift,
		delete = store.delete,
		save = store.save,
		refresh_marks = review.refresh_marks,
		notify = vim.notify,
		select = vim.ui.select,
	}
	local notices = {}
	local deleted = {}
	local target_calls = 0
	local drift_checks = 0
	local picker_calls = 0
	local picker
	diffview.workspace = function()
		return workspace
	end
	diffview.current_target = function()
		target_calls = target_calls + 1
		return {
			path = "lua/config/example.lua",
			side = "right",
			layer = "historical",
			winid = vim.api.nvim_get_current_win(),
		}
	end
	diffview.update_title = function() end
	scope.detect_drift = function()
		drift_checks = drift_checks + 1
		return { stale = false }
	end
	store.delete = function(session, id)
		deleted[#deleted + 1] = id
		local copy = vim.deepcopy(session)
		for index, candidate in ipairs(copy.items) do
			if candidate.id == id then
				table.remove(copy.items, index)
				break
			end
		end
		return copy
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, title = options and options.title }
	end
	vim.ui.select = function(items, options, callback)
		picker_calls = picker_calls + 1
		picker = { items = items, options = options, callback = callback }
	end
	local buffer_lines = {}
	for _ = 1, 16 do
		buffer_lines[#buffer_lines + 1] = ""
	end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, buffer_lines)
	vim.api.nvim_win_set_cursor(0, { 14, 0 })

	local ok, err = xpcall(function()
		review.delete()
		assert(#deleted == 0)
		assert(notices[#notices].message == "No review comment on the current line")
		assert(notices[#notices].title == "Review")
		assert(picker_calls == 0)

		workspace.session.items = {
			item("stale", { anchor = anchor({ stale = true }) }),
			item("exported", { status = "exported" }),
		}
		review.delete()
		assert(#deleted == 0)
		assert(notices[#notices].message == "The review comment on the current line is unavailable for this action")
		assert(picker_calls == 0)

		workspace.session.items = { item("exported", { status = "exported" }), item("local") }
		review.delete()
		assert(vim.deep_equal(deleted, { "local" }))
		assert(#workspace.session.items == 1 and workspace.session.items[1].id == "exported")
		assert(picker_calls == 0, "unique current-line deletion opened an overlap picker")

		local first = item("first", {
			sequence = 8,
			type = "suggestion",
			status = "resolved",
			body = "First body\nMore detail",
		})
		local second = item("second", {
			sequence = 3,
			type = "question",
			status = "reply",
			body = "Second body\nMore detail",
			anchor = anchor({ start_line = 14, end_line = 14 }),
		})
		workspace.session.items = {
			item("filtered-exported", { status = "exported" }),
			first,
			item("filtered-stale", { anchor = anchor({ stale = true }) }),
			item("filtered-path", { anchor = anchor({ path = "lua/config/other.lua" }) }),
			item("filtered-side", { anchor = anchor({ side = "left" }) }),
			item("filtered-layer", { anchor = anchor({ layer = "working" }) }),
			item("filtered-line", { anchor = anchor({ start_line = 1, end_line = 13 }) }),
			second,
		}
		local notices_before_cancel = #notices
		review.delete()
		assert(picker_calls == 1)
		assert(picker.options.prompt == "Delete review comment on current line")
		assert(#picker.items == 2 and picker.items[1].id == "first" and picker.items[2].id == "second")
		local first_label = picker.options.format_item(picker.items[1])
		local second_label = picker.options.format_item(picker.items[2])
		assert(first_label:find("08", 1, true) and first_label:find("suggestion", 1, true))
		assert(first_label:find("resolved", 1, true) and first_label:find("lua/config/example.lua:12-16", 1, true))
		assert(first_label:find("First body", 1, true) and not first_label:find("More detail", 1, true))
		assert(second_label:find("03", 1, true) and second_label:find("question", 1, true))
		assert(second_label:find("reply", 1, true) and second_label:find("lua/config/example.lua:14", 1, true))
		assert(not second_label:find("lua/config/example.lua:14-14", 1, true))
		picker.callback(nil)
		assert(vim.deep_equal(deleted, { "local" }) and #notices == notices_before_cancel)

		review.delete()
		assert(picker_calls == 2 and picker.items[2].id == "second")
		workspace.session = vim.deepcopy(workspace.session)
		workspace.session.items[#workspace.session.items + 1] = item("new-overlap")
		local target_calls_before_selection = target_calls
		local drift_checks_before_selection = drift_checks
		picker.callback(picker.items[2])
		assert(vim.deep_equal(deleted, { "local", "second" }))
		assert(target_calls == target_calls_before_selection + 1)
		assert(drift_checks == drift_checks_before_selection + 1)
		for _, candidate in ipairs(workspace.session.items) do
			assert(candidate.id ~= "second", "overlap deletion kept the selected ID")
		end

		for _, invalidation in ipairs({ "removed", "exported", "stale", "reanchored" }) do
			workspace.session.items = { item("fallback"), item("selected") }
			review.delete()
			assert(#picker.items == 2 and picker.items[2].id == "selected")
			if invalidation == "removed" then
				table.remove(workspace.session.items, 2)
			elseif invalidation == "exported" then
				workspace.session.items[2].status = "exported"
			elseif invalidation == "stale" then
				workspace.session.items[2].anchor.stale = true
			else
				workspace.session.items[2].anchor.start_line = 1
				workspace.session.items[2].anchor.end_line = 2
			end
			local deleted_before = #deleted
			picker.callback(picker.items[2])
			assert(#deleted == deleted_before, invalidation .. " selection deleted a fallback comment")
			assert(workspace.session.items[1].id == "fallback")
			assert(notices[#notices].message == "The review comment on the current line is unavailable for this action")
		end

		workspace.session.items = { item("first"), item("selected") }
		review.delete()
		local stale_picker = picker
		local selected_workspace = workspace
		local replacement_workspace = vim.deepcopy(workspace)
		replacement_workspace.session.id = "replacement-session"
		replacement_workspace.session.items = { item("replacement") }
		workspace = replacement_workspace
		local deleted_before_replacement = #deleted
		stale_picker.callback(stale_picker.items[2])
		assert(#deleted == deleted_before_replacement, "stale overlap picker deleted from a captured session")
		assert(#selected_workspace.session.items == 2 and selected_workspace.session.items[2].id == "selected")
		assert(#replacement_workspace.session.items == 1 and replacement_workspace.session.items[1].id == "replacement")
		assert(
			notices[#notices].message
				== "Active review changed while choosing a comment to delete; no changes were made"
		)
		assert(notices[#notices].level == vim.log.levels.WARN and notices[#notices].title == "Review")
		workspace = selected_workspace

		workspace.session.items = { item("explicit") }
		local calls_before = target_calls
		review.delete("explicit")
		assert(vim.deep_equal(deleted, { "local", "second", "explicit" }))
		assert(target_calls == calls_before, "explicit ID deletion inspected the current line")
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.current_target = originals.current_target
	diffview.update_title = originals.update_title
	scope.detect_drift = originals.detect_drift
	store.delete = originals.delete
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	vim.notify = originals.notify
	vim.ui.select = originals.select
	assert(ok, err)
end)

test("changing a line comment type uses the ordered picker and latest item state", function()
	local diffview = require("config.review_diffview")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local root = "/tmp/review-line-type"
	local anchor = {
		path = "lua/config/example.lua",
		side = "right",
		layer = "historical",
		start_line = 7,
		end_line = 11,
		stale = false,
	}
	local workspace = {
		root = root,
		tabpage = vim.api.nvim_get_current_tabpage(),
		view_mode = "files",
		scope = { kind = "commit" },
		session = {
			id = "session",
			repo_root = root,
			scope = { kind = "commit" },
			stale = false,
			items = {
				{
					id = "resolved",
					sequence = 1,
					type = "question",
					status = "resolved",
					body = "Original body",
					reply_to = vim.NIL,
					anchor = anchor,
				},
			},
		},
	}
	local originals = {
		workspace = diffview.workspace,
		current_target = diffview.current_target,
		update_title = diffview.update_title,
		detect_drift = scope.detect_drift,
		set_type = store.set_type,
		save = store.save,
		refresh_marks = review.refresh_marks,
		notify = vim.notify,
		select = vim.ui.select,
	}
	local picker_callback
	local drift_checks = 0
	local mutations = 0
	local picker_calls = 0
	local notices = {}
	diffview.workspace = function()
		return workspace
	end
	diffview.current_target = function()
		return {
			path = anchor.path,
			side = anchor.side,
			layer = anchor.layer,
			winid = vim.api.nvim_get_current_win(),
		}
	end
	diffview.update_title = function() end
	scope.detect_drift = function()
		drift_checks = drift_checks + 1
		return { stale = false }
	end
	store.set_type = function(session, id, item_type)
		mutations = mutations + 1
		assert(id == "resolved" and item_type == "rationale")
		assert(session.items[1].body == "Latest body", "type change used the pre-picker item")
		assert(session.items[1].status == "resolved")
		local copy = vim.deepcopy(session)
		copy.items[1].type = item_type
		return copy
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end
	vim.notify = function(message)
		notices[#notices + 1] = message
	end
	vim.ui.select = function(items, options, callback)
		picker_calls = picker_calls + 1
		assert(vim.deep_equal(items, { "issue", "suggestion", "rationale", "question", "pedantic", "praise" }))
		assert(options.prompt == "Review comment type")
		assert(options.format_item("suggestion") == "Suggestion")
		picker_callback = callback
	end
	local buffer_lines = {}
	for _ = 1, 11 do
		buffer_lines[#buffer_lines + 1] = ""
	end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, buffer_lines)
	vim.api.nvim_win_set_cursor(0, { 9, 0 })

	local ok, err = xpcall(function()
		review.change_type()
		assert(type(picker_callback) == "function" and drift_checks == 1 and picker_calls == 1)
		picker_callback(nil)
		assert(mutations == 0 and #notices == 0 and drift_checks == 1)

		picker_callback = nil
		review.change_type()
		assert(type(picker_callback) == "function" and picker_calls == 2)
		workspace.session.items[1].body = "Latest body"
		picker_callback("rationale")
		assert(drift_checks == 3 and mutations == 1)
		assert(workspace.session.items[1].type == "rationale")
		assert(workspace.session.items[1].status == "resolved")
		assert(#notices == 0)
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.current_target = originals.current_target
	diffview.update_title = originals.update_title
	scope.detect_drift = originals.detect_drift
	store.set_type = originals.set_type
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	vim.notify = originals.notify
	vim.ui.select = originals.select
	assert(ok, err)
end)

test("overlapping type changes re-resolve stable IDs and reject replacement sessions", function()
	local diffview = require("config.review_diffview")
	local scope = require("config.review_scope")
	local store = require("config.review_store")
	local root = "/tmp/review-line-type-recheck"
	local function item(id, values)
		values = values or {}
		return {
			id = id,
			sequence = values.sequence or 1,
			type = values.type or "question",
			status = values.status or "draft",
			body = values.body or id,
			reply_to = vim.NIL,
			anchor = {
				path = "lua/config/example.lua",
				side = "right",
				layer = "historical",
				start_line = values.start_line or 7,
				end_line = values.end_line or 11,
				stale = values.stale or false,
			},
		}
	end
	local workspace = {
		root = root,
		tabpage = vim.api.nvim_get_current_tabpage(),
		view_mode = "files",
		scope = { kind = "commit" },
		session = {
			id = "session",
			repo_root = root,
			scope = { kind = "commit" },
			stale = false,
			items = { item("original") },
		},
	}
	local originals = {
		workspace = diffview.workspace,
		current_target = diffview.current_target,
		update_title = diffview.update_title,
		detect_drift = scope.detect_drift,
		set_type = store.set_type,
		save = store.save,
		refresh_marks = review.refresh_marks,
		notify = vim.notify,
		select = vim.ui.select,
	}
	local pickers = {}
	local mutations = {}
	local notices = {}
	diffview.workspace = function()
		return workspace
	end
	diffview.current_target = function()
		return {
			path = "lua/config/example.lua",
			side = "right",
			layer = "historical",
			winid = vim.api.nvim_get_current_win(),
		}
	end
	diffview.update_title = function() end
	scope.detect_drift = function()
		return { stale = false }
	end
	store.set_type = function(session, id, item_type)
		mutations[#mutations + 1] = { id = id, item_type = item_type }
		local copy = vim.deepcopy(session)
		for _, candidate in ipairs(copy.items) do
			if candidate.id == id then
				candidate.type = item_type
				return copy
			end
		end
		error("selected type-change ID was not present")
	end
	store.save = function(_, session)
		return session
	end
	review.refresh_marks = function() end
	vim.notify = function(message, level, options)
		notices[#notices + 1] = { message = message, level = level, title = options and options.title }
	end
	vim.ui.select = function(items, options, callback)
		pickers[#pickers + 1] = { items = items, options = options, callback = callback }
	end
	local buffer_lines = {}
	for _ = 1, 11 do
		buffer_lines[#buffer_lines + 1] = ""
	end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, buffer_lines)

	local ok, err = xpcall(function()
		local ordered_types = { "issue", "suggestion", "rationale", "question", "pedantic", "praise" }
		local function open_comment_picker()
			review.change_type()
			local current = pickers[#pickers]
			assert(current.options.prompt == "Change type of review comment on current line")
			assert(#current.items == 2 and current.items[1].id == "first" and current.items[2].id == "selected")
			return current
		end
		local function choose_comment(current)
			current.callback(current.items[2])
			local type_picker = pickers[#pickers]
			assert(vim.deep_equal(type_picker.items, ordered_types))
			assert(type(type_picker.options.format_item) == "function")
			assert(type_picker.options.format_item("issue") == "Issue")
			assert(type_picker.options.prompt == "Review comment type")
			return type_picker
		end

		vim.api.nvim_win_set_cursor(0, { 9, 0 })
		workspace.session.items = { item("first", { sequence = 4 }), item("selected", { sequence = 2 }) }
		local notices_before_cancel = #notices
		local comment_picker = open_comment_picker()
		comment_picker.callback(nil)
		assert(#pickers == 1 and #mutations == 0 and #notices == notices_before_cancel)

		comment_picker = open_comment_picker()
		local type_picker = choose_comment(comment_picker)
		type_picker.callback(nil)
		assert(#mutations == 0 and #notices == notices_before_cancel)

		comment_picker = open_comment_picker()
		type_picker = choose_comment(comment_picker)
		workspace.session = vim.deepcopy(workspace.session)
		workspace.session.items[#workspace.session.items + 1] = item("new-overlap")
		type_picker.callback("rationale")
		assert(#mutations == 1 and mutations[1].id == "selected" and mutations[1].item_type == "rationale")
		assert(workspace.session.items[1].type == "question")
		assert(workspace.session.items[2].id == "selected" and workspace.session.items[2].type == "rationale")
		assert(workspace.session.items[3].id == "new-overlap" and workspace.session.items[3].type == "question")

		workspace.session.items = { item("first"), item("selected") }
		vim.api.nvim_win_set_cursor(0, { 9, 0 })
		comment_picker = open_comment_picker()
		type_picker = choose_comment(comment_picker)
		vim.api.nvim_win_set_cursor(0, { 6, 0 })
		type_picker.callback("rationale")
		assert(#mutations == 1)
		assert(notices[#notices].message == "No review comment on the current line")
		assert(notices[#notices].title == "Review")

		for _, invalidation in ipairs({ "removed", "exported", "stale", "reanchored" }) do
			workspace.session.items = { item("first"), item("selected") }
			vim.api.nvim_win_set_cursor(0, { 9, 0 })
			comment_picker = open_comment_picker()
			type_picker = choose_comment(comment_picker)
			if invalidation == "removed" then
				table.remove(workspace.session.items, 2)
			elseif invalidation == "exported" then
				workspace.session.items[2].status = "exported"
			elseif invalidation == "stale" then
				workspace.session.items[2].anchor.stale = true
			else
				workspace.session.items[2].anchor.start_line = 1
				workspace.session.items[2].anchor.end_line = 2
			end
			local mutation_count = #mutations
			type_picker.callback("rationale")
			assert(#mutations == mutation_count, invalidation .. " type change mutated a fallback comment")
			assert(workspace.session.items[1].id == "first" and workspace.session.items[1].type == "question")
			assert(notices[#notices].message == "The review comment on the current line is unavailable for this action")
		end

		workspace.session.items = { item("first"), item("selected") }
		vim.api.nvim_win_set_cursor(0, { 9, 0 })
		comment_picker = open_comment_picker()
		local overlap_workspace = workspace
		local overlap_replacement = vim.deepcopy(workspace)
		overlap_replacement.session.id = "replacement-overlap-session"
		overlap_replacement.session.items = { item("replacement"), item("selected") }
		workspace = overlap_replacement
		type_picker = choose_comment(comment_picker)
		local mutation_count = #mutations
		type_picker.callback("rationale")
		assert(#mutations == mutation_count, "stale overlap picker changed a captured session")
		assert(overlap_workspace.session.items[2].type == "question")
		assert(overlap_replacement.session.items[2].type == "question")
		assert(notices[#notices].message == "Active review changed while choosing a comment type; no changes were made")
		assert(notices[#notices].level == vim.log.levels.WARN and notices[#notices].title == "Review")

		workspace = overlap_workspace
		workspace.session.items = { item("first"), item("selected") }
		comment_picker = open_comment_picker()
		type_picker = choose_comment(comment_picker)
		local type_picker_workspace = workspace
		local type_picker_replacement = vim.deepcopy(workspace)
		type_picker_replacement.session.id = "replacement-type-session"
		type_picker_replacement.session.items = { item("replacement"), item("selected") }
		workspace = type_picker_replacement
		mutation_count = #mutations
		type_picker.callback("rationale")
		assert(#mutations == mutation_count, "stale type picker changed a captured session")
		assert(type_picker_workspace.session.items[2].type == "question")
		assert(type_picker_replacement.session.items[2].type == "question")
		assert(notices[#notices].message == "Active review changed while choosing a comment type; no changes were made")
		assert(notices[#notices].level == vim.log.levels.WARN and notices[#notices].title == "Review")
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.current_target = originals.current_target
	diffview.update_title = originals.update_title
	scope.detect_drift = originals.detect_drift
	store.set_type = originals.set_type
	store.save = originals.save
	review.refresh_marks = originals.refresh_marks
	vim.notify = originals.notify
	vim.ui.select = originals.select
	assert(ok, err)
end)

test("multiline comments render deterministic range text without marking file comments", function()
	local diffview = require("config.review_diffview")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
	local workspace = {
		view_mode = "files",
		session = {
			stale = false,
			items = {
				{
					id = "second",
					sequence = 2,
					type = "suggestion",
					anchor = {
						path = "a.lua",
						side = "right",
						layer = "working",
						start_line = 2,
						end_line = 5,
						stale = false,
					},
				},
				{
					id = "first",
					sequence = 1,
					type = "issue",
					anchor = {
						path = "a.lua",
						side = "right",
						layer = "working",
						start_line = 2,
						end_line = 4,
						stale = false,
					},
				},
				{
					id = "file",
					sequence = 3,
					type = "question",
					anchor = { path = "a.lua", side = "right", layer = "working", stale = false },
				},
			},
		},
	}
	local original_target = diffview.current_target
	diffview.current_target = function()
		return { bufnr = buf, path = "a.lua", side = "right", layer = "working" }
	end

	local ok, err = xpcall(function()
		review.decorate_buffer(workspace, buf)
		local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
		local signs = 0
		local range_chunks
		for _, mark in ipairs(marks) do
			local details = mark[4]
			if details.sign_text then
				signs = signs + 1
			end
			if details.virt_text then
				range_chunks = details.virt_text
			end
		end
		assert(signs == 2, "file-level comment drew a line sign")
		assert(range_chunks and range_chunks[1][1] == "  ● 2-4" and range_chunks[2][1] == "  ● 2-5")
	end, debug.traceback)
	diffview.current_target = original_target
	vim.api.nvim_buf_delete(buf, { force = true })
	assert(ok, err)
end)

test("comment list picker jumps without mutating review state", function()
	local diffview = require("config.review_diffview")
	local workspace = {
		root = "/tmp/review-comment-list",
		tabpage = vim.api.nvim_get_current_tabpage(),
		view_mode = "files",
		session = {
			stale = false,
			items = {
				{
					id = "navigable",
					sequence = 1,
					type = "suggestion",
					status = "draft",
					body = "Use the helper",
					anchor = {
						path = "lua/config/example.lua",
						side = "right",
						layer = "historical",
						start_line = 22,
						start_column = 4,
						stale = false,
					},
				},
				{
					id = "file-level",
					sequence = 2,
					type = "issue",
					status = "draft",
					body = "Whole file",
					anchor = {
						path = "lua/config/file.lua",
						side = "right",
						layer = "historical",
						stale = false,
					},
				},
				{
					id = "stale",
					sequence = 3,
					type = "issue",
					status = "draft",
					body = "Old location",
					anchor = {
						path = "lua/old.lua",
						side = "right",
						layer = "historical",
						start_line = 3,
						stale = true,
					},
				},
			},
		},
	}
	local before = vim.deepcopy(workspace.session)
	local originals = {
		workspace = diffview.workspace,
		select_file = diffview.select_file,
		select = vim.ui.select,
	}
	local selected
	local selection_calls = 0
	diffview.workspace = function()
		return workspace
	end
	diffview.select_file = function(path, layer, target)
		selection_calls = selection_calls + 1
		selected = { path = path, layer = layer, target = target }
		return true
	end
	vim.ui.select = function(items, options, callback)
		assert(options.prompt == "Review comments")
		assert(#items == 2 and items[2].id == "file-level")
		assert(options.format_item(items[1]):find("lua/config/example.lua:22", 1, true))
		assert(options.format_item(items[2]):find("lua/config/file.lua [file]", 1, true))
		callback(items[2])
	end

	local ok, err = xpcall(function()
		review.comments()
		assert(selection_calls == 1)
		assert(selected.path == "lua/config/file.lua" and selected.layer == "historical")
		assert(selected.target.side == "right" and selected.target.line == nil and selected.target.column == nil)
		assert(vim.deep_equal(workspace.session, before), "comment navigation mutated the review")

		vim.ui.select = function(items, _, callback)
			assert(#items == 2)
			callback(nil)
		end
		review.comments()
		assert(selection_calls == 1, "picker cancellation changed the selected review location")
		review.next()
		review.next()
		assert(selection_calls == 3 and selected.path == "lua/config/file.lua")
	end, debug.traceback)
	diffview.workspace = originals.workspace
	diffview.select_file = originals.select_file
	vim.ui.select = originals.select
	assert(ok, err)
end)

test("setup exposes the namespaced command and mapping surface", function()
	local diffview = require("config.review_diffview")
	local original_set_controller = diffview.set_controller
	diffview.set_controller = function(callbacks)
		installed_controller = callbacks
		original_set_controller(callbacks)
	end
	review.setup()
	diffview.set_controller = original_set_controller
	assert(type(installed_controller) == "table")
	for _, command in ipairs({
		"ReviewOpen",
		"ReviewScope",
		"ReviewSessions",
		"ReviewFiles",
		"ReviewCommits",
		"ReviewCode",
		"ReviewLayout",
		"ReviewContext",
		"ReviewComments",
		"ReviewComment",
		"ReviewFileComment",
		"ReviewThreads",
		"ReviewReply",
		"ReviewEdit",
		"ReviewDeleteDraft",
		"ReviewChangeType",
		"ReviewResolve",
		"ReviewReopen",
		"ReviewNext",
		"ReviewPrev",
		"ReviewRefresh",
		"ReviewExport",
		"ReviewLinkTuicr",
		"ReviewClose",
	}) do
		assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
	end
	for _, mapping in ipairs({
		"<leader>Ro",
		"<leader>Rs",
		"<leader>Rf",
		"<leader>Rh",
		"<leader>Rg",
		"<leader>Rv",
		"<leader>Rw",
		"<leader>Rl",
		"<leader>Ra",
		"<leader>RA",
		"<leader>RE",
		"<leader>Rc",
		"<leader>Rd",
		"<leader>Rt",
		"<leader>Re",
		"<leader>Rr",
		"<leader>Rq",
		"[r",
		"]r",
	}) do
		assert(vim.fn.maparg(mapping, "n") ~= "", mapping .. " is missing")
	end
	for lhs, rhs in pairs({
		["<leader>Rg"] = "<Cmd>ReviewCode<CR>",
		["<leader>Rv"] = "<Cmd>ReviewLayout<CR>",
		["<leader>Rw"] = "<Cmd>ReviewContext<CR>",
		["<leader>Rl"] = "<Cmd>ReviewComments<CR>",
		["<leader>RA"] = "<Cmd>ReviewFileComment<CR>",
		["<leader>RE"] = "<Cmd>ReviewEdit<CR>",
		["<leader>Rc"] = "<Cmd>ReviewChangeType<CR>",
		["<leader>Rd"] = "<Cmd>ReviewDeleteDraft<CR>",
	}) do
		assert(vim.fn.maparg(lhs, "n") == rhs, lhs .. " has unexpected RHS " .. vim.fn.maparg(lhs, "n"))
	end
	local original_context = diffview.context
	local context_calls = {}
	diffview.context = function(mode)
		context_calls[#context_calls + 1] = mode == nil and "toggle" or mode
		return true
	end
	vim.cmd("ReviewContext")
	vim.cmd("ReviewContext full")
	vim.cmd("ReviewContext hunks")
	diffview.context = original_context
	assert(vim.deep_equal(context_calls, { "toggle", "full", "hunks" }))
	local original_notify = vim.notify
	local warning
	vim.notify = function(message)
		warning = message
	end
	vim.cmd("ReviewContext invalid")
	vim.notify = original_notify
	assert(warning == "Usage: ReviewContext [hunks|full]", "invalid context argument did not show concise usage")
	assert(vim.fn.maparg("<leader>Ra", "x") == ":<C-U>'<,'>ReviewComment<CR>")
	local add_mapping = vim.fn.maparg("<leader>Ra", "n", false, true)
	assert(add_mapping.desc:find("Visual range", 1, true), "normal review comment help omits Visual ranges")

	local original_workspace = diffview.workspace
	local original_close = diffview.close
	local closed = 0
	local workspace = {
		root = "/tmp/review-empty-recovery",
		tabpage = vim.api.nvim_get_current_tabpage(),
		unsaved_error = "fixture conflict",
		session = { id = "empty", items = {} },
	}
	diffview.workspace = function()
		return workspace
	end
	diffview.close = function()
		closed = closed + 1
		return true
	end
	vim.cmd("ReviewClose!")
	assert(closed == 1, "metadata-only conflict could not be explicitly discarded")
	workspace.session.items = { { id = "draft" } }
	pcall(vim.cmd, "ReviewClose!")
	assert(closed == 1, "unexported recovery data was discarded")
	workspace.recovery_exported = true
	vim.cmd("ReviewClose!")
	assert(closed == 2, "fully exported recovery could not be discarded")
	diffview.workspace = original_workspace
	diffview.close = original_close
end)

test("only a final non-transition review closure requests home recovery", function()
	local tab_config = require("config.tabs")
	local original_ensure_home = tab_config.ensure_home
	local requests = 0
	tab_config.ensure_home = function()
		requests = requests + 1
		return true
	end

	local owned_roots = {}
	local function workspace(label)
		local value = {
			root = "/tmp/review-home-recovery-" .. label,
			session = { id = label, items = {} },
		}
		review._workspaces[value.root] = value
		owned_roots[#owned_roots + 1] = value.root
		return value
	end

	local ok, err = xpcall(function()
		local final = workspace("final")
		installed_controller.view_closed(final)
		assert(review._workspaces[final.root] == nil, "final closed review remained registered")
		assert(requests == 1, "final review closure did not request home recovery")

		local first = workspace("first-of-two")
		local remaining = workspace("remaining")
		installed_controller.view_closed(first)
		assert(review._workspaces[first.root] == nil and review._workspaces[remaining.root] == remaining)
		assert(requests == 1, "non-final review closure requested home recovery")
		review._workspaces[remaining.root] = nil

		for _, transition in ipairs({ "suspending", "replacing", "reopening" }) do
			local current = workspace(transition)
			current[transition] = true
			installed_controller.view_closed(current)
			assert(review._workspaces[current.root] == current, transition .. " closure removed the review workspace")
			assert(requests == 1, transition .. " closure requested home recovery")
			review._workspaces[current.root] = nil
		end
	end, debug.traceback)
	tab_config.ensure_home = original_ensure_home
	for _, root in ipairs(owned_roots) do
		review._workspaces[root] = nil
	end
	assert(ok, err)
end)

test("closing a review clears every inherited source lineage", function()
	local review_source = require("config.review_source")
	local workspace = {
		root = "/tmp/review-lineage-close",
		tabpage = vim.api.nvim_get_current_tabpage(),
		session = { id = "lineage-close", items = {} },
	}
	review._workspaces[workspace.root] = workspace
	assert(review_source.set(vim.api.nvim_get_current_tabpage(), workspace, { current_path = "closed.lua" }))
	installed_controller.view_closed(workspace)
	assert(review._workspaces[workspace.root] == nil, "closed review remained current")
	assert(review_source.get(vim.api.nvim_get_current_tabpage()) == nil, "closed review kept inherited lineage")
end)

test("global teardown persists every unsaved conflict recovery", function()
	local export = require("config.review_export")
	local store = require("config.review_store")
	local original_render = export.render
	local original_save_recovery = store.save_recovery
	local workspace = {
		root = "/tmp/review-conflict-recovery",
		unsaved_error = "fixture conflict",
		session = { id = "conflict", items = { { id = "draft" } } },
	}
	local saved_markdown
	export.render = function(session, force)
		assert(session == workspace.session and force)
		return "# Complete recovery", { "draft" }
	end
	store.save_recovery = function(root, session, markdown)
		assert(root == workspace.root and session == workspace.session)
		saved_markdown = markdown
		return { path = "/tmp/review-conflict-recovery.md", digest = string.rep("a", 64) }
	end

	local ok, err = xpcall(function()
		review._workspaces[workspace.root] = workspace
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
		assert(saved_markdown == "# Complete recovery")
		assert(workspace.automatic_recovery.path == "/tmp/review-conflict-recovery.md")
	end, debug.traceback)
	review._workspaces[workspace.root] = nil
	export.render = original_render
	store.save_recovery = original_save_recovery
	assert(ok, err)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("code_review_spec: %d tests passed", count))
vim.cmd("quitall!")
