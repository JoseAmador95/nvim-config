-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)

local function command(arguments)
	local argv = { "git", "-C", fixture }
	vim.list_extend(argv, arguments)
	local result = vim.system(argv, { text = false }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end

local function write(path, value)
	local handle = assert(vim.uv.fs_open(fixture .. "/" .. path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_write(handle, value, 0))
	assert(vim.uv.fs_close(handle))
end

command({ "init", "-q" })
command({ "config", "user.email", "review@example.invalid" })
command({ "config", "user.name", "Review Fixture" })
write("a.txt", "one\r\ntwo\r\nstable one\r\nstable two\r\n")
command({ "add", "a.txt" })
command({ "commit", "-qm", "base" })
local base = command({ "rev-parse", "HEAD" })
write("a.txt", "one\r\nchanged\r\nstable one\r\nstable two\r\n")
command({ "add", "a.txt" })
command({ "commit", "-qm", "change" })
local first = command({ "rev-parse", "HEAD" })
command({ "mv", "a.txt", "b.txt" })
write("b.txt", "one\r\nchanged\r\nstable one\r\nstable two\r\nthree\r\n")
command({ "add", "b.txt" })
command({ "commit", "-qm", "rename" })
local second = command({ "rev-parse", "HEAD" })

local changes = require("config.native_review").changes

test("historical ranges preserve exact bytes, paths, hunks, and ordered commits", function()
	local scope = {
		kind = "range",
		root = vim.uv.fs_realpath(fixture),
		from_oid = base,
		to_oid = second,
		backend_id = "native",
	}
	local model, err = changes.build(fixture, scope)
	assert(model, vim.inspect(err))
	equal(
		{ first, second },
		vim.tbl_map(function(commit)
			return commit.oid
		end, model.commits),
		"commits are not oldest-to-newest"
	)
	equal("Review Fixture", model.commits[1].author, "commit author metadata is missing")
	equal("change", model.commits[1].subject, "commit subject metadata is missing")
	assert(model.commits[1].date:match("^%d%d%d%d%-%d%d%-%d%dT"), "commit date metadata is missing")
	equal("rename", model.commits[2].subject, "second commit subject metadata is missing")
	local entry = assert(changes.find(model, "b.txt"))
	assert(entry.renamed and entry.old_path == "a.txt" and entry.new_path == "b.txt", vim.inspect(entry))
	equal("one\r\ntwo\r\nstable one\r\nstable two\r\n", entry.old_text, "old CRLF blob was normalized")
	equal("one\r\nchanged\r\nstable one\r\nstable two\r\nthree\r\n", entry.new_text, "new CRLF blob was normalized")
	assert(#entry.hunks > 0 and not entry.binary and not entry.submodule)
	local request = assert(changes.selection_request(model, second, first))
	equal({ kind = "range", from = base, to = second, backend_id = "native" }, request)
	equal({ kind = "commit", rev = first, backend_id = "native" }, assert(changes.selection_request(model, first)))
	local immutable = pcall(function()
		model.kind = "working"
	end)
	assert(not immutable and model.kind == "range", "model fields are mutable")
	local copied_entries = model.entries
	table.remove(copied_entries)
	assert(#model.entries == 1, "mutating a projected entry list changed the model")
end)

test("multi-commit selection rejects topo-adjacent commits that are not one linear span", function()
	local main = string.rep("3", 40)
	local side = string.rep("4", 40)
	local merge = string.rep("5", 40)
	local model = {
		scope = { backend_id = "native" },
		commits = {
			{ oid = main, parents = { base }, parent_oid = base },
			{ oid = side, parents = { base }, parent_oid = base },
			{ oid = merge, parents = { main, side }, parent_oid = main },
		},
	}

	local request, err = changes.selection_request(model, side, merge)
	assert(not request and err.code == "invalid_selection")
	assert(err.message:find("linear single%-parent span"), vim.inspect(err))
	request, err = changes.selection_request(model, main, side)
	assert(not request and err.message:find("not in one linear history", 1, true), vim.inspect(err))
	equal({ kind = "commit", rev = merge, backend_id = "native" }, assert(changes.selection_request(model, merge)))
end)

test("working reviews keep staged, unstaged, and untracked identities distinct", function()
	write("b.txt", "staged\n")
	command({ "add", "b.txt" })
	write("b.txt", "unstaged\n")
	write("new.txt", "untracked\n")
	local before = command({ "status", "--porcelain=v1", "-z" })
	local scope = {
		kind = "working",
		root = vim.uv.fs_realpath(fixture),
		head_oid = second,
		backend_id = "native",
	}
	local model, err = changes.build(fixture, scope)
	assert(model, vim.inspect(err))
	local staged = assert(changes.find(model, "b.txt", "staged"))
	local unstaged = assert(changes.find(model, "b.txt", "unstaged"))
	local untracked = assert(changes.find(model, "new.txt", "untracked"))
	assert(staged.identity ~= unstaged.identity and staged.layer == "staged" and unstaged.layer == "unstaged")
	equal("staged\n", staged.new_text)
	equal("staged\n", unstaged.old_text)
	equal("unstaged\n", unstaged.new_text)
	equal("untracked\n", untracked.new_text)
	assert(changes.find(model, "b.txt") == nil, "an ambiguous layered lookup was not rejected")
	equal(before, command({ "status", "--porcelain=v1", "-z" }), "model construction changed repository state")
end)

test("root commits compare against an empty tree without parser noise", function()
	local scope = {
		kind = "commit",
		root = vim.uv.fs_realpath(fixture),
		commit_oid = base,
		backend_id = "native",
	}
	local model, err = changes.build(fixture, scope)
	assert(model, vim.inspect(err))
	assert(model.old_oid == nil and model.new_oid == base and #model.entries == 1)
	local entry = model.entries[1]
	assert(entry.added and entry.old_path == nil and entry.new_path == "a.txt", vim.inspect(entry))
	equal("one\r\ntwo\r\nstable one\r\nstable two\r\n", entry.new_text)
end)

test("model limits are preflighted with structured OLD/NEW details before blob reads", function()
	local scope = {
		kind = "range",
		root = vim.uv.fs_realpath(fixture),
		from_oid = base,
		to_oid = second,
		backend_id = "native",
	}
	local commands = {}
	local function runner(argv, input)
		commands[#commands + 1] = vim.deepcopy(argv)
		return vim.system(argv, { text = false, stdin = input }):wait()
	end
	local model, err = changes.build(fixture, scope, {
		runner = runner,
		max_file_bytes = 8,
		max_model_bytes = 1024,
	})
	assert(not model and err.code == "review_limit_exceeded", vim.inspect(err))
	equal("max_file_bytes", err.details.limit, "wrong limit was reported")
	equal(8, err.details.maximum, "file maximum was omitted")
	assert(err.details.actual > 8 and err.details.path == "a.txt", vim.inspect(err.details))
	equal("history", err.details.layer, "historical layer was omitted")
	equal("OLD", err.details.side, "oversized old side was mislabeled")
	local blob_reads = vim.tbl_filter(function(argv)
		return argv[4] == "cat-file" and argv[5] == "blob"
	end, commands)
	equal({}, blob_reads, "content was read before size preflight completed")
	local batch_checks = vim.tbl_filter(function(argv)
		return argv[4] == "cat-file" and argv[5]:find("--batch-check=", 1, true) == 1
	end, commands)
	equal(1, #batch_checks, "unique blobs were not batch-checked")

	local old_size = #"one\r\ntwo\r\nstable one\r\nstable two\r\n"
	local new_size = #"one\r\nchanged\r\nstable one\r\nstable two\r\nthree\r\n"
	model, err = changes.build(fixture, scope, {
		max_file_bytes = 1024,
		max_model_bytes = old_size + new_size - 1,
	})
	assert(not model and err.code == "review_limit_exceeded", vim.inspect(err))
	equal("max_model_bytes", err.details.limit, "aggregate limit was not enforced")
	equal(old_size + new_size, err.details.actual, "aggregate represented-side size was incorrect")
	equal("NEW", err.details.side, "aggregate overflow was attributed to the wrong side")
end)

test("file-count and cooperative cancellation stop the whole model before content reads", function()
	local working = {
		kind = "working",
		root = vim.uv.fs_realpath(fixture),
		head_oid = second,
		backend_id = "native",
	}
	local model, err = changes.build(fixture, working, { max_files = 2 })
	assert(not model and err.code == "review_limit_exceeded", vim.inspect(err))
	equal("max_files", err.details.limit, "working layers escaped the file-count limit")
	equal(3, err.details.actual, "layered entries were not counted as represented files")
	assert(err.details.path and err.details.layer and err.details.side, "file-count error was not actionable")

	local commands = {}
	local phases = {}
	local function runner(argv, input)
		commands[#commands + 1] = vim.deepcopy(argv)
		return vim.system(argv, { text = false, stdin = input }):wait()
	end
	model, err = changes.build(fixture, {
		kind = "range",
		root = vim.uv.fs_realpath(fixture),
		from_oid = base,
		to_oid = second,
		backend_id = "native",
	}, {
		runner = runner,
		control = {
			checkpoint = function(phase)
				phases[#phases + 1] = phase
				if phase == "changes.file_read" then
					return false, "superseded"
				end
			end,
		},
	})
	assert(not model and err.code == "review_cancelled" and err.message == "superseded", vim.inspect(err))
	assert(vim.tbl_contains(phases, "changes.blob_metadata_batch"), "blob batch exposed no checkpoint")
	local blob_reads = vim.tbl_filter(function(argv)
		return argv[4] == "cat-file" and argv[5] == "blob"
	end, commands)
	equal({}, blob_reads, "cancelled model read Git content")
end)

test("worktree reads reject same-size metadata ABA before publication", function()
	local canonical = assert(vim.uv.fs_realpath(fixture))
	local target = vim.fs.joinpath(canonical, "new.txt")
	local changed = false
	local model, err = changes.build(fixture, {
		kind = "working",
		root = canonical,
		head_oid = second,
		backend_id = "native",
	}, {
		lstat = function(path)
			local stat, stat_err = vim.uv.fs_lstat(path)
			if not stat then
				return nil, stat_err
			end
			stat = vim.deepcopy(stat)
			if changed and path == target then
				stat.ctime = { sec = stat.ctime.sec + 1, nsec = stat.ctime.nsec }
			end
			return stat
		end,
		control = {
			checkpoint = function(phase, progress)
				if phase == "changes.file_read" and progress.path == "new.txt" then
					changed = true
				end
			end,
		},
	})
	assert(not model and err.code == "working_tree_changed", vim.inspect(err))
	equal("new.txt", err.details.path, "metadata drift was attributed to the wrong file")
	assert(err.message:find("metadata changed", 1, true), vim.inspect(err))
end)

vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("review_changes_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
