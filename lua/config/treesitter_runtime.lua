-- Host adapter for the installed-only treesitter-runtime.nvim lifecycle. Parser
-- manifests and the explicit installation command remain configuration policy.
local M = {}

local runtime = require("treesitter_runtime")
local parsers = {}

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
	return runtime.teardown(buf)
end

---@class NvimConfigTreesitterInstallOpts
---@field wait? boolean Wait for the installation task and return its result.
---@field timeout? integer Maximum wait in milliseconds (default 300000).
---@field summary? boolean Show nvim-treesitter's installation summary.

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
	runtime.setup({
		profile = opts.profile or "full",
		allowlist = parsers,
		max_bytes = opts.max_bytes,
		highlight = opts.highlight == true,
		indent = opts.indent == true,
		installed = installed_parsers,
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
