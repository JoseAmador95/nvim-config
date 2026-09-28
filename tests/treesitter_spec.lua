vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local treesitter_plugin = repo .. "/local-plugins/treesitter-runtime.nvim"
local trusted_plugin = repo .. "/local-plugins/trusted-workspace.nvim"
local shared = repo .. "/local-plugins/_shared"
vim.opt.runtimepath:prepend(treesitter_plugin)
vim.opt.runtimepath:prepend(trusted_plugin)
vim.opt.runtimepath:prepend(shared)
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	treesitter_plugin .. "/lua/?.lua",
	treesitter_plugin .. "/lua/?/init.lua",
	trusted_plugin .. "/lua/?.lua",
	trusted_plugin .. "/lua/?/init.lua",
	shared .. "/lua/?.lua",
	shared .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

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
local stops = {}
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
local original_stop = vim.treesitter.stop
local original_get_lang = vim.treesitter.language.get_lang
vim.treesitter.start = function(buf, lang)
	starts[#starts + 1] = { buf = buf, lang = lang }
	vim.treesitter.highlighter.active[buf] = { language = lang }
end
vim.treesitter.stop = function(buf)
	stops[#stops + 1] = buf
	vim.treesitter.highlighter.active[buf] = nil
end
vim.treesitter.language.get_lang = function(ft)
	return ft
end

local runtime = require("config.treesitter_runtime")
local default_expected_revision = runtime._expected_revision
local default_parser_file = runtime._parser_file
local default_installed_revision = runtime._installed_revision

local function reset_runtime()
	runtime.setup({ parsers = {}, highlight = false, indent = false })
	starts = {}
	stops = {}
	install_calls = {}
	install_task = nil
	runtime._expected_revision = default_expected_revision
	runtime._parser_file = default_parser_file
	runtime._installed_revision = default_installed_revision
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

test("stops an oversized highlighter that predates host setup", function()
	reset_runtime()
	local buf = make_buffer(".lua", string.rep("x", 200 * 1024 + 1), "lua")
	installed = { "lua" }
	vim.treesitter.highlighter.active[buf] = { language = "lua" }
	runtime.setup({ parsers = { "lua" }, highlight = true, indent = true })

	equal({}, starts_for(buf), "oversized pre-existing highlighter was restarted")
	equal({ buf }, stops, "oversized pre-existing highlighter was not stopped")
	local policy = runtime.policy(buf)
	assert(not policy.eligible and policy.reason == "max-bytes-exceeded", "host did not expose live size policy")
end)

test("host observers receive copied live eligibility edges", function()
	reset_runtime()
	local buf = make_buffer(".lua", "tiny", "lua")
	installed = { "lua" }
	local changes = {}
	runtime.setup({ parsers = { "lua" }, highlight = true, indent = true })
	runtime.observe_policy("treesitter-spec", function(current, previous)
		changes[#changes + 1] = { current = current, previous = previous }
	end)
	equal({}, changes, "observer replayed initial policy state")
	local limit = runtime.policy(buf).max_bytes

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", limit + 1) })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	assert(
		vim.wait(1000, function()
			return #changes == 1
		end, 5),
		"growth eligibility edge was not observed"
	)
	assert(changes[1].previous.eligible and not changes[1].current.eligible, "growth edge was reversed")
	changes[1].current.reason = "mutated"
	equal("max-bytes-exceeded", runtime.policy(buf).reason, "observer received shared policy state")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tiny" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	assert(
		vim.wait(1000, function()
			return #changes == 2
		end, 5),
		"shrink eligibility edge was not observed"
	)
	assert(not changes[2].previous.eligible and changes[2].current.eligible, "shrink edge was reversed")
	runtime.observe_policy("treesitter-spec", nil)
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
		vim.api.nvim_get_autocmds({ group = "TreesitterRuntime", event = "FileType" }),
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

test("exact provisioning is offline-safe selective and idempotent", function()
	reset_runtime()
	runtime.setup({ parsers = { "lua" }, highlight = false, indent = false })
	local parser_path = vim.fn.tempname() .. ".so"
	paths[#paths + 1] = parser_path
	assert(vim.fn.writefile({ "parser" }, parser_path, "b") == 0)
	local actual_revision
	runtime._expected_revision = function(name)
		assert(name == "lua")
		return "revision-1"
	end
	runtime._parser_file = function(name)
		assert(name == "lua")
		return parser_path
	end
	runtime._installed_revision = function(name)
		assert(name == "lua")
		return actual_revision
	end
	installed = {}

	local ok, reason, changed, before = runtime.provision_exact({ allow_network = false })
	assert(not ok and reason == "offline" and changed == false)
	assert(before.exact == false and #install_calls == 0, "offline provisioning started an install")

	install_task = {
		await = function() end,
		wait = function(_, timeout)
			assert(timeout == 1234)
			installed = { "lua" }
			actual_revision = "revision-1"
			return true
		end,
	}
	ok, _, changed = runtime.provision_exact({ allow_network = true, timeout = 1234 })
	assert(ok and changed == true)
	equal({ "lua" }, install_calls[1].parsers, "provisioning installed more than the stale parser")
	assert(install_calls[1].opts.force == true and install_calls[1].opts.summary == false)

	local calls = #install_calls
	ok, _, changed = runtime.provision_exact({ allow_network = true, timeout = 1234 })
	assert(ok and changed == false and #install_calls == calls, "exact second run reinstalled a parser")
end)

test("editor parser manifest is exactly 19 languages and keeps Rust", function()
	reset_runtime()
	installed = {}
	local specs = require("plugins.treesitter")
	assert(specs[1].build == nil, "Tree-sitter regained an implicit parser install hook")
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

test("UFO selects from live policy and reselects only attached buffers", function()
	reset_runtime()
	local original_policy = runtime.policy
	local original_observe = runtime.observe_policy
	local original_ufo = package.loaded.ufo
	local eligible = {}
	local observer
	local setup_options
	local attached = {}
	local detach_calls = {}
	local attach_calls = {}
	runtime.policy = function(buf)
		return { buf = buf, eligible = eligible[buf] == true }
	end
	runtime.observe_policy = function(name, callback)
		assert(name == "ufo", "UFO used an unstable policy observer name")
		observer = callback
	end
	package.loaded.ufo = {
		setup = function(options)
			setup_options = options
		end,
		hasAttached = function(buf)
			return attached[buf] == true
		end,
		detach = function(buf)
			detach_calls[#detach_calls + 1] = buf
			attached[buf] = nil
		end,
		attach = function(buf)
			attach_calls[#attach_calls + 1] = buf
			attached[buf] = true
		end,
	}

	local spec = dofile(vim.fs.joinpath(repo, "lua", "plugins", "ufo.lua"))[1]
	spec.config()
	assert(type(observer) == "function", "UFO did not observe runtime policy transitions")
	local buf = vim.api.nvim_get_current_buf()
	eligible[buf] = true
	equal({ "treesitter", "indent" }, setup_options.provider_selector(buf), "eligible UFO provider order changed")
	eligible[buf] = false
	equal({ "indent" }, setup_options.provider_selector(buf), "ineligible UFO buffer retained Tree-sitter")

	attached[buf] = true
	observer({ buf = buf, eligible = false }, { buf = buf, eligible = true })
	equal({ buf }, detach_calls, "UFO did not invalidate its cached provider")
	equal({ buf }, attach_calls, "UFO did not reselect after policy transition")
	detach_calls = {}
	attach_calls = {}
	attached[buf] = nil
	observer({ buf = buf, eligible = true }, { buf = buf, eligible = false })
	equal({}, detach_calls, "UFO touched a manually detached buffer")
	equal({}, attach_calls, "UFO reclaimed a manually detached buffer")

	runtime.policy = original_policy
	runtime.observe_policy = original_observe
	package.loaded.ufo = original_ufo
end)

runtime.teardown()
vim.treesitter.start = original_start
vim.treesitter.stop = original_stop
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

print(string.format("treesitter_spec: %d tests passed", 13))
vim.cmd("quitall!")
