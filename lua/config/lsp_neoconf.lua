local M = {}

local before_init_wrappers = setmetatable({}, { __mode = "k" })
local root_dir_wrappers = setmetatable({}, { __mode = "k" })
local on_new_config_wrappers = setmetatable({}, { __mode = "k" })

local function warn_once(message)
	vim.notify_once(message, vim.log.levels.WARN, { title = "LSP" })
end

local function project_value(key, default, file)
	local ok, neoconf = pcall(require, "neoconf")
	if not ok or type(neoconf.get) ~= "function" then
		warn_once("neoconf public API is unavailable; project LSP settings were not merged")
		return false, default
	end

	local success, value = pcall(neoconf.get, key, default, { file = file })
	if not success then
		warn_once("neoconf could not read project LSP settings: " .. tostring(value))
		return false, default
	end
	return true, value
end

function M.is_enabled(name, file)
	local ok, server = project_value("lspconfig." .. name, {}, file)
	return not ok or server ~= false
end

local function merge_settings(name, config, file)
	local ok_vscode, vscode = project_value("vscode", {}, file or config.root_dir)
	local ok_server, server = project_value("lspconfig." .. name, {}, file or config.root_dir)
	if not ok_vscode or not ok_server then
		return false
	end

	if config.original_settings == nil then
		config.original_settings = vim.deepcopy(config.settings or {})
	end
	if server == false then
		return false
	end
	config.settings = vim.tbl_deep_extend(
		"force",
		{},
		config.settings or {},
		type(vscode) == "table" and vscode or {},
		type(server) == "table" and server or {}
	)
	return true
end

---@param name string
---@param upstream? fun(params: table, config: table)
function M.wrap_before_init(name, upstream)
	if upstream and before_init_wrappers[upstream] then
		return upstream
	end

	local wrapper = function(params, config)
		merge_settings(name, config)
		if upstream then
			upstream(params, config)
		end
	end
	before_init_wrappers[wrapper] = true
	return wrapper
end

---@param name string
---@param upstream? string|fun(bufnr: integer, on_dir: fun(root_dir?: string))
---@param root_markers? string[]
function M.wrap_root_dir(name, upstream, root_markers)
	if type(upstream) == "function" and root_dir_wrappers[upstream] then
		return upstream
	end

	local wrapper = function(bufnr, on_dir)
		local file = vim.api.nvim_buf_get_name(bufnr)
		if not M.is_enabled(name, file ~= "" and file or vim.fn.getcwd()) then
			return
		end

		if type(upstream) == "function" then
			upstream(bufnr, on_dir)
		elseif type(upstream) == "string" then
			on_dir(upstream)
		else
			on_dir(root_markers and vim.fs.root(bufnr, root_markers) or nil)
		end
	end
	root_dir_wrappers[wrapper] = true
	return wrapper
end

---@param name string
---@param upstream? fun(config: table, root_dir: string)
function M.wrap_on_new_config(name, upstream)
	if upstream and on_new_config_wrappers[upstream] then
		return upstream
	end

	local wrapper = function(config, root_dir)
		if upstream then
			upstream(config, root_dir)
		end
		merge_settings(name, config, root_dir)
	end
	on_new_config_wrappers[wrapper] = true
	return wrapper
end

return M
