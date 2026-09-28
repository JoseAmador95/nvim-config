-- Host adapter for the installed-only treesitter-runtime.nvim lifecycle. Parser
-- manifests and the explicit installation command remain configuration policy.
local M = {}

local runtime = require("treesitter_runtime")
local parsers = {}
local policy_observers = {}
local policy_snapshots = {}

local function dispatch_policy(event)
	if event.kind == "buffer_deleted" then
		policy_snapshots[event.buf] = nil
		return
	end
	if event.kind ~= "buffer" or type(event.buf) ~= "number" then
		return
	end
	local current = runtime.policy(event.buf)
	local previous = policy_snapshots[event.buf]
	policy_snapshots[event.buf] = vim.deepcopy(current)
	if previous == nil or previous.eligible == current.eligible then
		return
	end
	local names = vim.tbl_keys(policy_observers)
	table.sort(names)
	for _, name in ipairs(names) do
		pcall(policy_observers[name], vim.deepcopy(current), vim.deepcopy(previous))
	end
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.ERROR, { title = "Tree-sitter" })
end

local function as_list(value)
	if type(value) == "string" then
		return { value }
	end
	local result = {}
	for _, parser in ipairs(value or {}) do
		result[#result + 1] = parser
	end
	return result
end

local function installed_parsers()
	local loaded, treesitter = pcall(require, "nvim-treesitter")
	if not loaded then
		return {}
	end
	local ok, installed = pcall(treesitter.get_installed, "parsers")
	return ok and type(installed) == "table" and installed or {}
end

---Retry automatic attachment after an explicit install or recoverable failure.
---@param buf? integer
---@return boolean
function M.retry(buf)
	return runtime.retry(buf)
end

---Release runtime-owned parser and indentation state.
---@param buf? integer
---@return boolean
function M.teardown(buf)
	local ok = runtime.teardown(buf)
	if ok and buf == nil then
		policy_snapshots = {}
	end
	return ok
end

function M.status(buf)
	return runtime.status(buf)
end

---Return the live, caller-owned policy for a buffer.
---@param buf? integer
---@return table
function M.policy(buf)
	return runtime.policy(buf)
end

---Observe eligibility edges without replaying the current state.
---Registering the same name replaces the prior host observer.
---@param name string
---@param callback? fun(current: table, previous: table)
function M.observe_policy(name, callback)
	assert(type(name) == "string" and name ~= "", "policy observer name must be a non-empty string")
	assert(callback == nil or type(callback) == "function", "policy observer callback must be a function or nil")
	policy_observers[name] = callback
end

function M.effective_config()
	return runtime.effective_config()
end

---@class NvimConfigTreesitterInstallOpts
---@field wait? boolean Wait for the installation task and return its result.
---@field timeout? integer Maximum wait in milliseconds (default 300000).
---@field summary? boolean Show nvim-treesitter's installation summary.
---@field force? boolean Reinstall requested parsers even when present.

---Install configured parsers explicitly through the host plugin API.
---@param requested? string|string[] Defaults to the parsers passed to setup().
---@param opts? NvimConfigTreesitterInstallOpts
---@return boolean success
---@return any task_or_error
function M.install(requested, opts)
	opts = opts or {}
	local selected = as_list(requested or parsers)
	if #selected == 0 then
		return false, "No Tree-sitter parsers are configured"
	end

	local loaded, treesitter = pcall(require, "nvim-treesitter")
	if not loaded then
		return false, tostring(treesitter)
	end
	local ok, task = pcall(treesitter.install, selected, {
		summary = opts.summary ~= false,
		force = opts.force == true,
	})
	if not ok then
		return false, tostring(task)
	end
	if type(task) ~= "table" or type(task.await) ~= "function" or type(task.wait) ~= "function" then
		return false, "nvim-treesitter.install() did not return an async Task"
	end

	if opts.wait then
		local wait_ok, result = pcall(task.wait, task, opts.timeout or 300000)
		if not wait_ok then
			return false, tostring(result)
		end
		if result ~= true then
			return false, "Tree-sitter parser installation did not complete successfully"
		end
		M.retry()
		return true, task
	end

	task:await(function(err, result)
		vim.schedule(function()
			if err then
				notify("Parser installation failed: " .. tostring(err))
			elseif result ~= true then
				notify("Parser installation did not complete successfully")
			else
				M.retry()
			end
		end)
	end)
	return true, task
end

---Return the configured parser allowlist as an immutable copy.
function M.configured()
	return vim.deepcopy(parsers)
end

local function as_set(values)
	local result = {}
	for _, value in ipairs(values or {}) do
		result[value] = true
	end
	return result
end

local function expected_revision(name)
	local ok, definitions = pcall(require, "nvim-treesitter.parsers")
	local entry = ok and definitions[name] or nil
	local revision = entry and entry.install_info and entry.install_info.revision
	return type(revision) == "string" and revision ~= "" and revision or nil
end

local function stable_line(path)
	local before = vim.uv.fs_lstat(path)
	if not before or before.type ~= "file" or before.nlink ~= 1 or before.size > 256 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path, "b", 1)
	local after = vim.uv.fs_lstat(path)
	if
		not ok
		or not after
		or before.dev ~= after.dev
		or before.ino ~= after.ino
		or before.size ~= after.size
		or type(lines[1]) ~= "string"
	then
		return nil
	end
	return lines[1]
