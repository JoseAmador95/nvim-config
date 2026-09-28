vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:append(vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "conform.nvim"))
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local notifications = {}
local resolve_calls = {}
local tool_calls = {}
local spawns = {}
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
		if mode == "revoke" or (mode == "revoke-runner" and #resolve_calls == 2) then
			return nil, "workspace authority was revoked before spawn"
		end
		return resolved, { runtime = "host", root = repo, repo_identity = repo }
	end,
}
local tool_bootstrap = {
	resolve = function(tool, command)
		tool_calls[#tool_calls + 1] = { tool = tool, command = command }
		if mode == "drift" or (mode == "drift-runner" and #tool_calls == 2) then
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
local original_system = vim.system
local original_executable = vim.fn.executable
package.loaded["config.execution"] = execution
vim.notify = function(message, level, opts)
	notifications[#notifications + 1] = { message = tostring(message), level = level, opts = opts }
end
vim.fn.executable = function()
	return 1
end
vim.system = function(argv, opts, callback)
	spawns[#spawns + 1] = { argv = vim.deepcopy(argv), opts = vim.deepcopy(opts) }
	local result = { code = 0, signal = 0, stdout = opts.stdin or "", stderr = "" }
	if callback then
		callback(result)
	end
	return {
		pid = 1000 + #spawns,
		wait = function()
			return result
		end,
	}
end

local conform = require("conform")
local formatting_spec = require("plugins.formatting")[1]
local formatting = require("config.formatting")
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
	spawns = {}
	path_generation = 0
end

local function drain()
	local done = false
	vim.schedule(function()
		done = true
	end)
	assert(
		vim.wait(1000, function()
			return done
		end, 10),
		"scheduled formatter callback did not drain"
	)
end

local buffer = vim.api.nvim_create_buf(true, false)
local filename = vim.fn.tempname() .. ".lua"
vim.api.nvim_buf_set_name(buffer, filename)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local x=1", "return x" })
vim.bo[buffer].filetype = "lua"
vim.api.nvim_set_current_buf(buffer)

test("native spec discovery leaves verified tool resolution deferred", function()
	assert(not discovery_loaded_tool_bootstrap, "formatting spec discovery loaded config.tool_bootstrap")
	assert(not discovery_loaded_verified_tools, "formatting spec discovery loaded verified_tools")
	equal({}, tool_calls, "formatting spec discovery resolved a tool")
end)

test("central wrapper is idempotent, caller-owned, callback-once, and LSP-never", function()
	local raw_calls = {}
	local fake = {
		list_formatters_for_buffer = function()
			return { "stylua" }
		end,
		format = function(opts, callback)
			raw_calls[#raw_calls + 1] = vim.deepcopy(opts)
			callback(nil, true)
			callback("duplicate callback")
			return true
		end,
	}
	assert(formatting.setup(fake))
	assert(formatting.setup(fake))
	local opts = {
		bufnr = buffer,
		formatters = { "stylua" },
		lsp_format = "fallback",
		lsp_fallback = true,
	}
	local before = vim.deepcopy(opts)
	local callbacks = 0
	assert(fake.format(opts, function()
		callbacks = callbacks + 1
	end))
	equal(before, opts, "central wrapper mutated caller options")
	equal(1, #raw_calls, "idempotent setup wrapped conform.format twice")
	equal("never", raw_calls[1].lsp_format, "central API permits LSP formatting")
	equal(false, raw_calls[1].lsp_fallback, "legacy lsp_fallback bypassed the central policy")
	equal(1, callbacks, "central wrapper invoked the callback more than once")
end)

test("every configured formatter maps to its exact manifest command", function()
	reset_observed()
	local expected = {
		["clang-format"] = { tool = "clang-format", command = "clang-format" },
		prettierd = { tool = "prettierd", command = "prettierd" },
		ruff_format = { tool = "ruff", command = "ruff" },
		shfmt = { tool = "shfmt", command = "shfmt" },
		stylua = { tool = "stylua", command = "stylua" },
		tombi = { tool = "tombi", command = "tombi" },
	}
	for name in vim.spairs(expected) do
		local path = formatting_spec.opts.formatters[name].command(nil, { buf = buffer })
		assert(vim.startswith(path, "/verified/"), name .. " did not return an exact verified path")
	end
	-- `vim.spairs` above defines the deterministic call order.
	local ordered = {}
	for name in vim.spairs(expected) do
		ordered[#ordered + 1] = expected[name]
	end
	equal(ordered, tool_calls, "formatter-to-manifest command mapping drifted")
end)

test("plugin setup is lazy, caller-owned, and configures only verified formatters", function()
	reset_observed()
	local caller_opts = vim.deepcopy(formatting_spec.opts)
	local before = vim.deepcopy(caller_opts)
	formatting_spec.config(nil, caller_opts)
	equal(before, caller_opts, "plugin setup mutated Lazy-owned options")
	equal({}, resolve_calls, "plugin setup checked workspace authority during startup")
	equal({}, tool_calls, "plugin setup resolved or probed tools during startup")
	assert(formatting.setup(conform))
	assert(formatting.setup(conform))
	assert(formatting_spec.opts.formatters_by_ft.rust == nil, "rustfmt remains enabled without a manifest contract")
	for _, ft in ipairs({
		"javascript",
		"typescript",
		"javascriptreact",
		"typescriptreact",
		"json",
		"jsonc",
		"yaml",
		"markdown",
	}) do
		equal({ "prettierd" }, formatting_spec.opts.formatters_by_ft[ft], ft .. " retained a prettier fallback")
	end
	for _, name in ipairs({ "stylua", "clang-format", "ruff_format", "shfmt", "tombi", "prettierd" }) do
		assert(type(formatting_spec.opts.formatters[name].command) == "function", name .. " lacks a verified command")
	end
end)

test("direct Conform API resolves twice and spawns the final exact argv", function()
	reset_observed()
	local opts = {
		bufnr = buffer,
		formatters = { "stylua" },
		lsp_format = "fallback",
		lsp_fallback = true,
	}
	local before = vim.deepcopy(opts)
	local callbacks = 0
	assert(conform.format(opts, function(err)
		assert(err == nil, err)
		callbacks = callbacks + 1
	end))
	drain()
	equal(before, opts, "direct Conform API mutated caller options")
	equal(2, #resolve_calls, "formatter was not re-resolved at the runner boundary")
	for _, item in ipairs(resolve_calls) do
		equal("lint-format", item.capability, "formatter used the wrong execution capability")
		equal(buffer, item.opts.buf, "formatter authorized the wrong buffer")
	end
	equal({
		"/verified/stylua/2",
		"--search-parent-directories",
		"--respect-ignores",
		"--stdin-filepath",
		vim.fs.joinpath(assert(vim.uv.fs_realpath(vim.fs.dirname(filename))), vim.fs.basename(filename)),
		"-",
	}, spawns[1].argv, "Conform did not spawn the final verified path with exact arguments")
	equal(1, callbacks, "successful direct formatting invoked its callback more than once")
end)

test("deny, revoke, resolver drift, and non-exact paths never reach spawn", function()
	for _, denied_mode in ipairs({ "deny", "throw", "revoke", "revoke-runner", "drift", "drift-runner", "relative" }) do
		reset_observed(denied_mode)
		local callbacks = 0
		local callback_error
		local ok = conform.format({
			bufnr = buffer,
			formatters = { "stylua" },
			async = denied_mode == "revoke-runner",
		}, function(callback_err)
			callbacks = callbacks + 1
			callback_error = callback_err
		end)
		assert(not ok, denied_mode .. " formatting reported success")
		equal({}, spawns, denied_mode .. " formatting reached vim.system")
		equal(1, callbacks, denied_mode .. " formatting invoked callback more than once")
		equal(1, #notifications, denied_mode .. " formatting did not notify exactly once")
		assert(#notifications[1].message <= 240, denied_mode .. " notification was not bounded")
		assert(
			type(callback_error) == "string" and callback_error ~= "",
			denied_mode .. " callback omitted the failure"
		)
	end

	reset_observed()
	local ok = conform.format({ bufnr = buffer, formatters = { "prettier" } })
	assert(not ok, "unmanaged direct formatter was accepted")
	equal({}, resolve_calls, "unmanaged formatter reached authority resolution")
	equal({}, spawns, "unmanaged formatter reached spawn")
	equal(1, #notifications, "unmanaged formatter did not notify exactly once")
end)

test("save, FormatFile mapping target, and formatexpr share the central gate", function()
	reset_observed()
	vim.g.conform_format_on_save = true
	vim.api.nvim_exec_autocmds("BufWritePre", { buffer = buffer, group = "Conform", modeline = false })
	equal(1, #spawns, "format-on-save bypassed or skipped the central gate")

	vim.cmd("FormatFile")
	drain()
	equal(2, #spawns, "FormatFile did not use the central gate")

	vim.bo[buffer].formatexpr = "v:lua.require'conform'.formatexpr()"
	vim.api.nvim_buf_call(buffer, function()
		vim.cmd("normal! gggqG")
	end)
	drain()
	equal(3, #spawns, "formatexpr did not use the central gate")
	equal(6, #resolve_calls, "one of the three entry points skipped runner-boundary revalidation")
	vim.g.conform_format_on_save = false
end)

pcall(vim.api.nvim_del_user_command, "FormatFile")
pcall(vim.api.nvim_del_user_command, "FormatToggle")
pcall(vim.api.nvim_del_augroup_by_name, "Conform")
if vim.api.nvim_buf_is_valid(buffer) then
	vim.api.nvim_buf_delete(buffer, { force = true })
end
vim.fn.executable = original_executable
vim.system = original_system
vim.notify = original_notify
package.loaded["config.execution"] = original_execution
package.loaded["config.tool_bootstrap"] = original_tool_bootstrap

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("formatting_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
