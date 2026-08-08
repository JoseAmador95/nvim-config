vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local buffers = {}
local paths = {}

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local lint_calls = {}
local lint = {
	linters_by_ft = {},
	try_lint = function(names)
		lint_calls[#lint_calls + 1] = {
			buf = vim.api.nvim_get_current_buf(),
			names = vim.deepcopy(names),
		}
	end,
}
package.loaded.lint = lint

local executable_state = { hadolint = 1, ["markdownlint-cli2"] = 1, shellcheck = 1 }
local original_executable = vim.fn.executable
vim.fn.executable = function(name)
	return executable_state[name] or 0
end

local notifications = {}
local original_notify_once = vim.notify_once
vim.notify_once = function(message, level, opts)
	notifications[#notifications + 1] = { message = tostring(message), level = level, opts = opts }
end

local spec = require("plugins.lint")
local pager = require("config.pager")

test("plugin is restricted to the terminal editor", function()
	local previous_vscode = vim.g.vscode
	local previous_pager = pager.active

	vim.g.vscode = nil
	pager.active = false
	assert(spec.cond(), "terminal editor unexpectedly disables nvim-lint")

	vim.g.vscode = true
	assert(not spec.cond(), "VSCode unexpectedly enables nvim-lint")

	vim.g.vscode = nil
	pager.active = true
	assert(not spec.cond(), "pager unexpectedly enables nvim-lint")

	vim.g.vscode = previous_vscode
	pager.active = previous_pager
end)

local function named_buffer(path, ft, buftype, on_disk)
	if not vim.startswith(path, "lint://") then
		paths[#paths + 1] = path
		vim.fn.delete(path)
		if on_disk ~= false then
			assert(vim.fn.writefile({ "lint fixture" }, path) == 0)
		end
	end
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, path)
	vim.bo[buf].filetype = ft
	vim.bo[buf].buftype = buftype or ""
	buffers[#buffers + 1] = buf
	return buf
end

local function flush_scheduled()
	local drained = false
	vim.schedule(function()
		drained = true
	end)
	assert(
		vim.wait(1000, function()
			return drained
		end, 10),
		"scheduled lint callbacks did not drain"
	)
end

local function drain(expected)
	assert(
		vim.wait(1000, function()
			return #lint_calls >= expected
		end, 10),
		string.format("only %d/%d scheduled lint calls completed", #lint_calls, expected)
	)
end

test("first lazy-loaded BufWritePost runs lint exactly once", function()
	lint_calls = {}
	local buf = named_buffer(vim.fn.tempname() .. ".md", "markdown")
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = vim.api.nvim_create_augroup("LintSpecLazyLoader", { clear = true }),
		once = true,
		callback = function(args)
			spec.config()
			vim.api.nvim_exec_autocmds("BufWritePost", {
				buffer = args.buf,
				group = "NvimLint",
				modeline = false,
			})
		end,
	})

	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
	drain(1)
	equal(1, #lint_calls, "first lazy-loaded BufWritePost ran lint more than once")
end)

test("maps only the declared saved-file linters", function()
	lint_calls = {}
	equal({ "hadolint" }, lint.linters_by_ft.dockerfile, "Dockerfile linter mapping is wrong")
	equal({ "markdownlint-cli2" }, lint.linters_by_ft.markdown, "Markdown linter mapping is wrong")
	equal({ "shellcheck" }, lint.linters_by_ft.sh, "sh linter mapping is wrong")
	equal({ "shellcheck" }, lint.linters_by_ft.bash, "bash linter mapping is wrong")
	equal(nil, lint.linters_by_ft.zsh, "zsh unexpectedly has a linter")

	local markdown = named_buffer(vim.fn.tempname() .. ".md", "markdown.mdx")
	vim.api.nvim_exec_autocmds("BufReadPost", { buffer = markdown, modeline = false })
	flush_scheduled()
	equal(0, #lint_calls, "compound Markdown linted on read")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = markdown, modeline = false })
	equal(markdown, lint_calls[1].buf, "compound Markdown lint ran in the wrong buffer")
	equal({ "markdownlint-cli2" }, lint_calls[1].names, "compound Markdown did not resolve markdownlint-cli2")

	local docker_path = vim.fn.tempname() .. ".Dockerfile"
	local dockerfile = named_buffer(docker_path, "dockerfile", nil, false)
	vim.api.nvim_exec_autocmds("BufNewFile", { buffer = dockerfile, modeline = false })
	flush_scheduled()
	equal(1, #lint_calls, "unwritten Dockerfile ran a linter on BufNewFile")
	assert(vim.fn.writefile({ "FROM scratch" }, docker_path) == 0)
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = dockerfile, modeline = false })
	drain(2)
	equal(dockerfile, lint_calls[2].buf, "Dockerfile lint ran in the wrong buffer")
	equal({ "hadolint" }, lint_calls[2].names, "Dockerfile did not resolve hadolint")

	local shell = named_buffer(vim.fn.tempname() .. ".sh", "sh")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = shell, modeline = false })
	equal({ "shellcheck" }, lint_calls[3].names, "sh did not resolve ShellCheck")
end)

