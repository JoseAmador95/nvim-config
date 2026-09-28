local M = {}
local project_settings = require("config.project_settings")

local before_init_wrappers = setmetatable({}, { __mode = "k" })
local root_dir_wrappers = setmetatable({}, { __mode = "k" })
local on_new_config_wrappers = setmetatable({}, { __mode = "k" })

local function warn_once(message)
	vim.notify_once(message, vim.log.levels.WARN, { title = "LSP" })
end

local function setting_values(defaults, file)
	local success, values = pcall(project_settings.get_many, defaults, file)
	if not success then
		warn_once("approved project LSP settings could not be read: " .. tostring(values))
		return false, vim.deepcopy(defaults)
	end
	return true, values
end

function M.is_enabled(name, file)
	local key = "lspconfig." .. name
	local ok, values = setting_values({ [key] = {} }, file)
	local server = values[key]
	return not ok or server ~= false
end

local function merge_settings(name, config, file)
	local server_key = "lspconfig." .. name
	local ok, values = setting_values({ vscode = {}, [server_key] = {} }, file or config.root_dir)
	if not ok then
		return false
	end
	local vscode = values.vscode
	local server = values[server_key]

	if config.original_settings == nil then
		config.original_settings = vim.deepcopy(config.settings or {})
	end
	local baseline = vim.deepcopy(config.original_settings)
	local settings = config.settings or {}
	if server == false then
		for key in pairs(settings) do
			settings[key] = nil
		end
		for key, value in pairs(baseline) do
			settings[key] = value
		end
		config.settings = settings
		return false
	end
	local merged = vim.tbl_deep_extend(
		"force",
		{},
		baseline,
		type(vscode) == "table" and vscode or {},
		type(server) == "table" and server or {}
	)
	for key in pairs(settings) do
		settings[key] = nil
	end
	for key, value in pairs(merged) do
		settings[key] = value
	end
	config.settings = settings
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