end

local function parser_file(name)
	return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "parser", name .. ".so")
end

local function installed_revision(name)
	return stable_line(vim.fs.joinpath(vim.fn.stdpath("data"), "site", "parser-info", name .. ".revision"))
end

M._expected_revision = expected_revision
M._parser_file = parser_file
M._installed_revision = installed_revision

---Inspect exact configured parser revisions without creating directories.
function M.inventory(requested)
	local selected = as_list(requested or parsers)
	local installed = as_set(installed_parsers())
	local selected_set = as_set(selected)
	local required = {}
	local problems = {}
	for _, name in ipairs(selected) do
		local expected = M._expected_revision(name)
		local parser_stat = vim.uv.fs_lstat(M._parser_file(name))
		local actual = installed[name]
				and parser_stat
				and parser_stat.type == "file"
				and parser_stat.nlink == 1
				and M._installed_revision(name)
			or nil
		local exact = expected ~= nil and actual == expected
		required[#required + 1] = {
			name = name,
			expected = expected or vim.NIL,
			actual = actual or vim.NIL,
			exact = exact,
		}
		if not exact then
			local reason = not expected and "unpinned" or not actual and "missing" or "wrong"
			problems[#problems + 1] = name .. ":" .. reason
		end
	end
	table.sort(required, function(left, right)
		return left.name < right.name
	end)
	table.sort(problems)
	local extras = {}
	for name in pairs(installed) do
		if not selected_set[name] then
			extras[#extras + 1] = name
		end
	end
	table.sort(extras)
	return { required = required, exact = #problems == 0, problems = problems, extras = extras }
end

---Reconcile only missing/stale configured parsers after explicit network consent.
function M.provision_exact(opts)
	opts = opts or {}
	local before = M.inventory()
	if before.exact then
		return true, before, false
	end
	if opts.allow_network ~= true then
		return false, "offline", false, before
	end
	local stale = {}
	for _, item in ipairs(before.required) do
		if not item.exact then
			stale[#stale + 1] = item.name
		end
	end
	local installed, install_err = M.install(stale, {
		wait = true,
		timeout = opts.timeout or 300000,
		summary = false,
		force = true,
	})
	if not installed then
		return false, tostring(install_err), true, before
	end
	local after = M.inventory()
	if not after.exact then
		return false, "Tree-sitter parser revisions remain inexact", true, after
	end
	if not vim.deep_equal(before.extras, after.extras) then
		after.exact = false
		after.problems[#after.problems + 1] = "extras-not-preserved"
		return false, "Tree-sitter extras changed", true, after
	end
	return true, after, true
end

---@class NvimConfigTreesitterRuntimeOpts
---@field parsers string[] Parsers this profile may start or explicitly install.
---@field profile? string Runtime profile name.
---@field max_bytes? integer Maximum current buffer content size.
---@field highlight? boolean Enable installed-only highlighting.
---@field indent? boolean Enable nvim-treesitter indentation while eligible.

---Configure one host-owned runtime profile and explicit install command.
---@param opts NvimConfigTreesitterRuntimeOpts
function M.setup(opts)
	opts = opts or {}
	parsers = as_list(assert(opts.parsers, "Tree-sitter parsers are required"))
	local policy = require("config.local_config").plugin("treesitter_runtime", {
		max_bytes = opts.max_bytes or 200 * 1024,
		reevaluate_debounce_ms = 50,
		languages = {},
	})
	runtime.setup({
		profile = opts.profile or "full",
		allowlist = parsers,
		max_bytes = policy.max_bytes,
		reevaluate_debounce_ms = policy.reevaluate_debounce_ms,
		languages = policy.languages,
		highlight = opts.highlight == true,
		indent = opts.indent == true,
		installed = installed_parsers,
		on_state_change = dispatch_policy,
	})

	vim.api.nvim_create_user_command("NvimConfigParsersInstall", function(command)
		local requested = #command.fargs > 0 and command.fargs or nil
		local install_ok, err = M.install(requested)
		if not install_ok then
			notify("Could not start parser installation: " .. tostring(err))
		end
	end, {
		nargs = "*",
		force = true,
		desc = "Install the configured Tree-sitter parsers",
	})
end

return M
