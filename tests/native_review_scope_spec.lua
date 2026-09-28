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

local scope = require("config.native_review").scope
local root = "/tmp/review-scope-repository"
local oid_a = string.rep("a", 40)
local oid_b = string.rep("b", 40)
local oid_c = string.rep("c", 40)
local oid_d = string.rep("d", 40)

local function key(arguments)
	return table.concat(arguments, "\0")
end

local function dependencies(outputs, calls, filesystem)
	filesystem = filesystem or {}
	return {
		root = function(value)
			assert(value == root)
			return root
		end,
		git = function(value, arguments)
			assert(value == root)
			calls[#calls + 1] = vim.deepcopy(arguments)
			local result = outputs[key(arguments)]
			if type(result) == "table" and result.error then
				return nil, result.error
			end
			if result == nil then
				return nil, "unexpected Git command: " .. vim.inspect(arguments)
			end
			return result
		end,
		lstat = function(path)
			assert(path == root .. "/new file.lua")
			return filesystem.stat or { type = "file", mode = tonumber("644", 8), size = 8 }
		end,
		readlink = function(path)
			assert(path == root .. "/new file.lua")
			return filesystem.target
		end,
	}
end

local function rev(revision)
	return key({ "rev-parse", "--verify", "--end-of-options", revision .. "^{commit}" })
end

local function assert_read_only_git(calls)
	for _, arguments in ipairs(calls) do
		local verb = arguments[1]
		local allowed = false
		if verb == "rev-parse" then
			allowed = (#arguments == 4 and arguments[2] == "--verify" and arguments[3] == "--end-of-options")
				or vim.deep_equal(arguments, {
					"rev-parse",
					"--abbrev-ref",
					"--symbolic-full-name",
					"@{upstream}",
				})
		elseif verb == "diff" then
			allowed = vim.deep_equal(arguments, {
				"diff",
				"--cached",
				"--binary",
				"--full-index",
				"--no-ext-diff",
				"--no-textconv",
				"--no-renames",
				"--",
			}) or vim.deep_equal(arguments, {
				"diff",
				"--binary",
				"--full-index",
				"--no-ext-diff",
				"--no-textconv",
				"--no-renames",
				"--",
			})
		elseif verb == "ls-files" then
			allowed = vim.deep_equal(arguments, { "ls-files", "--others", "--exclude-standard", "-z" })
		elseif verb == "hash-object" then
			allowed = #arguments == 4 and arguments[2] == "--no-filters" and arguments[3] == "--"
		elseif verb == "remote" then
			allowed = #arguments == 1
		elseif verb == "symbolic-ref" then
			allowed = #arguments == 4
				and arguments[2] == "--quiet"
				and arguments[3] == "--short"
				and arguments[4]:match("^refs/remotes/.+/HEAD$") ~= nil
		elseif verb == "merge-base" then
			allowed = #arguments == 3
				and arguments[2]:match("^[0-9a-f]+$") ~= nil
				and arguments[3]:match("^[0-9a-f]+$") ~= nil
		end
		assert(allowed, "unexpected or mutating Git command: " .. vim.inspect(arguments))
	end
end

test("commit and range scopes freeze full OIDs and emit exact Diffview ranges", function()
	local calls = {}
	local outputs = {
		[rev("feature")] = oid_a .. "\n",
		[rev("from")] = oid_b .. "\n",
		[rev("to")] = oid_c .. "\n",
	}
	local deps = dependencies(outputs, calls)
	local commit = assert(scope.resolve(root, { kind = "commit", rev = "feature" }, deps))
	assert(commit.commit_oid == oid_a)
	assert(vim.deep_equal(commit.diffview_args, { oid_a .. "^!" }))
	assert(commit.file_history_range == oid_a .. "^!")
	local again = assert(scope.resolve(root, { kind = "commit", rev = "feature" }, deps))
	assert(again.id == commit.id, "commit scope id is not deterministic")

	local range = assert(scope.resolve(root, { kind = "range", from = "from", to = "to" }, deps))
	local exact = oid_b .. ".." .. oid_c
	assert(vim.deep_equal(range.diffview_args, { exact }) and range.file_history_range == exact)
	assert(range.id ~= commit.id, "scope kind did not contribute to identity")
	assert(vim.deep_equal(calls[1], { "rev-parse", "--verify", "--end-of-options", "feature^{commit}" }))
	assert_read_only_git(calls)
end)

test("branch scope tries upstream remote then origin and freezes merge-base through HEAD", function()
	local calls = {}
	local outputs = {
		[key({ "remote" })] = "team\norigin\n",
		[key({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })] = "team/topic\n",
		[key({ "symbolic-ref", "--quiet", "--short", "refs/remotes/team/HEAD" })] = { error = "missing" },
		[key({ "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })] = "origin/main\n",
		[rev("origin/main")] = oid_a .. "\n",
		[rev("HEAD")] = oid_b .. "\n",
		[key({ "merge-base", oid_a, oid_b })] = oid_c .. "\n",
	}
	local branch = assert(scope.resolve(root, { kind = "branch" }, dependencies(outputs, calls)))
	assert(branch.label == "origin/main…HEAD")
	assert(branch.base_oid == oid_a and branch.merge_base_oid == oid_c and branch.head_oid == oid_b)
	assert(branch.default_remote == "origin")
	assert(vim.deep_equal(branch.diffview_args, { oid_c .. ".." .. oid_b }))
	assert(branch.file_history_range == oid_c .. ".." .. oid_b)
	local symbolic = {}
	for _, arguments in ipairs(calls) do
		if arguments[1] == "symbolic-ref" then
			symbolic[#symbolic + 1] = arguments[4]
		end
	end
	assert(vim.deep_equal(symbolic, { "refs/remotes/team/HEAD", "refs/remotes/origin/HEAD" }))
	assert_read_only_git(calls)
end)

test("sole remote is used locally and missing symbolic HEAD is a structured picker error", function()
	local calls = {}
	local outputs = {
		[key({ "remote" })] = "fork\n",
		[key({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" })] = { error = "none" },
		[key({ "symbolic-ref", "--quiet", "--short", "refs/remotes/fork/HEAD" })] = { error = "none" },
	}
	local resolved, err = scope.resolve(root, { kind = "branch" }, dependencies(outputs, calls))
	assert(not resolved and err.code == "remote_head_unavailable")
	assert(vim.deep_equal(err.details.remotes, { "fork" }))
	assert(vim.deep_equal(err.details.attempted, { "fork" }))
	assert_read_only_git(calls)
end)

local function working_outputs(options)
	options = options or {}
	return {
		[rev("HEAD")] = (options.head or oid_a) .. "\n",
		[key({
			"diff",
			"--cached",
			"--binary",
			"--full-index",
			"--no-ext-diff",
			"--no-textconv",
			"--no-renames",
			"--",
		})] = options.staged or "staged patch",
		[key({
			"diff",
			"--binary",
			"--full-index",
			"--no-ext-diff",
			"--no-textconv",
			"--no-renames",
			"--",
		})] = options.unstaged or "unstaged patch",
		[key({ "ls-files", "--others", "--exclude-standard", "-z" })] = "new file.lua\0",
		[key({ "hash-object", "--no-filters", "--", "new file.lua" })] = (options.untracked_oid or oid_d) .. "\n",
	}
end

test("working fingerprint separates HEAD, staged, unstaged, and untracked content without Git writes", function()
	local first_calls = {}
	local first = assert(
		scope.resolve(root, { kind = "working" }, dependencies(working_outputs({ staged = "staged one" }), first_calls))
	)
	local second_calls = {}
	local second = assert(
		scope.resolve(
			root,
			{ kind = "working" },
			dependencies(working_outputs({ staged = "staged two" }), second_calls)
		)
	)
	assert(first.head_oid == oid_a and first.layers.head == oid_a)
	assert(first.layers.staged ~= second.layers.staged and first.fingerprint ~= second.fingerprint)
	assert(first.layers.unstaged == second.layers.unstaged and first.layers.untracked == second.layers.untracked)
	assert(vim.deep_equal(first.diffview_args, {}) and first.file_history_range == nil)
	assert_read_only_git(first_calls)
	assert_read_only_git(second_calls)
end)

test("working drift detects changes in HEAD and every content layer", function()
	local baseline_calls = {}
	local baseline = assert(scope.resolve(root, { kind = "working" }, dependencies(working_outputs(), baseline_calls)))
	assert_read_only_git(baseline_calls)

	local unchanged_calls = {}
	local unchanged = assert(scope.detect_drift(baseline, dependencies(working_outputs(), unchanged_calls)))
	assert(not unchanged.stale and unchanged.current.fingerprint == baseline.fingerprint)
	assert_read_only_git(unchanged_calls)

	for _, changed in ipairs({
		{ head = oid_b },
		{ staged = "changed staged patch" },
		{ unstaged = "changed unstaged patch" },
		{ untracked_oid = oid_c },
		{ untracked_mode = tonumber("755", 8) },
	}) do
		local calls = {}
		local filesystem = changed.untracked_mode
				and { stat = { type = "file", mode = changed.untracked_mode, size = 8 } }
			or nil
		local drift = assert(scope.detect_drift(baseline, dependencies(working_outputs(changed), calls, filesystem)))
		assert(drift.stale and drift.current.fingerprint ~= baseline.fingerprint)
		assert_read_only_git(calls)
	end

	local historical_calls = {}
	local historical = assert(scope.detect_drift({ kind = "commit" }, dependencies({}, historical_calls)))
	assert(not historical.stale and #historical_calls == 0)
end)

test("working fingerprint hashes symlink targets and rejects special untracked files", function()
	local calls = {}
	local linked = assert(
		scope.resolve(
			root,
			{ kind = "working" },
			dependencies(
				working_outputs(),
				calls,
				{ stat = { type = "link", mode = tonumber("777", 8), size = 5 }, target = "a.lua" }
			)
		)
	)
	assert(linked.layers.untracked)
	for _, arguments in ipairs(calls) do
		assert(arguments[1] ~= "hash-object", "symlink fingerprint followed the target file")
	end

	local invalid, err = scope.resolve(
		root,
		{ kind = "working" },
		dependencies(working_outputs(), {}, { stat = { type = "fifo", mode = tonumber("644", 8), size = 0 } })
	)
	assert(not invalid and err.code == "working_tree_unavailable")
	assert(err.message:find("unsupported untracked file type", 1, true))
end)

test("untracked hashing is NUL-safe, ordered, and uses bounded multi-path batches", function()
	local paths = {}
	for index = 1, 2000 do
		paths[#paths + 1] = ("dir/%04d-%s.lua"):format(index, string.rep("x", 70))
	end
	paths[3] = "line\nbreak.lua"
	paths[4] = "tab\tname.lua"
	paths[5] = "space name.lua"
	paths[#paths + 1] = "linked.lua"
	table.sort(paths)
	local hash_calls = {}
	local checkpoints = {}
	local outputs = working_outputs()
	outputs[key({ "ls-files", "--others", "--exclude-standard", "-z" })] = table.concat(paths, "\0") .. "\0"
	local resolved, err = scope.resolve(root, { kind = "working" }, {
		root = function()
			return root
		end,
		git = function(_, arguments)
			if arguments[1] == "hash-object" then
				assert(arguments[2] == "--no-filters" and arguments[3] == "--")
				assert(not vim.tbl_contains(arguments, "--stdin-paths"))
				local bytes = #"git" + 1 + #"-C" + 1 + #root + 1
				for _, argument in ipairs(arguments) do
					bytes = bytes + #argument + 1
				end
				assert(bytes <= 128 * 1024, "hash-object argv exceeded its private cap")
				hash_calls[#hash_calls + 1] = vim.list_slice(arguments, 4)
				return table.concat(
					vim.tbl_map(function()
						return oid_d
					end, hash_calls[#hash_calls]),
					"\n"
				) .. "\n"
			end
			return outputs[key(arguments)]
		end,
		lstat = function(path)
			if path == root .. "/linked.lua" then
				return { type = "link", mode = tonumber("777", 8), size = 11 }
			end
			return { type = "file", mode = tonumber("644", 8), size = 1 }
		end,
		readlink = function(path)
			assert(path == root .. "/linked.lua")
			return "target name"
		end,
		max_files = #paths,
		max_file_bytes = 16,
		max_model_bytes = #paths + 16,
		control = {
			checkpoint = function(phase)
				checkpoints[#checkpoints + 1] = phase
			end,
		},
	})
	assert(resolved, vim.inspect(err))
	assert(#hash_calls > 1, "large untracked sets retained one unbounded Git argv")
	local hashed = {}
	for _, batch in ipairs(hash_calls) do
		vim.list_extend(hashed, batch)
	end
	local expected = vim.tbl_filter(function(path)
		return path ~= "linked.lua"
	end, paths)
	assert(vim.deep_equal(expected, hashed), "batched paths lost ordering or control bytes")
	assert(vim.tbl_contains(checkpoints, "scope.untracked_hash_batch"), "hash batches exposed no checkpoint")
end)

test("untracked limits fail before regular file hashing", function()
	local paths = { "one.lua", "two.lua" }
	local function limited(overrides)
		local hash_calls = 0
		local stat_calls = 0
		local outputs = working_outputs()
		outputs[key({ "ls-files", "--others", "--exclude-standard", "-z" })] = table.concat(paths, "\0") .. "\0"
		local options = vim.tbl_extend("force", {
			root = function()
				return root
			end,
			git = function(_, arguments)
				if arguments[1] == "hash-object" then
					hash_calls = hash_calls + 1
					return oid_d .. "\n" .. oid_c .. "\n"
				end
				return outputs[key(arguments)]
			end,
			lstat = function(path)
				stat_calls = stat_calls + 1
				return { type = "file", mode = tonumber("644", 8), size = path:find("one", 1, true) and 4 or 5 }
			end,
		}, overrides)
		local value, err = scope.resolve(root, { kind = "working" }, options)
		return value, err, hash_calls, stat_calls
	end

	local value, err, hash_calls, stat_calls = limited({ max_files = 1 })
	assert(not value and err.code == "review_limit_exceeded" and err.details.limit == "max_files")
	assert(err.details.actual == 2 and err.details.maximum == 1 and err.details.side == "NEW")
	assert(hash_calls == 0 and stat_calls == 0, "file-count rejection inspected or hashed content")

	value, err, hash_calls = limited({ max_files = 2, max_file_bytes = 3 })
	assert(not value and err.details.limit == "max_file_bytes" and err.details.path == "one.lua")
	assert(err.details.actual == 4 and err.details.layer == "untracked" and hash_calls == 0)

	value, err, hash_calls = limited({ max_files = 2, max_file_bytes = 5, max_model_bytes = 8 })
	assert(not value and err.details.limit == "max_model_bytes" and err.details.path == "two.lua")
	assert(err.details.actual == 9 and hash_calls == 0, "aggregate rejection ran hash-object")
end)

test("invalid requests fail before Git execution", function()
	local calls = {}
	local value, err = scope.resolve(root, { kind = "commit", rev = "HEAD", extra = true }, dependencies({}, calls))
	assert(not value and err.code == "invalid_scope" and #calls == 0)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_scope_spec: %d tests passed", count))
vim.cmd("quitall!")
