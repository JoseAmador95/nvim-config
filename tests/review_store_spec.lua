vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local state
local function test(name, callback)
	count = count + 1
	if state then
		vim.fn.delete(state, "rf")
		assert(vim.fn.mkdir(state, "p") == 1)
	end
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local config_fs = require("config.fs")
local scope_module = require("config.review_scope")
local store = require("config.review_store")
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

test("session and scope identities are deterministic and include the working fingerprint", function()
	local first = fresh()
	local second = fresh()
	assert(first.id == second.id and first.repo_hash == second.repo_hash)
	local changed_scope = working_scope(vim.fn.sha256("changed"))
	assert(changed_scope.id ~= first.id)
	local changed = assert(store.new(root, changed_scope, deps))
	assert(changed.id == changed_scope.id)
end)

test("TUICR bridge is strictly linked to the current session and survives JSON roundtrip", function()
	local round = "123e4567-e89b-12d3-a456-426614174000"
	local session = assert(store.link_tuicr(fresh(), round, deps))
	assert(vim.deep_equal(session.bridge, {
		backend = "tuicr",
		round = round,
		trusted_scope_id = session.id,
		linked_at = session.bridge.linked_at,
	}))
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded.bridge, saved.bridge))

	local invalid_round, round_err = store.link_tuicr(fresh(), "not-a-uuid", deps)
	assert(not invalid_round and round_err:find("canonical lowercase UUID", 1, true))

	loaded.bridge.backend = "github"
	local invalid_backend, backend_err = store.save(root, loaded, deps)
	assert(not invalid_backend and backend_err:find("backend must be tuicr", 1, true))
end)

