local M = {}

local DEFAULT_MAX_BYTES = 200 * 1024
local DEFAULT_INDENTEXPR = "v:lua.require'nvim-treesitter'.indentexpr()"
local AUGROUP = "TreesitterRuntime"

local config
local attached = {}

local function as_list(value, label)
	if type(value) ~= "table" or not vim.islist(value) then
		return nil, label .. " must be an array"
	end
	local result = {}
	local seen = {}
	for index, item in ipairs(value) do
		if type(item) ~= "string" or item == "" or item:find("\0", 1, true) then
			return nil, ("%s[%d] must be a non-empty string without NUL bytes"):format(label, index)
		end
		if not seen[item] then
			result[#result + 1] = item
			seen[item] = true
		end
	end
	return result
end

local function as_set(value)
	local result = {}
	if type(value) ~= "table" then
		return result
	end
	if vim.islist(value) then
		for _, item in ipairs(value) do
			if type(item) == "string" and item ~= "" then
				result[item] = true
			end
		end
		return result
	end
	for item, installed in pairs(value) do
		if type(item) == "string" and installed == true then
			result[item] = true
		end
	end
	return result
end

local function default_buffer_bytes(buf)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local ok, offset = pcall(vim.api.nvim_buf_get_offset, buf, line_count)
	if ok and type(offset) == "number" and offset >= 0 then
		return offset
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local bytes = math.max(#lines - 1, 0)
	for _, line in ipairs(lines) do
		bytes = bytes + #line
	end
	return bytes
end

local function default_language(buf)
	local filetype = vim.bo[buf].filetype
	if filetype == "" then
		return nil
	end
	local ok, language = pcall(vim.treesitter.language.get_lang, filetype)
	return ok and language or filetype
end

local function default_is_started(buf)
	return vim.treesitter.highlighter
			and vim.treesitter.highlighter.active
			and vim.treesitter.highlighter.active[buf] ~= nil
		or false
end

local function default_start(buf, language)
	return vim.treesitter.start(buf, language)
end

local function default_stop(buf)
	return vim.treesitter.stop(buf)
end

local function current_indentexpr(buf)
	local ok, value = pcall(vim.api.nvim_get_option_value, "indentexpr", { buf = buf })
	return ok and value or nil
end

local function set_indentexpr(buf, value)
	return pcall(vim.api.nvim_set_option_value, "indentexpr", value, { buf = buf })
end

local function refresh_installed()
	if not config then
		return {}
	end
	local ok, installed = pcall(config.installed)
	config.installed_set = ok and as_set(installed) or {}
	return config.installed_set
end

local function parser_is_started(buf, language)
	local ok, started = pcall(config.is_started, buf, language)
	return ok and started == true
end

local function restore_indent(buf, record)
	if not record.indent_owned then
		return
	end
	if vim.api.nvim_buf_is_valid(buf) and current_indentexpr(buf) == record.indent_value then
		set_indentexpr(buf, record.prior_indentexpr)
	end
	record.indent_owned = false
	record.indent_value = nil
	record.prior_indentexpr = nil
end

local function ensure_indent(buf, record)
	if not config.indent then
		restore_indent(buf, record)
		record.indent_external = false
		return
	end
	local current = current_indentexpr(buf)
	if current == nil then
		return
	end
	if record.indent_owned then
		if current ~= record.indent_value then
			record.indent_owned = false
			record.indent_value = nil
			record.prior_indentexpr = nil
			record.indent_external = true
			return
		end
		if current ~= config.indentexpr and set_indentexpr(buf, config.indentexpr) then
			record.indent_value = config.indentexpr
		end
		return
	end
	if record.indent_external or current == config.indentexpr then
		record.indent_external = true
		return
	end
	local prior = current
	if set_indentexpr(buf, config.indentexpr) then
		record.prior_indentexpr = prior
		record.indent_value = config.indentexpr
		record.indent_owned = true
	end
end

local function stop_owned_parser(buf, record)
	if not record.parser_owned then
		return true
	end
	local ok, result = pcall(record.stop, buf, record.language)
	if not ok or result == false then
		return false
	end
	record.parser_owned = false
	return true
end

local function detach(buf)
	local record = attached[buf]
	if not record then
		return true
	end
	restore_indent(buf, record)
	if not stop_owned_parser(buf, record) then
		return false
	end
	attached[buf] = nil
	return true
end

local function eligible(buf)
	if
		not config
		or not config.enabled
		or not config.highlight
		or not vim.api.nvim_buf_is_valid(buf)
		or not vim.api.nvim_buf_is_loaded(buf)
	then
		return false
	end
	local ok, language = pcall(config.language, buf)
	if not ok or type(language) ~= "string" or language == "" then
		return false
	end
	if not config.allowed[language] or not config.installed_set[language] then
		return false, language
	end
	local size_ok, bytes = pcall(config.buffer_bytes, buf)
	if not size_ok or type(bytes) ~= "number" or bytes < 0 or bytes > config.max_bytes then
		return false, language
	end
	return true, language
end

local function evaluate(buf)
	local is_eligible, language = eligible(buf)
	local record = attached[buf]
	if not is_eligible then
		detach(buf)
		return false
	end

	if record and record.language ~= language then
		if not detach(buf) then
			return false
		end
		record = nil
	end

	if not record then
		local preexisting = parser_is_started(buf, language)
		record = {
			language = language,
			parser_owned = false,
			stop = config.stop,
			indent_owned = false,
			indent_external = false,
		}
		if not preexisting then
			local ok, result = pcall(config.start, buf, language)
			if not ok or result == false then
				return false
			end
			record.parser_owned = true
		end
		attached[buf] = record
	end
	ensure_indent(buf, record)
	return true
end

local function register_autocmds()
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
	if not config.enabled or not config.highlight then
		return
	end
	vim.api.nvim_create_autocmd(
		{ "BufEnter", "BufNewFile", "BufReadPost", "FileType", "TextChanged", "TextChangedI" },
		{
			group = group,
			callback = function(args)
				evaluate(args.buf)
			end,
		}
	)
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			attached[args.buf] = nil
		end,
	})
