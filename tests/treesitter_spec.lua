vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local paths = {}
local buffers = {}

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

local function make_buffer(suffix, contents, ft)
	local path = vim.fn.tempname() .. suffix
	assert(vim.fn.writefile({ contents }, path) == 0)
	paths[#paths + 1] = path
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	buffers[#buffers + 1] = buf
	vim.bo[buf].filetype = ft
	return buf
end

local installed = {}
local starts = {}
local install_calls = {}
local install_task

local function successful_task()
	return {
		await = function(_, callback)
			callback(nil, true)
		end,
		wait = function()
			return true
		end,
	}
end

package.loaded["nvim-treesitter"] = {
	setup = function() end,
	get_installed = function(kind)
		assert(kind == "parsers")
		return vim.deepcopy(installed)
	end,
	install = function(parsers, opts)
		install_calls[#install_calls + 1] = { parsers = vim.deepcopy(parsers), opts = vim.deepcopy(opts) }
		return install_task or successful_task()
	end,
}

local original_start = vim.treesitter.start
local original_get_lang = vim.treesitter.language.get_lang
vim.treesitter.start = function(buf, lang)
	starts[#starts + 1] = { buf = buf, lang = lang }
end
vim.treesitter.language.get_lang = function(ft)
	return ft
end

local runtime = require("config.treesitter_runtime")

local function reset_runtime()
	runtime.setup({ parsers = {}, highlight = false, indent = false })
	starts = {}
	install_calls = {}
	install_task = nil
end

local function starts_for(buf)
	local result = {}
	for _, call in ipairs(starts) do
		if call.buf == buf then
			result[#result + 1] = call.lang
		end
	end
	return result
end

test("starts installed parsers for already-loaded editor buffers", function()
	reset_runtime()
	local buf = make_buffer(".lua", "return true", "lua")
	installed = { "lua" }
	runtime.setup({ parsers = { "lua" }, highlight = true, indent = true })

	equal({ "lua" }, starts_for(buf), "already-loaded Lua buffer was not started exactly once")
	equal(
		"v:lua.require'nvim-treesitter'.indentexpr()",
		vim.bo[buf].indentexpr,
		"editor Tree-sitter indentation was not enabled"
	)
end)

test("skips buffers larger than 200 KiB", function()
	reset_runtime()
	local buf = make_buffer(".lua", string.rep("x", 200 * 1024 + 1), "lua")
	installed = { "lua" }
	runtime.setup({ parsers = { "lua" }, highlight = true, indent = true })

	equal({}, starts_for(buf), "oversized buffer unexpectedly started Tree-sitter")
	equal("", vim.bo[buf].indentexpr, "oversized buffer unexpectedly enabled Tree-sitter indentation")
end)

test("starts only configured parsers that are installed", function()
	reset_runtime()
	local missing = make_buffer(".py", "print('missing')", "python")
	local excluded = make_buffer(".json", "{}", "json")
	installed = { "json" }
	runtime.setup({ parsers = { "python" }, highlight = true, indent = true })

	equal({}, starts_for(missing), "missing Python parser was started")
	equal({}, starts_for(excluded), "installed but unconfigured JSON parser was started")
end)

test("pager-style profile highlights without changing indentation", function()
	reset_runtime()
	local buf = make_buffer(".md", "# pager", "markdown")
	installed = { "markdown" }
	vim.bo[buf].indentexpr = ""
	runtime.setup({ parsers = { "markdown" }, highlight = true, indent = false })

	equal({ "markdown" }, starts_for(buf), "pager buffer was not highlighted with its installed parser")
	equal("", vim.bo[buf].indentexpr, "pager profile changed indentation")
end)

test("VSCode-style profile exposes parsers without starting highlighting", function()
	reset_runtime()
	local buf = make_buffer(".lua", "return 'vscode'", "lua")
	installed = { "lua" }
	runtime.setup({ parsers = { "lua" }, highlight = false, indent = false })

	equal({}, starts_for(buf), "VSCode-style profile started Tree-sitter highlighting")
	equal(
		{},
		vim.api.nvim_get_autocmds({ group = "NvimConfigTreesitter", event = "FileType" }),
		"VSCode-style profile registered a highlighting lifecycle"
	)
	assert(vim.fn.exists(":NvimConfigParsersInstall") == 2, "explicit parser install command is missing")
end)

test("async install awaits completion and retries eligible buffers", function()
	reset_runtime()
	local buf = make_buffer(".lua", "return 'retry'", "lua")
	installed = {}
	runtime.setup({ parsers = { "lua" }, highlight = true, indent = true })
	equal({}, starts_for(buf), "buffer started before its parser was installed")

	local completion
	install_task = {
		await = function(_, callback)
			completion = callback
		end,
		wait = function()
			return true
		end,
	}
	local ok, task = runtime.install()
	assert(ok and task == install_task, "async install did not return its Task")
	equal({ "lua" }, install_calls[1].parsers, "async install used the wrong parser set")
	assert(completion, "async install did not register Task:await")

	installed = { "lua" }
	completion(nil, true)
	assert(
		vim.wait(1000, function()
			return #starts_for(buf) == 1
		end, 10),
		"install completion did not retry the loaded buffer"
	)
	equal({ "lua" }, starts_for(buf), "install completion retried the buffer more than once")
end)

test("blocking install API honors timeout and returns the Task result", function()
	reset_runtime()
	runtime.setup({ parsers = { "lua" }, highlight = false, indent = false })
	local received_timeout
	install_task = {
		await = function() end,
		wait = function(_, timeout)
			received_timeout = timeout
			return true
		end,
	}

	local ok, task = runtime.install(nil, { wait = true, timeout = 1234, summary = false })
	assert(ok and task == install_task, "blocking install did not return success and its Task")
	equal(1234, received_timeout, "blocking install did not forward its timeout")
	equal(false, install_calls[1].opts.summary, "blocking install did not forward its summary option")
end)

test("editor parser manifest is exactly 19 languages and keeps Rust", function()
	reset_runtime()
	installed = {}
	local specs = require("plugins.treesitter")
	assert(specs[1].build == ":TSUpdate", "Tree-sitter build hook drifted")
	specs[1].config()
	local ok = runtime.install(nil, { wait = true, summary = false })
	assert(ok, "configured parser manifest could not be inspected")
	equal({
		"bash",
		"c",
		"cmake",
		"cpp",
		"javascript",
		"json",
		"lua",
		"markdown",
		"markdown_inline",
		"python",
		"query",
		"rust",
		"toml",
		"tsx",
		"typescript",
		"vim",
		"vimdoc",
		"xml",
		"yaml",
	}, install_calls[1].parsers, "editor parser manifest drifted")
end)

test("editor and pager plugin specs never install parsers implicitly", function()
	reset_runtime()
	installed = {}
	local specs = require("plugins.treesitter")
	specs[1].config()
	equal({}, install_calls, "editor Tree-sitter config installed parsers during startup")

	local pager_specs = require("config.pager").specs()
	local pager_treesitter
	for _, spec in ipairs(pager_specs) do
		if spec[1] == "nvim-treesitter/nvim-treesitter" then
			pager_treesitter = spec
			break
		end
	end
	assert(pager_treesitter, "pager Tree-sitter spec was not found")
	pager_treesitter.config()
	equal({}, install_calls, "pager Tree-sitter config installed parsers during startup")

	local previous_vscode = vim.g.vscode
	vim.g.vscode = true
	assert(specs[2].cond == nil, "Tree-sitter textobjects are disabled in VSCode")
	assert(specs[3].cond() == false, "Tree-sitter context is enabled in VSCode")
	assert(specs[4].cond() == false, "rainbow-delimiters is enabled in VSCode")
	vim.g.vscode = previous_vscode
end)

vim.treesitter.start = original_start
vim.treesitter.language.get_lang = original_get_lang
package.loaded["nvim-treesitter"] = nil

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

print(string.format("treesitter_spec: %d tests passed", 9))
vim.cmd("quitall!")