test("TUICR linking rejects late or conflicting publication backends", function()
	local round = "123e4567-e89b-12d3-a456-426614174000"
	local session = add_root(fresh())
	session = assert(store.mark_exported(session, session.items[1].id, "clipboard:first", deps))
	local linked, late_err = store.link_tuicr(session, round, deps)
	assert(not linked and late_err:find("before exporting", 1, true))

	session = add_root(fresh())
	session = assert(store.link_tuicr(session, round, deps))
	local other = "22222222-2222-2222-2222-222222222222"
	linked, late_err = store.link_tuicr(session, other, deps)
	assert(not linked and late_err:find("different TUICR round", 1, true))
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

test("file-level anchors survive save and load without invented line metadata", function()
	local anchor = { path = "src/file.lua", side = "right", layer = "working", stale = false }
	local session = assert(store.add(fresh(), {
		type = "rationale",
		body = "This applies to the whole file",
		anchor = anchor,
	}, deps))
	local saved = assert(store.save(root, session, deps))
	local loaded = assert(store.load(root, saved.id, deps))
	assert(vim.deep_equal(loaded.items[1].anchor, anchor))
	assert(loaded.items[1].anchor.start_line == nil and loaded.items[1].anchor.end_line == nil)
end)

test("six types, normalized anchors, replies, resolution, and export lifecycle are strict", function()
	local session = fresh()
	for _, item_type in ipairs({ "issue", "suggestion", "rationale", "question", "pedantic", "praise" }) do
		session = add_root(session, item_type)
	end
	assert(#session.items == 6 and session.items[1].anchor.path == "src/main.lua")
	local invalid, invalid_err = store.add(session, { type = "note", body = "no", anchor = {} }, deps)
	assert(not invalid and invalid_err:find("six supported", 1, true))
	local traversal, traversal_err = store.add(session, {
		type = "issue",
		body = "unsafe",
		anchor = { path = "../outside.lua" },
	}, deps)
	assert(not traversal and traversal_err:find("traversal", 1, true))

	local root_item = session.items[1]
	session = assert(store.reply(session, root_item.id, { body = "A direct answer" }, deps))
	local reply = session.items[#session.items]
	assert(reply.status == "reply" and reply.reply_to == root_item.id)
	session = assert(store.set_status(session, root_item.id, "resolved", deps))
	assert(session.items[1].status == "resolved")
	session = assert(store.edit(session, root_item.id, { body = "Updated finding" }, deps))
	assert(session.items[1].status == "draft" and session.items[1].body == "Updated finding")
	session = assert(store.mark_exported(session, reply.id, "tuicr-comment-7", deps))
	assert(session.items[#session.items].status == "exported")
	local edited, edit_err = store.edit(session, reply.id, { body = "changed" }, deps)
	assert(not edited and edit_err:find("immutable", 1, true))
	local deleted, delete_err = store.delete(session, root_item.id, deps)
	assert(not deleted and delete_err:find("has replies", 1, true))
end)

test("type changes preserve resolved lifecycle metadata", function()
	local session = add_root(fresh())
	local id = session.items[1].id
	session = assert(store.set_status(session, id, "resolved", deps))
	local before = vim.deepcopy(session.items[1])
	session = assert(store.set_type(session, id, "rationale", deps))
	local changed = session.items[1]
	local expected = vim.deepcopy(before)
	expected.type = "rationale"
	expected.updated_at = changed.updated_at
	assert(vim.deep_equal(changed, expected), "type mutation changed review lifecycle metadata")
	assert(changed.status == "resolved" and changed.updated_at ~= before.updated_at)

	local invalid, invalid_err = store.set_type(session, id, "note", deps)
	assert(not invalid and invalid_err:find("six supported", 1, true))
	session = assert(store.mark_exported(session, id, "clipboard:resolved", deps))
	local exported, exported_err = store.set_type(session, id, "question", deps)
	assert(not exported and exported_err:find("immutable", 1, true))
end)

test("exported findings remain replyable without unlocking the parent", function()
	local session = add_root(fresh())
	local parent = session.items[1]
	session = assert(store.mark_exported(session, parent.id, "tuicr-parent", deps))
	session = assert(store.reply(session, parent.id, { body = "Follow-up after export" }, deps))
	assert(session.items[1].status == "exported")
	assert(session.items[2].status == "reply" and session.items[2].reply_to == parent.id)
end)

test("anchor metadata is strictly typed and bounded", function()
	for _, anchor in ipairs({
		{ layer = string.rep("x", 129) },
		{ context = string.rep("x", 16 * 1024 + 1) },
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

test("atomic save uses exact versioned path and owner-only permissions", function()
	local session = add_root(fresh())
	session.stale = true
	local saved, path = assert(store.save(root, session, deps))
	assert(writes > 0 and saved.stale and saved.revision == 1)
	local expected = vim.fs.joinpath(state, "nvim-config", "reviews", "v1", vim.fn.sha256(root), session.id .. ".json")
	assert(path == expected)
	assert(assert(vim.uv.fs_lstat(path)).mode % 512 == 384, "session file is not 0600")
	for _, directory in ipairs({
		state,
		state .. "/nvim-config",
		state .. "/nvim-config/reviews",
		state .. "/nvim-config/reviews/v1",
		state .. "/nvim-config/reviews/v1/" .. vim.fn.sha256(root),
	}) do
		assert(assert(vim.uv.fs_lstat(directory)).mode % 512 == 448, directory .. " is not 0700")
	end
	local loaded = assert(store.load(root, session.id, deps))
	assert(loaded.stale and loaded.items[1].body == session.items[1].body)
	local listed = assert(store.list(root, deps))
	assert(#listed >= 1 and listed[1].id == session.id)
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

test("cross-process saves reject stale writers without losing comments", function()
	local initial = assert(store.save(root, fresh(), deps))
	local writer_a = assert(store.load(root, initial.id, deps))
	local writer_b = assert(store.load(root, initial.id, deps))
	writer_a = assert(store.add(writer_a, { type = "issue", body = "writer A", anchor = {} }, deps))
	writer_b = assert(store.add(writer_b, { type = "issue", body = "writer B", anchor = {} }, deps))
	assert(writer_a.items[1].id ~= writer_b.items[1].id, "concurrent drafts reused a TUICR delivery key")
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
