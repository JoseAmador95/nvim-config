vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:append(vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "nvim-lint"))
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local buffers = {}
local fixture_paths = {}
local notifications = {}
local resolve_calls = {}
local tool_calls = {}
local raw_calls = {}
local mode = "allow"
local path_generation = 0

local execution = {
	resolve = function(capability, resolver, opts)
		resolve_calls[#resolve_calls + 1] = { capability = capability, opts = vim.deepcopy(opts) }
		if mode == "throw" then
			error("authority reader exploded")
		end
		if mode == "deny" then
			return nil, "workspace denied " .. string.rep("x", 400)
		end
		local resolved, resolve_err = resolver()
		if not resolved then
			return nil, resolve_err
		end
		if mode == "revoke" then
			return nil, "workspace authority was revoked before spawn"
		end
		return resolved, { runtime = "host", root = repo, repo_identity = repo }
	end,
}
local tool_bootstrap = {
	resolve = function(tool, command)
		tool_calls[#tool_calls + 1] = { tool = tool, command = command }
		if mode == "drift" then
			return nil, "verified record drifted"
		end
		if mode == "relative" then
			return command
		end
		path_generation = path_generation + 1
		return ("/verified/%s/%d"):format(command, path_generation)
	end,
}

local original_execution = package.loaded["config.execution"]
local original_tool_bootstrap = package.loaded["config.tool_bootstrap"]
local original_notify = vim.notify
local original_executable = vim.fn.executable
package.loaded["config.execution"] = execution
vim.notify = function(message, level, opts)
	notifications[#notifications + 1] = { message = tostring(message), level = level, opts = opts }
end
vim.fn.executable = function()
	error("vim.fn.executable must not authorize lint execution")
end

local lint = require("lint")
lint.lint = function(linter, opts)
	local argv = {}
	for _, argument in ipairs(linter.args or {}) do
		argv[#argv + 1] = type(argument) == "function" and argument() or argument
	end
	if not linter.stdin and linter.append_fname ~= false then
		argv[#argv + 1] = vim.api.nvim_buf_get_name(0)
	end
	local command = type(linter.cmd) == "function" and linter.cmd() or linter.cmd
	table.insert(argv, 1, command)
	raw_calls[#raw_calls + 1] = {
		argv = argv,
		command = command,
		linter = vim.deepcopy(linter),
		opts = vim.deepcopy(opts),
		buf = vim.api.nvim_get_current_buf(),
	}
	return { cancel = function() end }
end

local spec = require("plugins.lint")
local pager = require("config.pager")
local discovery_loaded_tool_bootstrap = package.loaded["config.tool_bootstrap"] ~= nil
local discovery_loaded_verified_tools = package.loaded.verified_tools ~= nil
package.loaded["config.tool_bootstrap"] = tool_bootstrap

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
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

local function reset_observed(next_mode)
	mode = next_mode or "allow"
	notifications = {}
	resolve_calls = {}
	tool_calls = {}
	raw_calls = {}
	path_generation = 0
end

local function named_buffer(suffix, ft, buftype, on_disk)
	local path = suffix:find("^lint://") and suffix or (vim.fn.tempname() .. suffix)
	if not path:find("^lint://") then
		fixture_paths[#fixture_paths + 1] = path
		if on_disk ~= false then
			assert(vim.fn.writefile({ "lint fixture" }, path) == 0)
		end
	end
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, path)
	vim.bo[buf].filetype = ft
	vim.bo[buf].buftype = buftype or ""
	buffers[#buffers + 1] = buf
	return buf, path
end

test("native spec discovery leaves verified tool resolution deferred", function()
	assert(not discovery_loaded_tool_bootstrap, "lint spec discovery loaded config.tool_bootstrap")
	assert(not discovery_loaded_verified_tools, "lint spec discovery loaded verified_tools")
	equal({}, tool_calls, "lint spec discovery resolved a tool")
end)

test("profiles and setup remain lazy and idempotent", function()
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
	pager.active = false

	reset_observed()
	spec.config()
	spec.config()
	equal({}, resolve_calls, "lint setup checked workspace authority during startup")
	equal({}, tool_calls, "lint setup resolved or probed tools during startup")
	local events = {}
	for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "NvimLint" })) do
		events[autocmd.event] = true
	end
	equal({ BufWritePost = true }, events, "idempotent setup registered the wrong autocmds")

	vim.g.vscode = previous_vscode
	pager.active = previous_pager
end)

test("saved-file routes preserve exact argv with verified command paths", function()
	reset_observed()
	local markdown = named_buffer(".md", "markdown.mdx")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = markdown, group = "NvimLint", modeline = false })
	equal({ "/verified/markdownlint-cli2/1", "-" }, raw_calls[1].argv, "Markdown argv drifted")
	equal(markdown, raw_calls[1].buf, "Markdown lint ran in the wrong buffer")

	local dockerfile = named_buffer(".Dockerfile", "dockerfile")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = dockerfile, group = "NvimLint", modeline = false })
	equal({ "/verified/hadolint/2", "-f", "json", "-" }, raw_calls[2].argv, "Hadolint argv drifted")

	local shell, shell_path = named_buffer(".sh", "sh")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = shell, group = "NvimLint", modeline = false })
	local canonical_shell =
		vim.fs.joinpath(assert(vim.uv.fs_realpath(vim.fs.dirname(shell_path))), vim.fs.basename(shell_path))
	equal(
		{ "/verified/shellcheck/3", "--format", "json1", vim.fn.fnameescape(canonical_shell) },
		raw_calls[3].argv,
		"ShellCheck argv drifted"
	)
	for index, call in ipairs(resolve_calls) do
		equal("lint-format", call.capability, "linter used the wrong execution capability")
		equal(raw_calls[index].buf, call.opts.buf, "linter authorized a different buffer from the spawn buffer")
	end
