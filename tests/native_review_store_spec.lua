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
local state
local comment_types
local host_comment_types
local function test(name, callback)
	count = count + 1
	if state then
		vim.fn.delete(state, "rf")
		assert(vim.fn.mkdir(state, "p") == 1)
	end
	local ok, err = xpcall(function()
		comment_types.configure({})
		callback()
	end, debug.traceback)
	local restored, restore_err = pcall(comment_types.configure, host_comment_types)
	if not restored then
		failures[#failures + 1] = name .. "\nCould not restore host comment types: " .. tostring(restore_err)
	end
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local config_fs = require("config.fs")
local native_review = require("config.native_review")
comment_types = native_review.comment_types
host_comment_types = native_review.effective_config().comment_types or {}
local exporter = native_review.export
local scope_module = native_review.scope
local store = native_review.store
local root = "/tmp/review-store-repository"
local oid = string.rep("a", 40)
state = vim.fn.tempname()
assert(vim.fn.mkdir(state, "p") == 1)

local tick = 0
local writes = 0
local deps = {
	state_home = state,
	root = function(value)
		assert(value == root)
		return root
	end,
	now = function()
		tick = tick + 1
		return string.format("2026-08-25T12:00:%02dZ", tick % 60)
	end,
	fs = {
		read_binary = config_fs.read_binary,
		write_binary_atomic = function(path, data)
			writes = writes + 1
			return config_fs.write_binary_atomic(path, data)
		end,
	},
}

local function working_scope(fingerprint)
	fingerprint = fingerprint or vim.fn.sha256("working")
	local value = {
		version = 1,
		root = root,
		kind = "working",
		backend_id = "diffview",
		label = "Working tree @ " .. oid:sub(1, 12),
		head_oid = oid,
		fingerprint = fingerprint,
		layers = {
			head = oid,
			staged = vim.fn.sha256("staged"),
			unstaged = vim.fn.sha256("unstaged"),
			untracked = vim.fn.sha256("untracked"),
		},
		diffview_args = {},
	}
	value.id = assert(scope_module.scope_id(root, value))
	return value
end

local function fresh()
	return assert(store.new(root, working_scope(), deps))
end

local function add_root(session, item_type)
	return assert(store.add(session, {
		type = item_type or "issue",
		body = "Review this implementation",
		anchor = {
			path = "src//main.lua",
			side = "right",
			layer = "working",
			context = "local context",
			context_hash = vim.fn.sha256("local context"),
			stale = false,
			start_line = 4,
			start_column = 2,
			end_line = 5,
			end_column = 3,
		},
	}, deps))
end

local function legacy_value(session, statuses, export_ids)
	local legacy = vim.deepcopy(session)
	legacy.version = 1
	for index, item in ipairs(legacy.items) do
		item.anchor.kind = nil
		item.origin_engine = nil
		item.status = statuses[index]
		item.resolution = nil
		item.deliveries = nil
		local export_id = export_ids and export_ids[index]
		if export_id then
			item.exported_at = "2026-08-25T11:00:00Z"
			item.export_id = export_id
		else
			item.exported_at = vim.NIL
			item.export_id = vim.NIL
		end
	end
	return legacy
end

local function write_legacy(session)
	local directory = vim.fs.joinpath(state, "nvim-config", "reviews", "v" .. session.version, vim.fn.sha256(root))
	assert(vim.fn.mkdir(directory, "p", 448) == 1)
	local path = vim.fs.joinpath(directory, session.id .. ".json")
	local encoded = vim.json.encode(session) .. "\n"
	assert(config_fs.write_binary_atomic(path, encoded))
	assert(vim.uv.fs_chmod(path, 384))
	return path, encoded
end

test("session and scope identities are deterministic and include the working fingerprint", function()
	local first = fresh()
	local second = fresh()
	assert(first.version == 3 and first.scope.version == 1)
	assert(first.id == second.id and first.repo_hash == second.repo_hash)
	local changed_scope = working_scope(vim.fn.sha256("changed"))
	assert(changed_scope.id ~= first.id)
	local changed = assert(store.new(root, changed_scope, deps))
	assert(changed.id == changed_scope.id)
end)

test("legacy bridge and delivery metadata round-trip strictly but remain inert", function()
	local session = add_root(fresh())
	session.bridge = {
		backend = "tuicr",
		round = "123e4567-e89b-12d3-a456-426614174000",
		trusted_scope_id = session.id,
		linked_at = "2026-08-25T10:00:00Z",
	}
	session.items[1].deliveries = {
		{ backend = "tuicr", receipt = "legacy-receipt", delivered_at = "2026-08-25T10:00:01Z" },
	}
	local before = vim.deepcopy(session)
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded.bridge, before.bridge))
	assert(vim.deep_equal(loaded.items[1].deliveries, before.items[1].deliveries))
	assert(store.link_tuicr == nil and store.mark_tuicr_delivered == nil and store.mark_exported == nil)
	assert(store.item_status(loaded.items[1]) == "draft")
	loaded = assert(store.edit(loaded, loaded.items[1].id, { body = "Native edit" }, deps))
	assert(vim.deep_equal(loaded.items[1].deliveries, before.items[1].deliveries))

	loaded.bridge.backend = "github"
	local invalid_backend, backend_err = store.save(root, loaded, deps)
	assert(not invalid_backend and backend_err:find("backend must be tuicr", 1, true))