end

---Configure an installed-only Tree-sitter runtime profile.
---@param opts table
---@return table
function M.setup(opts)
	opts = opts or {}
	local allowlist, allowlist_err = as_list(opts.allowlist, "allowlist")
	if not allowlist then
		error(allowlist_err)
	end
	if type(opts.installed) ~= "function" then
		error("treesitter_runtime.setup requires installed()")
	end
	local max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES
	if type(max_bytes) ~= "number" or max_bytes < 0 or max_bytes % 1 ~= 0 then
		error("max_bytes must be a non-negative integer")
	end
	local profile = opts.profile or "default"
	if type(profile) ~= "string" or profile == "" then
		error("profile must be a non-empty string")
	end

	config = {
		profile = profile,
		enabled = opts.enabled ~= false,
		allowlist = allowlist,
		allowed = as_set(allowlist),
		max_bytes = max_bytes,
		highlight = opts.highlight == true,
		indent = opts.indent == true,
		indentexpr = opts.indentexpr or DEFAULT_INDENTEXPR,
		installed = opts.installed,
		installed_set = {},
		start = opts.start or default_start,
		stop = opts.stop or default_stop,
		is_started = opts.is_started or default_is_started,
		language = opts.language or default_language,
		buffer_bytes = opts.buffer_bytes or default_buffer_bytes,
	}
	refresh_installed()
	register_autocmds()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		evaluate(buf)
	end
	return M
end

---Retry attachment after an explicit parser install or recoverable failure.
---@param buf? integer
---@return boolean
function M.retry(buf)
	if not config then
		return false
	end
	refresh_installed()
	if buf ~= nil then
		return evaluate(buf)
	end
	for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
		evaluate(candidate)
	end
	return true
end

---Release plugin-owned state for one buffer or the complete runtime profile.
---@param buf? integer
---@return boolean
function M.teardown(buf)
	if buf ~= nil then
		return detach(buf)
	end
	local complete = true
	local buffers = {}
	for candidate in pairs(attached) do
		buffers[#buffers + 1] = candidate
	end
	for _, candidate in ipairs(buffers) do
		complete = detach(candidate) and complete
	end
	pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
	config = nil
	return complete
end

return M