test("runs only once per save, never on read, create, or InsertLeave", function()
	lint_calls = {}
	local buf = named_buffer(vim.fn.tempname() .. ".md", "markdown")

	vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
	vim.api.nvim_exec_autocmds("BufNewFile", { buffer = buf, modeline = false })
	vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf, modeline = false })
	flush_scheduled()
	equal(0, #lint_calls, "non-save event ran lint")

	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
	equal(1, #lint_calls, "first save did not run lint exactly once")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
	equal(2, #lint_calls, "second save did not run lint exactly once")

	vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf, modeline = false })
	equal(2, #lint_calls, "InsertLeave unexpectedly ran lint")

	local events = {}
	for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "NvimLint" })) do
		events[autocmd.event] = true
	end
	equal({ BufWritePost = true }, events, "NvimLint registered a non-save autocmd")
end)

test("skips unnamed and non-file buffers", function()
	lint_calls = {}
	local nofile = named_buffer("lint://preview", "markdown", "nofile")
	vim.api.nvim_exec_autocmds("BufReadPost", { buffer = nofile, modeline = false })
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = nofile, modeline = false })

	local unnamed = vim.api.nvim_create_buf(true, false)
	vim.bo[unnamed].filetype = "markdown"
	buffers[#buffers + 1] = unnamed
	vim.api.nvim_exec_autocmds("BufNewFile", { buffer = unnamed, modeline = false })
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = unnamed, modeline = false })

	flush_scheduled()
	equal({}, lint_calls, "non-file buffer ran a linter")
end)

test("notifies once and skips a linter whose executable is missing", function()
	lint_calls = {}
	notifications = {}
	executable_state["markdownlint-cli2"] = 0
	local first = named_buffer(vim.fn.tempname() .. ".md", "markdown")
	local second = named_buffer(vim.fn.tempname() .. ".md", "markdown.pandoc")

	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = first, modeline = false })
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = second, modeline = false })

	flush_scheduled()
	equal({}, lint_calls, "missing markdownlint-cli2 was still invoked")
	equal(1, #notifications, "missing executable notification was repeated")
	assert(notifications[1].message:find("markdownlint%-cli2"), "notification omitted the executable")
	equal(vim.log.levels.WARN, notifications[1].level, "missing executable notification has the wrong level")
end)

vim.fn.executable = original_executable
vim.notify_once = original_notify_once
package.loaded.lint = nil

for _, buf in ipairs(buffers) do
	if vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end
for _, path in ipairs(paths) do
	vim.fn.delete(path)
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("lint_spec: %d tests passed", 6))
vim.cmd("quitall!")