end)

test("anchor metadata survives add, edit, reply, save, and load", function()
	local session = add_root(fresh())
	local root_item = session.items[1]
	assert(root_item.anchor.layer == "working")
	assert(root_item.anchor.context == "local context")
	assert(root_item.anchor.context_hash == vim.fn.sha256("local context"))
	assert(root_item.anchor.stale == false)

	local context = "updated context"
	local updated_anchor = {
		kind = "range",
		path = "src/main.lua",
		side = "right",
		layer = "unstaged",
		context = context,
		context_hash = vim.fn.sha256(context),
		stale = true,
		start_line = 4,
		start_column = 2,
		end_line = 5,
		end_column = 3,
	}
	session = assert(store.edit(session, root_item.id, { anchor = updated_anchor }, deps))
	assert(vim.deep_equal(session.items[1].anchor, updated_anchor))
	session = assert(store.reply(session, root_item.id, { body = "Anchor inheritance" }, deps))
	assert(vim.deep_equal(session.items[2].anchor, updated_anchor))

	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded.items[1].anchor, updated_anchor))
	assert(vim.deep_equal(loaded.items[2].anchor, updated_anchor))
end)

test("item origins survive lifecycle changes and replies record their own engine", function()
	local main = { id = "main", version = "builtin-v1 / Neovim 0.12.0" }
	local difftastic = { id = "difftastic", version = "0.71.0" }
	local session = assert(store.add(fresh(), {
		type = "issue",
		body = "Recorded in the main engine",
		anchor = { path = "src/main.lua", side = "left", start_line = 4 },
		origin_engine = main,
	}, deps))
	local original_origin = vim.deepcopy(main)
	main.version = "changed caller value"
	local root_id = session.items[1].id
	session = assert(store.reply(session, root_id, { body = "Structural reply", origin_engine = difftastic }, deps))
	session = assert(store.reply(session, root_id, { body = "Unrecorded reply" }, deps))
	session = assert(store.edit(session, root_id, {
		body = "Edited body",
		anchor = { kind = "range", path = "src/main.lua", side = "right", start_line = 9 },
	}, deps))
	session = assert(store.set_type(session, root_id, "issue", deps))
	session = assert(store.set_resolution(session, root_id, "resolved", deps))
	session = assert(store.set_resolution(session, root_id, "open", deps))
	assert(vim.deep_equal(session.items[1].origin_engine, original_origin))
	assert(vim.deep_equal(session.items[2].origin_engine, difftastic))
	assert(session.items[3].origin_engine == nil, "reply invented or inherited an engine origin")
	local forbidden, edit_err = store.edit(session, root_id, { origin_engine = difftastic }, deps)
	assert(not forbidden and edit_err:find("unknown key", 1, true))
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded, saved))
	assert(loaded.scope.backend_id == "diffview" and loaded.id == session.id)
	assert(loaded.items[1].anchor.start_line == 9 and loaded.items[1].anchor.side == "right")
end)

