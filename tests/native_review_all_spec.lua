vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
require("config.local_plugins").setup()

local review = require("config.native_review")
local fs = require("config.fs")
local equal = require("tests.helpers").equal
local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })
local directory, root, state, base
local original_state = vim.env.XDG_STATE_HOME
local original_select, original_input = vim.ui.select, vim.ui.input
local original_open_async = review.controller.open_async

local function git(...)
	local result = vim.system({ "git", "-C", root, ... }, { text = false }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end

local function write(path, text)
	local file = assert(io.open(root .. "/" .. path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

local function resolve(base_ref, options)
	local scope, err = review.scope.resolve(root, { kind = "all", base = base_ref, backend_id = "native" }, options)
	assert(scope, vim.inspect(err))
	return scope
end

local function build(base_ref, options)
	local scope = resolve(base_ref)
	local model, err = review.changes.build(root, scope, options)
	assert(model, vim.inspect(err))
	return model, scope
end

hooks.pre_case = function()
	directory = vim.fn.tempname()
	assert(vim.fn.mkdir(directory .. "/repo", "p") == 1)
	directory = assert(vim.uv.fs_realpath(directory))
	root, state = directory .. "/repo", directory .. "/state"
	vim.env.XDG_STATE_HOME = state
	git("init", "-q", "-b", "main")
	git("config", "user.email", "review@example.invalid")
	git("config", "user.name", "Review Fixture")
	write("a.txt", "one\r\nbase\r\nthree\r\n")
	write("gone.txt", "remove me\n")
	write(".gitignore", "ignored.txt\n")
	git("add", ".")
	git("commit", "-qm", "base")
	base = git("rev-parse", "HEAD")
	git("switch", "-qc", "topic")
end

hooks.post_case = function()
	vim.ui.select, vim.ui.input = original_select, original_input
	review.controller.open_async = original_open_async
	if review.controller.status().active then
		review.controller.close(true)
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
	vim.env.XDG_STATE_HOME = original_state
	vim.fn.delete(directory, "rf")
end

T["all combines committed, staged, unstaged and untracked content without changing Git"] = function()
	write("a.txt", "one\r\ncommitted\r\nthree\r\n")
	write("committed.txt", "committed only\n")
	git("add", ".")
	git("commit", "-qm", "change")
	local head = git("rev-parse", "HEAD")
	write("a.txt", "one\r\nstaged\r\nthree\r\n")
	write("staged.txt", "staged only\n")
	git("add", ".")
	write("a.txt", "one\r\nfinal\r\nthree")
	write("new file\tname.txt", "untracked\n")
	write("ignored.txt", "ignored\n")
	assert(vim.uv.fs_unlink(root .. "/gone.txt"))
	local status = git("status", "--porcelain=v1", "-z")
	local index = assert(fs.read_binary(root .. "/.git/index"))
	local objects = git("count-objects", "-v")
	local model = build(base)
	equal(5, #model.entries)
	local entry = assert(review.changes.find(model, "a.txt"))
	equal("one\r\nbase\r\nthree\r\n", entry.old_text)
	equal("one\r\nfinal\r\nthree", entry.new_text)
	equal("all", entry.layer)
	assert(#entry.hunks > 0)
	equal("staged only\n", review.changes.find(model, "staged.txt").new_text)
	equal("untracked\n", review.changes.find(model, "new file\tname.txt").new_text)
	assert(review.changes.find(model, "gone.txt").deleted)
	equal(head, model.commits[1].oid)
	equal(nil, model.new_oid)
	equal(status, git("status", "--porcelain=v1", "-z"))
	equal(index, fs.read_binary(root .. "/.git/index"))
	equal(objects, git("count-objects", "-v"))
	equal(head, git("rev-parse", "HEAD"))
end

T["changes cancelled across layers disappear but mode changes remain"] = function()
	write("a.txt", "committed\n")
	git("add", "a.txt")
	git("commit", "-qm", "change")
	write("a.txt", "staged\n")
	write("temporary.txt", "added then removed\n")
	git("add", ".")
	write("a.txt", "one\r\nbase\r\nthree\r\n")
	assert(vim.uv.fs_unlink(root .. "/temporary.txt"))
	equal(0, #build(base).entries)
	git("config", "core.filemode", "true")
	assert(vim.uv.fs_chmod(root .. "/a.txt", 493))
	local model = build(base)
	equal(1, #model.entries)
	equal("100755", model.entries[1].new_mode)
	equal(model.entries[1].old_text, model.entries[1].new_text)
end

T["untracked replacements of index deletions compare once against their base"] = function()
	git("rm", "--cached", "a.txt")
	equal(0, #build(base).entries)
	write("a.txt", "replacement\n")
	local model = build(base)
	equal(1, #model.entries)
	equal("M", model.entries[1].status)
	equal("one\r\nbase\r\nthree\r\n", model.entries[1].old_text)
	equal("replacement\n", model.entries[1].new_text)
end

T["renames survive unless their original path reappears as untracked"] = function()
	git("mv", "a.txt", "renamed.txt")
	local model = build(base)
	equal(1, #model.entries)
	assert(model.entries[1].renamed and model.entries[1].old_path == "a.txt")
	write("a.txt", "one\r\nbase\r\nthree\r\n")
	model = build(base)
	equal(1, #model.entries)
	assert(model.entries[1].added and model.entries[1].new_path == "renamed.txt")
	write("a.txt", "new original\n")
	model = build(base)
	equal(2, #model.entries)
	equal("M", review.changes.find(model, "a.txt").status)
	equal("A", review.changes.find(model, "renamed.txt").status)
end

T["the default uses the branch merge base while explicit refs are exact"] = function()
	write("a.txt", "topic\n")
	git("add", "a.txt")
	git("commit", "-qm", "topic")
	local head = git("rev-parse", "HEAD")
	git("switch", "-q", "main")
	write("base-only.txt", "main advanced\n")
	git("add", ".")
	git("commit", "-qm", "main advanced")
	local main = git("rev-parse", "HEAD")
	git("remote", "add", "origin", root)
	git("update-ref", "refs/remotes/origin/main", main)
	git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
	git("switch", "-q", "topic")
	local automatic, scope = build()
	equal(base, scope.from_oid)
	equal(head, scope.head_oid)
	equal(base .. ".." .. head, scope.file_history_range)
	equal(resolve(base).id, scope.id)
	equal(1, #automatic.entries)
	local explicit, explicit_scope = build("origin/main")
	equal(main, explicit_scope.from_oid)
	assert(explicit_scope.id ~= scope.id)
	assert(review.changes.find(explicit, "base-only.txt").deleted)
	git("update-ref", "refs/remotes/origin/main", head)
	assert(not review.scope.detect_drift(scope).stale, "moving a ref invalidated frozen endpoints")
end

T["missing automatic bases are actionable and explicit bases need no remote"] = function()
	local scope, err = review.scope.resolve(root, { kind = "all" })
	assert(not scope and err.code == "remote_head_unavailable")
	assert(err.message:find("ReviewOpen all REV", 1, true), err.message)
	equal(base, resolve("HEAD").from_oid)
	scope, err = review.scope.resolve(root, { kind = "all", base = "missing" })
	assert(not scope and err.code == "revision_unavailable")
end

T["local drift invalidates all scopes before and during construction"] = function()
	local mutations = {
		function()
			write("new.txt", "untracked\n")
		end,
		function()
			write("new.txt", "different\n")
		end,
		function()
			git("add", "new.txt")
		end,
		function()
			write("a.txt", "unstaged\n")
		end,
		function()
			git("commit", "-qm", "new HEAD")
		end,
	}
	for _, mutate in ipairs(mutations) do
		local scope = resolve(base)
		mutate()
		assert(review.scope.detect_drift(scope).stale)
		assert(resolve(base).id ~= scope.id)
		local model, err = review.changes.build(root, scope)
		assert(not model and err.code == "working_tree_changed", vim.inspect(err))
	end
	local scope = resolve(base)
	local changed = false
	local model, err = review.changes.build(root, scope, {
		control = {
			checkpoint = function(phase)
				if phase == "changes.diff" and not changed then
					changed = true
					write("late.txt", "changed during build\n")
				end
				return true
			end,
		},
	})
	assert(changed and not model and err.code == "working_tree_changed", vim.inspect(err))
end

T["all retains bounded reads and cooperative cancellation"] = function()
	write("a.txt", "changed\n")
	write("gone.txt", "also changed\n")
	local scope = resolve(base)
	for _, limits in ipairs({ { max_files = 1 }, { max_file_bytes = 2 }, { max_model_bytes = 2 } }) do
		local options = {
			limits = limits,
			read_file = function()
				error("content read before preflight")
			end,
		}
		local model, err = review.changes.build(root, scope, options)
		assert(not model and err.code == "review_limit_exceeded", vim.inspect(err))
	end
	local model, err = review.changes.build(root, scope, {
		control = {
			checkpoint = function(phase)
				return phase ~= "changes.file_metadata", "cancelled"
			end,
		},
	})
	assert(not model and err.code == "review_cancelled", vim.inspect(err))
end

T["binary files, symlinks and submodules retain their representations"] = function()
	write("binary.dat", "before\0binary")
	assert(vim.uv.fs_symlink("a.txt", root .. "/link"))
	git("add", ".")
	git("update-index", "--add", "--cacheinfo", "160000," .. base .. ",module")
	git("commit", "-qm", "special files")
	local special_base = git("rev-parse", "HEAD")
	write("binary.dat", "after\0binary")
	assert(vim.uv.fs_unlink(root .. "/link"))
	assert(vim.uv.fs_symlink("gone.txt", root .. "/link"))
	git("update-index", "--cacheinfo", "160000," .. special_base .. ",module")
	local model = build(special_base)
	assert(review.changes.find(model, "binary.dat").binary)
	equal({}, review.changes.find(model, "binary.dat").hunks)
	equal("gone.txt", review.changes.find(model, "link").new_text)
	assert(review.changes.find(model, "module").submodule)
	assert(review.changes.find(model, "module").metadata_only)
end

T["all sessions round trip canonical comments and export their exact endpoints"] = function()
	write("a.txt", "final\n")
	local model, scope = build(base)
	local options = { state_home = state }
	local session = assert(review.store.new(root, scope, options))
	for _, side in ipairs({ "left", "right" }) do
		session = assert(review.store.add(session, {
			type = "issue",
			body = "Check " .. side,
			anchor = {
				kind = "range",
				path = "a.txt",
				layer = "all",
				side = side,
				start_line = 1,
				end_line = 1,
			},
		}, options))
	end
	local saved = assert(review.store.save(root, session, options))
	local loaded = assert(review.store.load(root, saved.id, options))
	equal(saved, loaded)
	equal("all", loaded.items[1].anchor.layer)
	equal(1, #review.changes.build(root, loaded.scope).entries)
	local markdown = assert(review.export.render(loaded))
	for _, text in ipairs({ scope.from_oid, scope.head_oid, scope.fingerprint, "a.txt:1 [OLD]", "a.txt:1 [NEW]" }) do
		assert(markdown:find(text, 1, true), text)
	end
	local invalid = vim.deepcopy(scope)
	invalid.diffview_args = {}
	assert(not review.store.new(root, invalid, options))
	invalid = vim.deepcopy(scope)
	invalid.file_history_range = "HEAD"
	assert(not review.store.new(root, invalid, options))
	local lines =
		review.panel._file_lines(review.panel.new({ root = root, scope = scope, session = loaded, model = model }))
	assert(table.concat(lines, "\n"):find("Changes (1)", 1, true))
end

T["the all picker accepts an automatic or exact base and cancellation is neutral"] = function()
	local requests = {}
	local input_callback
	vim.ui.select = function(choices, options, callback)
		equal("native_review", options.kind)
		for _, choice in ipairs(choices) do
			if choice.action == "all" then
				callback(choice)
				return
			end
		end
		error("all choice is missing")
	end
	vim.ui.input = function(_, callback)
		input_callback = callback
	end
	review.controller.open_async = function(request, requested_root)
		equal(root, requested_root)
		requests[#requests + 1] = request
	end
	review.controller._open_scope_picker(root)
	assert(input_callback)(nil)
	equal({}, requests)
	review.controller._open_scope_picker(root)
	assert(input_callback)("")
	review.controller._open_scope_picker(root)
	assert(input_callback)(" HEAD~2 ")
	equal({ { kind = "all" }, { kind = "all", base = "HEAD~2" } }, requests)
end

T["all opens both layouts, drills into commits, returns and refuses stale refresh"] = function()
	write("a.txt", "committed\n")
	git("add", "a.txt")
	git("commit", "-qm", "change")
	local commit = git("rev-parse", "HEAD")
	write("a.txt", "final\n")
	vim.cmd.edit(vim.fn.fnameescape(root .. "/a.txt"))
	local workspace, err = review.controller.open({ kind = "all", base = base }, root)
	assert(workspace, err)
	local id = workspace.session.id
	local entry = assert(review.changes.find(workspace.model, "a.txt"))
	assert(review.controller.present(entry.identity))
	equal("inline", workspace.mode_state.presentation.layout)
	assert(review.controller.layout("split"))
	equal("split", workspace.mode_state.presentation.layout)
	workspace.panel.callbacks.apply_commit(commit)
	equal("commit", review.controller._active_workspace().scope.kind)
	assert(review.controller.scope_back())
	equal(id, review.controller._active_workspace().session.id)
	equal("all", review.controller._active_workspace().scope.kind)
	assert(review.controller.close())
	workspace = assert(review.controller.open({ kind = "all", base = base }, root))
	equal(id, workspace.session.id)
	write("new.txt", "later change\n")
	assert(not review.controller.refresh())
	assert(workspace.session.stale)
end

return T
