vim.o.shadafile = "NONE"
vim.o.swapfile = false

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

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
local path = fixture .. "/sample.lua"
assert(vim.fn.writefile({ "local selected_symbol = 1", "second line", "third line" }, path) == 0)
local root = assert(vim.uv.fs_realpath(fixture))
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local selected_symbol = 1", "second line", "third line" })
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 1, 8 })

local context = require("config.agent_context")
local function base_dependencies()
	return {
		current_root = function()
			return root
		end,
		get_diagnostics = function()
			return {
				{
					lnum = 1,
					col = 2,
					end_lnum = 1,
					end_col = 5,
					severity = vim.diagnostic.severity.WARN,
					message = "diagnostic",
					source = "lua_ls",
					code = "W1",
				},
			}
		end,
		notify = function() end,
	}
end

test("no-bang context contains range, selection, cword hint, and diagnostics only", function()
	local deps = base_dependencies()
	local git_calls = 0
	deps.git = function()
		git_calls = git_calls + 1
		return { code = 0, stdout = "", stderr = "" }
	end
	local payload = assert(context.collect({ buf = buf, line1 = 1, line2 = 2 }, deps))
	assert(payload.version == 1 and payload.repo_root == root and payload.path == "sample.lua")
	assert(payload.range.start.line == 1 and payload.range.start.column == 1)
	assert(payload.range["end"].line == 2 and payload.range["end"].column == 12)
	assert(payload.selection == "local selected_symbol = 1\nsecond line")
	assert(payload.symbol == "selected_symbol", "current-word symbol hint drifted")
	assert(payload.git == nil and git_calls == 0, "no-bang context read Git diffs")
	local diagnostic = payload.diagnostics[1]
	assert(diagnostic.start.line == 2 and diagnostic.start.column == 3)
	assert(diagnostic["end"].line == 2 and diagnostic["end"].column == 6)
	assert(diagnostic.severity == "warn" and diagnostic.source == "lua_ls" and diagnostic.code == "W1")
end)

test("bang adds separate staged, unstaged, and untracked data through argv Git", function()
	local deps = base_dependencies()
	deps.symbol = function()
		return "ExplicitSymbol"
	end
	local commands = {}
	deps.git = function(command)
		commands[#commands + 1] = command
		local joined = table.concat(command, " ")
		if joined:find("--cached", 1, true) then
			return { code = 0, stdout = "staged\n", stderr = "" }
		end
		if joined:find("ls-files", 1, true) then
			return { code = 0, stdout = "new.lua\0more.lua\0", stderr = "" }
		end
		return { code = 0, stdout = "unstaged\n", stderr = "" }
	end
	local payload = assert(context.collect({ buf = buf, line1 = 3, line2 = 3, bang = true }, deps))
	assert(payload.symbol == "ExplicitSymbol")
	assert(payload.git.staged_diff == "staged\n")
	assert(payload.git.unstaged_diff == "unstaged\n")
	assert(vim.deep_equal(payload.git.untracked, { "new.lua", "more.lua" }))
	assert(#commands == 3)
	for _, command in ipairs(commands) do
		assert(command[1] == "git" and command[2] == "-C" and command[3] == root)
	end
	assert(vim.tbl_contains(commands[1], "--no-ext-diff") and vim.tbl_contains(commands[1], "--no-textconv"))
end)

test("default Git reads clear inherited routing and disable optional locks", function()
	local bin = fixture .. "/bin"
	assert(vim.fn.mkdir(bin, "p") == 1)
	local fake = bin .. "/git"
	assert(vim.fn.writefile({
		"#!/bin/sh",
		[[[ -z "${GIT_DIR+x}" ] && [ -z "${GIT_WORK_TREE+x}" ] && [ -z "${GIT_INDEX_FILE+x}" ] || exit 71]],
		[[[ "$GIT_OPTIONAL_LOCKS" = 0 ] && [ "$GIT_NO_LAZY_FETCH" = 1 ] || exit 72]],
		[[printf 'sanitized\n']],
	}, fake) == 0)
	assert(vim.fn.setfperm(fake, "rwxr-xr-x") == 1)
	local old_path = vim.env.PATH
	local old_dir = vim.env.GIT_DIR
	local old_worktree = vim.env.GIT_WORK_TREE
	local old_index = vim.env.GIT_INDEX_FILE
	vim.env.PATH = bin .. ":" .. old_path
	vim.env.GIT_DIR = "/tmp/hostile-git-dir"
	vim.env.GIT_WORK_TREE = "/tmp/hostile-worktree"
	vim.env.GIT_INDEX_FILE = "/tmp/hostile-index"
	local output, err = require("config.repo").git(root, { "status" })
	vim.env.PATH = old_path
	vim.env.GIT_DIR = old_dir
	vim.env.GIT_WORK_TREE = old_worktree
	vim.env.GIT_INDEX_FILE = old_index
	assert(output == "sanitized\n", err)
end)

test("OSC52 plus-register call receives one UTF-8 JSON line even locally", function()
	local deps = base_dependencies()
	local copied
	deps.copy = function(lines, register_type)
		copied = { lines = lines, register_type = register_type }
	end
	local encoded = assert(context.emit({ buf = buf, line1 = 2, line2 = 2 }, deps))
	assert(copied and #copied.lines == 1 and copied.lines[1] == encoded)
	assert(copied.register_type == "v")
	assert(pcall(vim.str_utfindex, encoded), "OSC52 payload is not UTF-8")
	local decoded = vim.json.decode(encoded)
	assert(decoded.selection == "second line" and decoded.git == nil)
end)

test("payloads over one MiB are refused before OSC52", function()
	local copied = false
	local encoded, err = context.encode({ version = 1, selection = string.rep("x", context.max_bytes) })
	assert(not encoded and err:find("maximum", 1, true))
	local deps = base_dependencies()
	deps.copy = function()
		copied = true
	end
	deps.notify = function() end
	local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", context.max_bytes) })
	assert(context.emit({ buf = buf, line1 = 1, line2 = 1 }, deps) == nil)
	assert(not copied, "oversized context reached OSC52")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
end)

vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("agent_context_spec: %d tests passed", count))
vim.cmd("quitall!")