test("v3 engine origins are strict and bounded without restricting future engine names", function()
	local session = add_root(fresh())
	local saved, path = assert(store.save(root, session, deps))
	local before = writes
	local invalid_origins = {
		vim.NIL,
		false,
		"main",
		{},
		{ id = "main" },
		{ version = "1" },
		{ id = "", version = "1" },
		{ id = "Main", version = "1" },
		{ id = "../main", version = "1" },
		{ id = "main\n", version = "1" },
		{ id = string.rep("a", 65), version = "1" },
		{ id = "main", version = "" },
		{ id = "main", version = string.rep("v", 129) },
		{ id = "main", version = "1\n2" },
		{ id = "main", version = "1\t2" },
		{ id = "main", version = "1" .. string.char(127) },
		{ id = "main", version = "1\0" },
		{ id = "main", version = "v\195\169" },
		{ id = "main", version = "1", preference = true },
	}
	for _, origin in ipairs(invalid_origins) do
		local added, add_err = store.add(session, {
			type = "issue",
			body = "Invalid origin",
			anchor = {},
			origin_engine = origin,
		}, deps)
		assert(not added and add_err:find("origin_engine", 1, true))
		local replied, reply_err = store.reply(session, session.items[1].id, {
			body = "Invalid reply origin",
			origin_engine = origin,
		}, deps)
		assert(not replied and reply_err:find("origin_engine", 1, true))
		local invalid = vim.deepcopy(saved)
		invalid.items[1].origin_engine = origin
		local persisted, persist_err = store.save(root, invalid, deps)
		assert(not persisted and persist_err:find("origin_engine", 1, true) and writes == before)
		assert(config_fs.write_binary_atomic(path, vim.json.encode(invalid) .. "\n"))
		local loaded, load_err = store.load(root, invalid.id, deps)
		assert(not loaded and load_err:find("origin_engine", 1, true))
	end
	local future = assert(store.add(session, {
		type = "issue",
		body = "Future engine",
		anchor = {},
		origin_engine = { id = "future_engine-" .. string.rep("a", 50), version = string.rep("v", 128) },
	}, deps))
	assert(#future.items[2].origin_engine.id == 64 and #future.items[2].origin_engine.version == 128)
end)

test("file-level anchors survive save and load without invented line metadata", function()
	local anchor = { kind = "file", path = "src/file.lua", side = "right", layer = "working", stale = false }
	local session = assert(store.add(fresh(), {
		type = "issue",
		body = "This applies to the whole file",
		anchor = anchor,
	}, deps))
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded.items[1].anchor, anchor))
	assert(loaded.items[1].anchor.start_line == nil and loaded.items[1].anchor.end_line == nil)
end)

test("saved v3 rationale comments load as objection! and save canonically", function()
	local session = add_root(fresh())
	local saved, path = assert(store.save(root, session, deps))
	local legacy = vim.deepcopy(saved)
	legacy.items[1].type = "rationale"
	local encoded = vim.json.encode(legacy) .. "\n"
	assert(config_fs.write_binary_atomic(path, encoded))
	assert(vim.uv.fs_chmod(path, 384))

	local loaded = assert(store.load(root, saved.id, deps))
	assert(loaded.items[1].type == "objection!")
	assert(config_fs.read_binary(path) == encoded, "read-only load rewrote v3 state")
	local updated = assert(store.save(root, loaded, deps))
	assert(updated.items[1].type == "objection!")
	local persisted = assert(vim.json.decode(assert(config_fs.read_binary(path))))
	assert(persisted.items[1].type == "objection!")
end)