end)

test("direct lint API cannot bypass exact resolution or mutate its caller", function()
	reset_observed()
	local buf = named_buffer(".sh", "sh")
	vim.api.nvim_set_current_buf(buf)
	local args_observed_before_resolve = false
	local linter = {
		name = "shellcheck",
		cmd = "host-shellcheck",
		args = {
			function()
				args_observed_before_resolve = #resolve_calls == 0
				return "--format"
			end,
			"json1",
			"-",
		},
		stdin = true,
	}
	local before = vim.deepcopy(linter)
	local process = lint.lint(linter, { cwd = repo })
	assert(process, "direct verified lint was rejected")
	equal(before, linter, "direct lint gate mutated the caller's linter")
	assert(args_observed_before_resolve, "lint command was resolved before the runner's final command seam")
	equal("/verified/shellcheck/1", raw_calls[1].command, "direct lint retained an unverified command")
	equal({ "/verified/shellcheck/1", "--format", "json1", "-" }, raw_calls[1].argv, "direct lint argv drifted")
	equal(1, #resolve_calls, "idempotent setup wrapped lint.lint more than once")
end)

test("deny, revoke, resolver drift, and non-exact paths never reach lint", function()
	local buf = named_buffer(".md", "markdown")
	vim.api.nvim_set_current_buf(buf)
	for _, denied_mode in ipairs({ "deny", "throw", "revoke", "drift", "relative" }) do
		reset_observed(denied_mode)
		local process, err = lint.lint({ name = "markdownlint-cli2", cmd = "markdownlint-cli2", args = { "-" } })
		assert(not process and type(err) == "string", denied_mode .. " lint reported success")
		equal({}, raw_calls, denied_mode .. " lint reached the upstream spawn seam")
		equal(1, #notifications, denied_mode .. " lint did not notify exactly once")
		assert(#notifications[1].message <= 240, denied_mode .. " lint notification was not bounded")
	end
end)

test("unmanaged direct linters fail closed before authority resolution", function()
	reset_observed()
	local process, err = lint.lint({ name = "custom", cmd = "/tmp/custom" })
	assert(not process and tostring(err):find("not manifest%-backed"), "unmanaged direct linter was accepted")
	equal({}, resolve_calls, "unmanaged linter reached authority resolution")
	equal({}, tool_calls, "unmanaged linter reached tool resolution")
	equal({}, raw_calls, "unmanaged linter reached the upstream spawn seam")
	equal(1, #notifications, "unmanaged direct linter did not notify exactly once")
end)

test("only eligible written file buffers reach the central lint API", function()
	reset_observed()
	local nofile = named_buffer("lint://preview", "markdown", "nofile")
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = nofile, group = "NvimLint", modeline = false })
	local unwritten = named_buffer(".md", "markdown", "", false)
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = unwritten, group = "NvimLint", modeline = false })
	local unnamed = vim.api.nvim_create_buf(true, false)
	vim.bo[unnamed].filetype = "markdown"
	buffers[#buffers + 1] = unnamed
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = unnamed, group = "NvimLint", modeline = false })
	equal({}, resolve_calls, "ineligible buffer reached authority resolution")
	equal({}, raw_calls, "ineligible buffer reached the upstream spawn seam")
end)

pcall(vim.api.nvim_del_augroup_by_name, "NvimLint")
for _, buf in ipairs(buffers) do
	if vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end
for _, path in ipairs(fixture_paths) do
	vim.fn.delete(path)
end
vim.fn.executable = original_executable
vim.notify = original_notify
package.loaded["config.execution"] = original_execution
package.loaded["config.tool_bootstrap"] = original_tool_bootstrap

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("lint_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
