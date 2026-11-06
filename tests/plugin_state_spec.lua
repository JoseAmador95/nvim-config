vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local equal = require("tests.helpers").equal
local plugin_state = require("config.plugin_state")

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p", 448) == 1)
local original_lazy_config = package.loaded["lazy.core.config"]

local function checkout(name, files)
	local dir = vim.fs.joinpath(root, name)
	for path, lines in pairs(files) do
		local full = vim.fs.joinpath(dir, path)
		assert(vim.fn.mkdir(vim.fs.dirname(full), "p", 448) == 1 or vim.fn.isdirectory(vim.fs.dirname(full)) == 1)
		assert(vim.fn.writefile(lines, full) == 0)
	end
	return dir
end

local A = string.rep("a", 40)
local B = string.rep("b", 40)
local C = string.rep("c", 40)

T["HEAD is read from detached, loose-ref, packed-ref and worktree checkouts"] = function()
	equal(A, plugin_state.git_head(checkout("detached", { [".git/HEAD"] = { A } })))
	equal(
		B,
		plugin_state.git_head(checkout("loose", {
			[".git/HEAD"] = { "ref: refs/heads/main" },
			[".git/refs/heads/main"] = { B },
		}))
	)
	equal(
		C,
		plugin_state.git_head(checkout("packed", {
			[".git/HEAD"] = { "ref: refs/heads/main" },
			[".git/packed-refs"] = { "# pack-refs with: peeled fully-peeled sorted", C .. " refs/heads/main" },
		}))
	)
	local linked = checkout("linked", { ["gitdir/HEAD"] = { A } })
	assert(vim.fn.writefile({ "gitdir: gitdir" }, linked .. "/.git") == 0)
	equal(A, plugin_state.git_head(linked), "relative gitdir pointer was not followed")
	equal(nil, plugin_state.git_head(vim.fs.joinpath(root, "absent")))
end

T["inspection separates missing, drifted and local plugins"] = function()
	local lockfile = vim.fs.joinpath(root, "lazy-lock.json")
	assert(vim.fn.writefile({
		vim.json.encode({
			current = { branch = "main", commit = A },
			drifted = { branch = "main", commit = A },
			missing = { branch = "main", commit = A },
		}),
	}, lockfile) == 0)
	package.loaded["lazy.core.config"] = {
		options = { lockfile = lockfile },
		plugins = {
			current = { dir = checkout("current", { [".git/HEAD"] = { A } }), _ = { installed = true } },
			drifted = { dir = checkout("drifted", { [".git/HEAD"] = { B } }), _ = { installed = true } },
			missing = { dir = vim.fs.joinpath(root, "missing"), _ = { installed = false } },
			dev = { dir = root, _ = { installed = true, is_local = true } },
		},
	}
	local state = plugin_state.inspect()
	assert(state.loaded, "loaded Lazy configuration was not observed")
	equal(lockfile, state.lockfile)
	equal(3, state.total, "local plugins were counted")
	equal({ "missing" }, state.missing)
	equal({ { name = "drifted", head = B, locked = A } }, state.drift)

	package.loaded["lazy.core.config"] = nil
	equal({ loaded = false, total = 0, missing = {}, drift = {} }, plugin_state.inspect())
end

T["restore_locked moves drifted checkouts and reports the ones it cannot move"] = function()
	local plugins = vim.fs.joinpath(root, "restore")
	local function git(args)
		local result = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
		assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
		return vim.trim(result.stdout or "")
	end
	local function repository(name)
		local dir = vim.fs.joinpath(plugins, name)
		git({ "init", "-q", dir })
		local commits = {}
		for index = 1, 2 do
			assert(vim.fn.writefile({ tostring(index) }, dir .. "/file.txt") == 0)
			git({ "-C", dir, "add", "file.txt" })
			git({
				"-C",
				dir,
				"-c",
				"user.name=Fixture",
				"-c",
				"user.email=fixture@example.invalid",
				"-c",
				"commit.gpgsign=false",
				"commit",
				"-q",
				"-m",
				"c" .. index,
			})
			commits[index] = git({ "-C", dir, "rev-parse", "HEAD" })
		end
		return dir, commits
	end
	local behind, behind_commits = repository("behind")
	git({ "-C", behind, "checkout", "-q", "--detach", behind_commits[1] })
	local current, current_commits = repository("current")
	local unknown = repository("unknown")
	local calls = {}
	local function run_git(argv)
		calls[#calls + 1] = table.concat(argv, " ")
		return vim.system(argv, { text = true }):wait().code
	end

	local restored, failed = plugin_state.restore_locked({
		behind = { commit = behind_commits[2] },
		current = { commit = current_commits[2] },
		unknown = { commit = string.rep("d", 40) },
		skipped = { commit = string.rep("e", 40) },
		absent = { commit = string.rep("f", 40) },
	}, plugins, run_git, { skipped = true })

	equal({ "behind" }, restored, "drifted checkout was not restored")
	equal({ "unknown" }, failed, "unreachable commit was not reported")
	equal(behind_commits[2], plugin_state.git_head(behind), "checkout did not reach the locked commit")
	equal(current_commits[2], plugin_state.git_head(current), "a current checkout changed")
	for _, call in ipairs(calls) do
		assert(not call:find(current, 1, true), "a current checkout was touched: " .. call)
	end
	assert(plugin_state.git_head(unknown) ~= string.rep("d", 40))
end

hooks.post_once = function()
	package.loaded["lazy.core.config"] = original_lazy_config
	vim.fn.delete(root, "rf")
end

return T
