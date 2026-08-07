-- Own the nvim-treesitter runtime lifecycle without relying on the plugin's
-- legacy module configuration or on Lazy replaying startup events.
local M = {}

local MAX_FILESIZE = 200 * 1024

local state = {
	parsers = {},
	allowed = {},
	highlight = false,
	indent = false,
}
local attached = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.ERROR, { title = "Tree-sitter" })
end

local function as_list(parsers)
	if type(parsers) == "string" then
		return { parsers }
	end
	local result = {}
	for _, parser in ipairs(parsers or {}) do
		result[#result + 1] = parser
	end
	return result
end

local function as_set(items)
	local result = {}
	for _, item in ipairs(items) do
		result[item] = true
	end
	return result
end

local function installed_parsers()
	local loaded, treesitter = pcall(require, "nvim-treesitter")
	if not loaded then
		return {}
	end
	local ok, parsers = pcall(treesitter.get_installed, "parsers")
	if not ok or type(parsers) ~= "table" then
		return {}
	end
	return as_set(parsers)
end

local function buffer_size(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name ~= "" then
		local stat = vim.uv.fs_stat(name)
		if stat and stat.type == "file" then
			return stat.size
		end
	end

	local ok, size = pcall(vim.api.nvim_buf_get_offset, buf, vim.api.nvim_buf_line_count(buf))
	return ok and size or 0
end

local function buffer_language(buf)
	local ft = vim.bo[buf].filetype
	if ft == "" then
		return nil
	end
	local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
	return (ok and lang) or ft
end

local function set_indent(buf)
	if state.indent then
		vim.bo[buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
	end
end

local function start_buffer(buf, installed)
	if not state.highlight or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
		return false
	end

	local lang = buffer_language(buf)
	if not lang or not state.allowed[lang] or not installed[lang] or buffer_size(buf) > MAX_FILESIZE then
		return false
	end

	if attached[buf] == lang then
		set_indent(buf)
		return true
	end

	local ok = pcall(vim.treesitter.start, buf, lang)
	if not ok then
		return false
	end

	attached[buf] = lang
	set_indent(buf)
	return true
end

---Retry Tree-sitter highlighting for every eligible loaded buffer.
function M.retry()
	if not state.highlight then
		return
	end
	local installed = installed_parsers()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		start_buffer(buf, installed)
	end
end

---@class NvimConfigTreesitterInstallOpts
---@field wait? boolean Wait for the installation task and return its result.
---@field timeout? integer Maximum wait in milliseconds (default 300000).
---@field summary? boolean Show nvim-treesitter's installation summary.

---Install configured parsers explicitly.
---@param parsers? string|string[] Defaults to the parsers passed to setup().
---@param opts? NvimConfigTreesitterInstallOpts
---@return boolean success
---@return any task_or_error
function M.install(parsers, opts)
	opts = opts or {}
	local requested = as_list(parsers or state.parsers)
	if #requested == 0 then
		return false, "No Tree-sitter parsers are configured"
	end

	local loaded, treesitter = pcall(require, "nvim-treesitter")
	if not loaded then
		return false, tostring(treesitter)
	end
	local ok, task = pcall(treesitter.install, requested, {
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
---@field parsers string[] Parsers this profile is allowed to start or install.
---@field highlight? boolean Enable Neovim's Tree-sitter highlighter.
---@field indent? boolean Enable nvim-treesitter's experimental indentation.

---Configure one runtime profile and cover buffers whose FileType already ran.
---@param opts NvimConfigTreesitterRuntimeOpts
function M.setup(opts)
	state.parsers = as_list(assert(opts.parsers, "Tree-sitter parsers are required"))
	state.allowed = as_set(state.parsers)
	state.highlight = opts.highlight == true
	state.indent = opts.indent == true
	attached = {}

	local group = vim.api.nvim_create_augroup("NvimConfigTreesitter", { clear = true })
	if state.highlight then
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			callback = function(args)
				start_buffer(args.buf, installed_parsers())
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			group = group,
			callback = function(args)
				attached[args.buf] = nil
			end,
		})
	end

	vim.api.nvim_create_user_command("NvimConfigParsersInstall", function(command)
		local parsers = #command.fargs > 0 and command.fargs or nil
		local install_ok, err = M.install(parsers)
		if not install_ok then
			notify("Could not start parser installation: " .. tostring(err))
		end
	end, {
		nargs = "*",
		force = true,
		desc = "Install the configured Tree-sitter parsers",
	})

	M.retry()
end

return M
