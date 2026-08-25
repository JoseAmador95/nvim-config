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
		assert(callback("Changed", true) == true and mutations == 1)

		workspace.session.stale = false
		drifted = false
		callback = nil
		review.reply("parent")
		assert(type(callback) == "function")
		drifted = true
		assert(callback("Answer", false) == false)
		assert(workspace.session.stale and mutations == 1)
		assert(callback("Answer", true) == true and mutations == 2)

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
		"ReviewComment",
		"ReviewThreads",
		"ReviewReply",
		"ReviewEdit",
		"ReviewDeleteDraft",
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
		"<leader>Rv",
		"<leader>Rl",
		"<leader>Ra",
		"<leader>Rt",
		"<leader>Re",
		"<leader>Rr",
		"<leader>Rq",
		"[r",
		"]r",
	}) do
		assert(vim.fn.maparg(mapping, "n") ~= "", mapping .. " is missing")
	end

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