test("retired and removed types survive load, edit, reply, and save without becoming selectable", function()
	local types = { "issue", "suggestion", "objection!", "question", "pedantic", "praise", "archived" }
	local session = fresh()
	for _ = 1, #types do
		session = add_root(session)
	end
	local saved, path = assert(store.save(root, session, deps))
	local archived = vim.deepcopy(saved)
	for index, item_type in ipairs(types) do
		archived.items[index].type = item_type
	end
	assert(config_fs.write_binary_atomic(path, vim.json.encode(archived) .. "\n"))
	assert(vim.uv.fs_chmod(path, 384))

	local loaded = assert(store.load(root, saved.id, deps))
	for index, item_type in ipairs(types) do
		assert(loaded.items[index].type == item_type)
	end
	local archived_id = loaded.items[#types].id
	local edited =
		assert(store.edit(loaded, archived_id, { body = "Updated archived finding", type = "archived" }, deps))
	assert(edited.items[#types].type == "archived" and edited.items[#types].body == "Updated archived finding")
	local changed, change_err = store.edit(edited, archived_id, { type = "suggestion" }, deps)
	assert(not changed and change_err:find("active configured", 1, true))
	local inactive_reply, reply_err = store.reply(edited, archived_id, { type = "archived", body = "Old type" }, deps)
	assert(not inactive_reply and reply_err:find("active configured", 1, true))
	local replied = assert(store.reply(edited, archived_id, { body = "New answer" }, deps))
	assert(replied.items[#replied.items].type == "issue")
	local persisted = assert(store.save(root, replied, deps))
	assert(persisted.items[#types].type == "archived")
	assert(assert(store.load(root, saved.id, deps)).items[#types].type == "archived")
end)

test("configured additional types are selectable and remain readable after removal", function()
	comment_types.configure({
		{
			id = "note",
			icon = "N",
			highlight = "NvimReviewCommentNote",
			default_link = "DiagnosticSignInfo",
			rail_rank = 2,
		},
	})
	local session = assert(store.add(fresh(), { type = "note", body = "Custom finding", anchor = {} }, deps))
	local saved = assert(store.save(root, session, deps))
	comment_types.configure({})
	local loaded = assert(store.load(root, saved.id, deps))
	assert(loaded.items[1].type == "note" and not comment_types.contains("note"))
	local edited = assert(store.edit(loaded, loaded.items[1].id, { body = "Still readable" }, deps))
	assert(assert(store.save(root, edited, deps)).items[1].type == "note")
	local added, add_err = store.add(edited, { type = "note", body = "No new custom finding", anchor = {} }, deps)
	assert(not added and add_err:find("active configured", 1, true))
end)

test("stored type identifiers cannot inject UI or Markdown lines", function()
	local saved, path = assert(store.save(root, add_root(fresh()), deps))
	for _, item_type in ipairs({ "bad\n# heading", "../../outside", string.rep("x", 128), "" }) do
		local unsafe = vim.deepcopy(saved)
		unsafe.items[1].type = item_type
		assert(config_fs.write_binary_atomic(path, vim.json.encode(unsafe) .. "\n"))
		assert(vim.uv.fs_chmod(path, 384))
		local loaded, err = store.load(root, saved.id, deps)
		assert(not loaded and err:find("valid review type identifier", 1, true), tostring(err))
	end
end)

test("active types, normalized anchors, replies, and resolution lifecycle are strict", function()
	local session = add_root(fresh())
	assert(#session.items == 1 and session.items[1].anchor.path == "src/main.lua")
	local invalid, invalid_err = store.add(session, { type = "note", body = "no", anchor = {} }, deps)
	assert(not invalid and invalid_err:find("active configured", 1, true))
	local retired, retired_err = store.add(session, { type = "suggestion", body = "old", anchor = {} }, deps)
	assert(not retired and retired_err:find("active configured", 1, true))
	local traversal, traversal_err = store.add(session, {
		type = "issue",
		body = "unsafe",
		anchor = { path = "../outside.lua" },
	}, deps)
	assert(not traversal and traversal_err:find("traversal", 1, true))

	local root_item = session.items[1]
	session = assert(store.reply(session, root_item.id, { body = "A direct answer" }, deps))
	local reply = session.items[#session.items]
	assert(store.item_status(reply) == "reply" and reply.reply_to == root_item.id)
	session = assert(store.set_status(session, root_item.id, "resolved", deps))
	assert(session.items[1].resolution == "resolved")
	session = assert(store.edit(session, root_item.id, { body = "Updated finding" }, deps))
	assert(session.items[1].resolution == "resolved" and session.items[1].body == "Updated finding")
	session = assert(store.set_status(session, root_item.id, "draft", deps))
	assert(session.items[1].resolution == "open")
	session = assert(store.edit(session, reply.id, { body = "changed" }, deps))
	assert(session.items[#session.items].body == "changed")
	local deleted, delete_err = store.delete(session, root_item.id, deps)
	assert(not deleted and delete_err:find("has replies", 1, true))
end)

test("type changes from retired types preserve resolved lifecycle metadata", function()
	local session = add_root(fresh())
	session.items[1].type = "objection!"
	local id = session.items[1].id
	session = assert(store.set_status(session, id, "resolved", deps))
	local before = vim.deepcopy(session.items[1])
	session = assert(store.set_type(session, id, "issue", deps))
	local changed = session.items[1]
	local expected = vim.deepcopy(before)
	expected.type = "issue"
	expected.updated_at = changed.updated_at
	assert(vim.deep_equal(changed, expected), "type mutation changed review lifecycle metadata")
	assert(changed.resolution == "resolved" and changed.updated_at ~= before.updated_at)

	local invalid, invalid_err = store.set_type(session, id, "note", deps)
	assert(not invalid and invalid_err:find("active configured", 1, true))
	local retired, retired_err = store.set_type(session, id, "question", deps)
	assert(not retired and retired_err:find("active configured", 1, true))
	assert(session.items[1].type == "issue" and session.items[1].resolution == "resolved")
end)

test("anchor metadata is strictly typed and bounded", function()
	local invalid_utf8 = string.char(0xF0, 0x9F, 0x99)
	for _, anchor in ipairs({
		{ layer = string.rep("x", 129) },
		{ context = string.rep("x", 16 * 1024 + 1) },
		{ context = invalid_utf8, context_hash = vim.fn.sha256(invalid_utf8) },
		{ context = "captured without a digest" },
		{ context_hash = vim.fn.sha256("digest without context") },
		{ context = "captured", context_hash = vim.fn.sha256("different") },
		{ context_hash = string.rep("A", 64) },
		{ stale = "yes" },
	}) do
		local added, err = store.add(fresh(), { type = "issue", body = "invalid anchor", anchor = anchor }, deps)
		assert(not added and err, "invalid anchor metadata was accepted")
	end
end)

test("UTF-8 context bounds retain only complete code points", function()
	local emoji = "🙂"
	local context = "x" .. string.rep(emoji, 5000)
	local truncated = assert(store.truncate_utf8(context, store.max_anchor_context))
	assert(truncated == "x" .. string.rep(emoji, 4095))
	assert(#truncated == 16381 and #truncated <= store.max_anchor_context)

	local malformed, malformed_err = store.truncate_utf8(string.char(0xF0, 0x9F, 0x99), store.max_anchor_context)
	assert(malformed == nil and malformed_err:find("not valid UTF%-8"))

	local session = assert(store.add(fresh(), {
		type = "issue",
		body = "Unicode context",
		anchor = {
			kind = "range",
			path = "src/unicode.lua",
			side = "right",
			layer = "working",
			start_line = 1,
			end_line = 1,
			context = truncated,
			context_hash = vim.fn.sha256(truncated),
			stale = false,
		},
	}, deps))
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(loaded.items[1].anchor.context == truncated)
end)

test("atomic save uses exact versioned path and owner-only permissions", function()
	local session = add_root(fresh())
	session.stale = true
	local saved, path = assert(store.save(root, session, deps))
	assert(writes > 0 and saved.stale and saved.revision == 1)
	local expected = vim.fs.joinpath(state, "nvim-config", "reviews", "v3", vim.fn.sha256(root), session.id .. ".json")
	assert(path == expected)
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == 384, "session file is not 0600")
	for _, directory in ipairs({
		state,
		state .. "/nvim-config",
		state .. "/nvim-config/reviews",
		state .. "/nvim-config/reviews/v3",
		state .. "/nvim-config/reviews/v3/" .. vim.fn.sha256(root),
	}) do
		assert(assert(vim.uv.fs_lstat(directory)).mode % 512 == 448, directory .. " is not 0700")
	end
	local loaded = assert(store.load(root, session.id, deps))
	assert(loaded.stale and loaded.items[1].body == session.items[1].body)
	local listed = assert(store.list(root, deps))
	assert(#listed >= 1 and listed[1].id == session.id)
end)

test("v1 loads without writes and materializes safely only on explicit save", function()
	local source = add_root(fresh())
	source = assert(store.reply(source, source.items[1].id, { body = "Legacy reply" }, deps))
	source = add_root(source)
	source = add_root(source)
	source = add_root(source)
	source.bridge = {
		backend = "tuicr",
		round = "123e4567-e89b-12d3-a456-426614174000",
		trusted_scope_id = source.id,
		linked_at = "2026-08-25T10:00:00Z",
	}
	source.revision = 7
	local legacy = legacy_value(source, { "draft", "reply", "resolved", "exported", "exported" }, {
		[4] = "clipboard:old-copy",
		[5] = "tuicr:remote-5",
	})
	legacy.items[3].type = "rationale"
	legacy.items[4].type = "question"
	legacy.items[5].type = "praise"
	local legacy_path, encoded = write_legacy(legacy)

	local migrated, path = assert(store.load(root, legacy.id, deps))
	assert(migrated.version == 3 and migrated.scope.version == 1 and migrated.revision == 7)
	assert(migrated.id == legacy.id and migrated.repo_hash == legacy.repo_hash)
	assert(migrated.created_at == legacy.created_at and migrated.updated_at == legacy.updated_at)
	assert(vim.deep_equal(migrated.bridge, legacy.bridge) and migrated.next_sequence == legacy.next_sequence)
	assert(migrated.items[1].resolution == "open" and migrated.items[2].resolution == "open")
	assert(migrated.items[2].reply_to == legacy.items[2].reply_to)
	assert(migrated.items[3].resolution == "resolved")
	assert(migrated.items[3].type == "objection!")
	assert(migrated.items[4].resolution == "legacy_unknown" and #migrated.items[4].deliveries == 0)
	assert(migrated.items[5].resolution == "legacy_unknown")
	assert(migrated.items[5].deliveries[1].receipt == "remote-5")
	for index, item in ipairs(migrated.items) do
		assert(item.id == legacy.items[index].id and item.sequence == legacy.items[index].sequence)
		assert(item.created_at == legacy.items[index].created_at and item.updated_at == legacy.items[index].updated_at)
		assert(item.status == nil and item.anchor.kind ~= nil and item.origin_engine == nil)
		local original_anchor = vim.deepcopy(legacy.items[index].anchor)
		original_anchor.kind = item.anchor.kind
		assert(vim.deep_equal(item.anchor, original_anchor))
	end
	assert(path == legacy_path)
	local target = vim.fs.joinpath(state, "nvim-config", "reviews", "v3", vim.fn.sha256(root), legacy.id .. ".json")
	local backup = legacy_path:sub(1, -6) .. ".v1-backup"
	assert(vim.uv.fs_lstat(target) == nil and vim.uv.fs_lstat(backup) == nil, "read-only load rewrote v1 state")
	local again = assert(store.load(root, legacy.id, deps))
	assert(vim.deep_equal(again, migrated), "repeat load changed the in-memory v1 projection")
	local listed = assert(store.list(root, deps))
	assert(#listed == 1 and listed[1].id == legacy.id, "v1 session was duplicated during listing")
	assert(vim.uv.fs_lstat(target) == nil and vim.uv.fs_lstat(backup) == nil, "listing rewrote v1 state")

	local editable =
		assert(store.edit(migrated, migrated.items[4].id, { body = "Edited after clipboard migration" }, deps))
	assert(editable.items[4].body == "Edited after clipboard migration")
	local edited_legacy = assert(store.edit(migrated, migrated.items[5].id, { body = "Native edit" }, deps))
	assert(edited_legacy.items[5].deliveries[1].receipt == "remote-5")
	local reopened = assert(store.set_resolution(migrated, migrated.items[4].id, "open", deps))
	assert(store.item_status(reopened.items[4]) == "draft")

	local saved, saved_path = assert(store.save(root, migrated, deps))
	assert(saved_path == target and saved.revision == migrated.revision + 1)
	assert(saved.items[3].type == "objection!")
	assert(not backup:match("%.json$") and config_fs.read_binary(backup) == encoded)
	assert(assert(vim.uv.fs_lstat(backup)).mode % 512 == 384)
	assert(assert(vim.uv.fs_lstat(saved_path)).mode % 512 == 384)
	assert(vim.deep_equal(assert(store.load(root, legacy.id, deps)), saved))
end)

test("v2 sessions migrate without inventing origins and preserve exact inert metadata", function()
	local source = add_root(fresh())
	source = assert(store.reply(source, source.items[1].id, { body = "Legacy v2 reply" }, deps))
	source = assert(store.set_resolution(source, source.items[1].id, "resolved", deps))
	source.items[2].resolution = "legacy_unknown"
	source.items[2].deliveries = {
		{ backend = "tuicr", receipt = "v2-reply", delivered_at = "2026-08-25T10:00:01Z" },
	}
	source.bridge = {
		backend = "tuicr",
		round = "123e4567-e89b-12d3-a456-426614174000",
		trusted_scope_id = source.id,
		linked_at = "2026-08-25T10:00:00Z",
	}
	source.version = 2
	source.revision = 4
	local legacy_path, encoded = write_legacy(source)
	local older = legacy_value(source, { "resolved", "exported" }, { [2] = "tuicr:older-reply" })
	older.items[1].body = "Superseded v1 body"
	write_legacy(older)
	local before = writes
	local loaded, loaded_path = assert(store.load(root, source.id, deps))
	local expected = vim.deepcopy(source)
	expected.version = 3
	assert(vim.deep_equal(loaded, expected), "v2 projection changed identifiers, anchors, replies, or inert metadata")
	assert(loaded_path == legacy_path and writes == before)
	for _, item in ipairs(loaded.items) do
		assert(item.origin_engine == nil, "v2 migration invented an origin")
	end
	local listed = assert(store.list(root, deps))
	assert(#listed == 1 and vim.deep_equal(listed[1], loaded), "v2 did not take precedence over v1")
	local target = vim.fs.joinpath(state, "nvim-config", "reviews", "v3", vim.fn.sha256(root), source.id .. ".json")
	local backup = legacy_path:sub(1, -6) .. ".v2-backup"
	assert(not vim.uv.fs_lstat(target) and not vim.uv.fs_lstat(backup) and writes == before)
	local writer_a = assert(store.add(loaded, {
		type = "issue",
		body = "New v3 comment",
		anchor = { path = "src/main.lua", side = "right", start_line = 8 },
		origin_engine = { id = "difftastic", version = "0.71.0" },
	}, deps))
	local writer_b = assert(store.edit(loaded, loaded.items[1].id, { body = "Stale writer" }, deps))
	local saved, saved_path = assert(store.save(root, writer_a, deps))
	assert(saved_path == target and saved.revision == 5)
	assert(config_fs.read_binary(legacy_path) == encoded and config_fs.read_binary(backup) == encoded)
	assert(assert(vim.uv.fs_lstat(backup)).mode % 512 == 384)
	local conflicted, conflict_err = store.save(root, writer_b, deps)
	assert(not conflicted and conflict_err:find("another Neovim", 1, true))
	assert(vim.deep_equal(assert(store.load(root, source.id, deps)), saved))
	listed = assert(store.list(root, deps))
	assert(#listed == 1 and vim.deep_equal(listed[1], saved), "v3 duplicated older sessions")
end)

test("older codecs reject injected origin fields instead of silently discarding them", function()
	for _, version in ipairs({ 1, 2 }) do
		local source = add_root(assert(store.new(root, working_scope(vim.fn.sha256("strict-v" .. version)), deps)))
		if version == 1 then
			source = legacy_value(source, { "draft" })
		else
			source.version = 2
		end
		source.items[1].origin_engine = { id = "main", version = "forged" }
		write_legacy(source)
		local loaded, load_err = store.load(root, source.id, deps)
		assert(not loaded and load_err:find("unknown key", 1, true))
	end
end)

test("failed v2 reload rolls back only created v3 files and preserves originals", function()
	local source = add_root(fresh())
	source.version = 2
	local legacy_path, encoded = write_legacy(source)
	local backup = legacy_path:sub(1, -6) .. ".v2-backup"
	local target = vim.fs.joinpath(state, "nvim-config", "reviews", "v3", vim.fn.sha256(root), source.id .. ".json")
	local failing = vim.tbl_extend("force", deps, {
		fs = {
			read_binary = function(path)
				if path == target then
					return "{}"
				end
				return config_fs.read_binary(path)
			end,
			write_binary_atomic = config_fs.write_binary_atomic,
		},
	})
	local loaded = assert(store.load(root, source.id, failing))
	local saved, save_err = store.save(root, loaded, failing)
	assert(not saved and save_err:find("reload validation", 1, true))
	assert(not vim.uv.fs_lstat(target) and not vim.uv.fs_lstat(backup))
	assert(config_fs.read_binary(legacy_path) == encoded)
	assert(not vim.uv.fs_lstat(legacy_path .. ".lock") and not vim.uv.fs_lstat(target .. ".lock"))

	assert(config_fs.write_binary_atomic(backup, "mismatching backup"))
	saved, save_err = store.save(root, loaded, deps)
	assert(not saved and save_err:find("backup does not match", 1, true))
	assert(not vim.uv.fs_lstat(target) and config_fs.read_binary(backup) == "mismatching backup")
	assert(config_fs.read_binary(legacy_path) == encoded)
end)

test("failed v1 migration rolls back v3 and its new backup without exposing bodies", function()
	local source = add_root(fresh())
	source.items[1].body = "secret migration body"
	local legacy = legacy_value(source, { "draft" })
	local legacy_path = write_legacy(legacy)
	local target = vim.fs.joinpath(state, "nvim-config", "reviews", "v3", vim.fn.sha256(root), legacy.id .. ".json")
	local failing = vim.tbl_extend("force", deps, {
		fs = {
			read_binary = config_fs.read_binary,
			write_binary_atomic = function(path, data)
				if path == target then
					return nil, "injected atomic failure"
				end
				return config_fs.write_binary_atomic(path, data)
			end,
		},
	})
	local migrated = assert(store.load(root, legacy.id, failing))
	assert(vim.uv.fs_lstat(target) == nil, "read-only load unexpectedly materialized v3")
	local saved, migration_err = store.save(root, migrated, failing)
	assert(not saved and migration_err:find("injected atomic failure", 1, true))
	assert(not migration_err:find(source.items[1].body, 1, true))
	assert(vim.uv.fs_lstat(target) == nil)
	assert(vim.uv.fs_lstat(legacy_path:sub(1, -6) .. ".v1-backup") == nil)
	assert(vim.uv.fs_lstat(legacy_path).type == "file")
end)

test("complete recovery Markdown is owner-only and verified before discard", function()
	local session = add_root(fresh())
	local markdown = "# Recovery\n\nComplete review body\n"
	local receipt = assert(store.save_recovery(root, session, markdown, deps))
	assert(assert(vim.uv.fs_lstat(receipt.path)).mode % 512 == 384, "recovery file is not 0600")
	assert(config_fs.read_binary(receipt.path) == markdown)
	assert(store.verify_recovery(root, receipt, deps))
	assert(vim.uv.fs_chmod(receipt.path, 420)) -- 0644
	local private, private_err = store.verify_recovery(root, receipt, deps)
	assert(not private and private_err:find("unsafe", 1, true))
	assert(vim.uv.fs_chmod(receipt.path, 384)) -- 0600
	assert(config_fs.write_binary_atomic(receipt.path, markdown .. "changed"))
	local verified, verify_err = store.verify_recovery(root, receipt, deps)
	assert(not verified and verify_err:find("changed", 1, true))
end)

test("near-limit v3 sessions produce complete owner-only verified recovery", function()
	local session = fresh()
	local context_marker = "PRIVATE_SOURCE_CONTEXT"
	local context = context_marker .. string.rep("\n", store.max_anchor_context - #context_marker)
	local item_count = 30
	for index = 1, item_count do
		session = assert(store.add(session, {
			type = "issue",
			body = ("near-limit item %02d"):format(index),
			anchor = {
				kind = "range",
				path = "src/main.lua",
				side = "right",
				layer = "working",
				context = context,
				context_hash = vim.fn.sha256(context),
				stale = false,
				start_line = index,
				end_line = index,
			},
		}, deps))
	end

	local saved, path = assert(store.save(root, session, deps))
	local state_bytes = assert(vim.uv.fs_lstat(path)).size
	assert(state_bytes > store.max_bytes * 0.95 and state_bytes <= store.max_bytes, "fixture is not near the cap")
	local markdown, ids = assert(exporter.render_recovery(saved))
	local _, heading_count = markdown:gsub("## ISSUE", "")
	assert(#ids == item_count and heading_count == item_count, "recovery omitted review items")
	for index = 1, item_count do
		assert(markdown:find(("near-limit item %02d"):format(index), 1, true), "recovery omitted an item body")
	end
	assert(not markdown:find(context_marker, 1, true), "recovery leaked private anchor context")
	assert(not markdown:find("Context (`", 1, true), "recovery retained the source-context section")
	assert(#markdown <= store.max_recovery_bytes, "valid recovery exceeded its derived bound")

	local receipt = assert(store.save_recovery(root, saved, markdown, deps))
	assert(assert(vim.uv.fs_lstat(receipt.path)).mode % 512 == 384, "near-limit recovery is not 0600")
	assert(config_fs.read_binary(receipt.path) == markdown, "near-limit recovery was truncated")
	assert(store.verify_recovery(root, receipt, deps))
end)

test("cross-process saves reject stale writers without losing comments", function()
	local initial = assert(store.save(root, fresh(), deps))
	local writer_a = assert(store.load(root, initial.id, deps))
	local writer_b = assert(store.load(root, initial.id, deps))
	writer_a = assert(store.add(writer_a, { type = "issue", body = "writer A", anchor = {} }, deps))
	writer_b = assert(store.add(writer_b, { type = "issue", body = "writer B", anchor = {} }, deps))
	assert(writer_a.items[1].id ~= writer_b.items[1].id, "concurrent drafts reused a review item ID")
	local saved_a = assert(store.save(root, writer_a, deps))
	local saved_b, conflict_err = store.save(root, writer_b, deps)
	assert(not saved_b and conflict_err:find("another Neovim", 1, true))
	local final = assert(store.load(root, initial.id, deps))
	assert(final.revision == saved_a.revision)
	assert(#final.items == 1 and final.items[1].body == "writer A")
end)

test("a crashed lock owner is recovered without bypassing the revision check", function()
	local initial, path = assert(store.save(root, fresh(), deps))
	local changed = assert(store.add(initial, { type = "issue", body = "after crash", anchor = {} }, deps))
	local lock_path = path .. ".lock"
	assert(vim.fn.mkdir(lock_path, "p", 448) == 1)
	local owner = {
		created_at = 1,
		pid = 99999999,
		token = vim.fn.sha256("dead lock owner"),
	}
	assert(config_fs.write_binary_atomic(vim.fs.joinpath(lock_path, "owner.json"), vim.json.encode(owner) .. "\n"))
	local recovered = assert(store.save(
		root,
		changed,
		vim.tbl_extend("force", deps, {
			process_alive = function()
				return false
			end,
		})
	))
	assert(recovered.revision == 2)
	assert(vim.uv.fs_lstat(lock_path) == nil)
end)

test("unknown JSON fields and symlink state files fail closed", function()
	local session, path = store.save(root, add_root(fresh()), deps)
	assert(session and path)
	local value = vim.json.decode(assert(config_fs.read_binary(path)))
	value.execute = "danger"
	assert(config_fs.write_binary_atomic(path, vim.json.encode(value) .. "\n"))
	local loaded, load_err = store.load(root, session.id, deps)
	assert(not loaded and load_err:find("unknown key", 1, true))

	assert(vim.fn.delete(path) == 0)
	local outside = vim.fn.tempname()
	assert(vim.fn.writefile({ "{}" }, outside) == 0)
	assert(vim.uv.fs_symlink(outside, path))
	local linked, linked_err = store.load(root, session.id, deps)
	assert(not linked and linked_err:find("symlink", 1, true))
	local saved, save_err = store.save(root, session, deps)
	assert(not saved and save_err:find("symlink", 1, true))
	vim.fn.delete(outside)
	vim.fn.delete(path)
end)

test("item and encoded byte limits reject oversized state", function()
	local too_many = fresh()
	too_many.items = {}
	for index = 1, store.max_items + 1 do
		too_many.items[index] = {}
	end
	local saved, count_err = store.save(root, too_many, deps)
	assert(not saved and count_err:find("maximum is 2000", 1, true))

	local large = fresh()
	for _ = 1, 17 do
		large = assert(store.add(large, { type = "issue", body = string.rep("x", 64 * 1024), anchor = {} }, deps))
	end
	local written, size_err = store.save(root, large, deps)
	assert(not written and size_err:find("maximum", 1, true), tostring(size_err))
end)

test("strict validation rejects injected fields before any write", function()
	local before = writes
	local session = fresh()
	session.scope.callback = "danger"
	local saved, err = store.save(root, session, deps)
	assert(not saved and err:find("unknown key", 1, true) and writes == before)
end)

vim.fn.delete(state, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_store_spec: %d tests passed", count))
vim.cmd("quitall!")
