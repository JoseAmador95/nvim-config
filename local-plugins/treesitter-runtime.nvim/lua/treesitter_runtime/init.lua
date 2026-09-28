local M = {}

local DEFAULT_MAX_BYTES = 200 * 1024
local DEFAULT_REEVALUATE_DEBOUNCE_MS = 50
local DEFAULT_INDENTEXPR = "v:lua.require'nvim-treesitter'.indentexpr()"
local AUGROUP = "TreesitterRuntime"

local config
local attached = {}
local buffer_status = {}
local pending = {}
local setup_generation = 0

local SETUP_KEYS = {
	profile = true,
	enabled = true,
	allowlist = true,
	max_bytes = true,
	highlight = true,
	indent = true,
	indentexpr = true,
	languages = true,
	reevaluate_debounce_ms = true,
	installed = true,
	start = true,
	stop = true,
	is_started = true,
	language = true,
	buffer_bytes = true,
	defer = true,
	on_state_change = true,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function exact_options(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown option: " .. tostring(key)
		end
	end
	return true
end

local function non_negative_integer(value, label)
	if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
		return nil, label .. " must be a non-negative integer"
	end
	return value
end

local function emit(kind, status)
	if not config or type(config.on_state_change) ~= "function" then
		return
	end
	local event = copy(status or {})
	event.kind = kind
	pcall(config.on_state_change, event)
end

local function record_status(buf, values)
	local status = vim.tbl_extend("force", {
		buf = buf,
		attached = attached[buf] ~= nil,
		reason = "unknown",
	}, values or {})
	local previous = buffer_status[buf]
	buffer_status[buf] = copy(status)
	if not vim.deep_equal(previous, status) then
		emit("buffer", status)
	end
	return status
end

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

local function list_set(value)
	local result = {}
	for _, item in ipairs(value) do
		result[item] = true
	end
	return result
end

local function installed_set(value)
	if type(value) ~= "table" then
		return nil, "installed() must return an array or a string-to-boolean map"
	end
	if vim.islist(value) then
		local installed, installed_err = as_list(value, "installed()")
		if not installed then
			return nil, installed_err
		end
		return list_set(installed)
	end
	local result = {}
	for language, present in pairs(value) do
		if type(language) ~= "string" or language == "" or language:find("\0", 1, true) then
			return nil, "installed() map keys must be non-empty strings without NUL bytes"
		end
		if type(present) ~= "boolean" then
			return nil, "installed() map values must be boolean"
		end
		if present then
			result[language] = true
		end
	end
	return result
end

local function normalize_languages(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or (next(value) ~= nil and vim.islist(value)) then
		return nil, "languages must be a map"
	end
	local result = {}
	for language, override in pairs(value) do
		if type(language) ~= "string" or language == "" or language:find("\0", 1, true) then
			return nil, "languages keys must be non-empty strings without NUL bytes"
		end
		local ok, err = exact_options(override, { max_bytes = true, indent = true }, "languages." .. language)
		if not ok then
			return nil, err
		end
		local normalized = {}
		if override.max_bytes ~= nil then
			local maximum, maximum_err =
				non_negative_integer(override.max_bytes, "languages." .. language .. ".max_bytes")
			if not maximum then
				return nil, maximum_err
			end
			normalized.max_bytes = maximum
		end
		if override.indent ~= nil and type(override.indent) ~= "boolean" then
			return nil, "languages." .. language .. ".indent must be boolean"
		end
		normalized.indent = override.indent
		result[language] = normalized
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
		return nil, "not configured"
	end
	local ok, installed = pcall(config.installed)
	if not ok then
		return nil, "installed() failed: " .. tostring(installed)
	end
	local snapshot, snapshot_err = installed_set(installed)
	if not snapshot then
		return nil, snapshot_err
	end
	config.installed_set = snapshot
	return snapshot
end

local function parser_is_started(buf, language)
	local ok, started = pcall(config.is_started, buf, language)
	if not ok or type(started) ~= "boolean" then
		return nil
	end
	return started
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

local function ensure_indent(buf, record, enabled)
	if not enabled then
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

local function stop_managed_parser(buf, record)
	if not record.parser_managed then
		return true
	end
	local ok, result = pcall(record.stop, buf, record.language)
	if not ok or result == false then
		return false
	end
	record.parser_managed = false
	return true
end

local function detach(buf)
	local record = attached[buf]
	if not record then
		return true
	end
	if not stop_managed_parser(buf, record) then
		return false
	end
	restore_indent(buf, record)
	attached[buf] = nil
	return true
end

local function current_policy(buf, selected)
	selected = selected or config
	local policy = {
		buf = buf,
		eligible = false,
		reason = "unknown",
	}
	if not selected then
		policy.reason = "not-configured"
		return policy
	end
	if not selected.enabled then
		policy.reason = "disabled"
		return policy
	end
	if not selected.highlight then
		policy.reason = "highlight-disabled"
		return policy
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		policy.reason = "invalid-buffer"
		return policy
	end
	if not vim.api.nvim_buf_is_loaded(buf) then
		policy.reason = "unloaded-buffer"
		return policy
	end
	local ok, language = pcall(selected.language, buf)
	if not ok then
		policy.reason = "language-error"
		return policy
	end
	if type(language) ~= "string" or language == "" then
		policy.reason = "no-language"
		return policy
	end
	policy.language = language
	local size_ok, bytes = pcall(selected.buffer_bytes, buf)
	if not size_ok or type(bytes) ~= "number" or bytes < 0 then
		policy.reason = "size-unavailable"
		return policy
	end
	local override = selected.languages[language] or {}
	local max_bytes = override.max_bytes or selected.max_bytes
	local indent = override.indent
	if indent == nil then
		indent = selected.indent
	end
	policy.bytes = bytes
	policy.max_bytes = max_bytes
	policy.indent = indent
	if not selected.allowed[language] then
		policy.reason = "not-allowlisted"
		return policy
	end
	if not selected.installed_set[language] then
		policy.reason = "parser-not-installed"
		return policy
	end
	if bytes > max_bytes then
		policy.reason = "max-bytes-exceeded"
		return policy
	end
	policy.eligible = true
	policy.reason = "eligible"
	return policy
end

local evaluate

local function detach_for_reconfiguration(next_config)
	local impacted = {}
	for buf, record in pairs(attached) do
		local policy = current_policy(buf, next_config)
		if not policy.eligible or policy.language ~= record.language then
			impacted[#impacted + 1] = buf
		end
	end
	table.sort(impacted)
	local detached = {}
	for _, buf in ipairs(impacted) do
		if not detach(buf) then
			for _, prior in ipairs(detached) do
				evaluate(prior)
			end
			return nil, "could not stop parser for buffer " .. tostring(buf)
		end
		detached[#detached + 1] = buf
	end
	return true
end

local function stop_ineligible_highlighter(buf, policy)
	if policy.bytes == nil or policy.max_bytes == nil or policy.bytes <= policy.max_bytes then
		return true
	end
	local started = parser_is_started(buf, policy.language)
	if started == nil then
		return false, "parser-state-error"
	end
	if not started then
		return true
	end
	local ok, result = pcall(config.stop, buf, policy.language)
	if not ok or result == false then
		return false, "stop-failed"
	end
	return true
end

evaluate = function(buf)
	local policy = current_policy(buf)
	local record = attached[buf]
	if not policy.eligible then
		local detached = detach(buf)
		local stopped, stop_reason = true, nil
		if detached then
			stopped, stop_reason = stop_ineligible_highlighter(buf, policy)
		end
		record_status(buf, {
			attached = attached[buf] ~= nil,
			eligible = false,
			language = policy.language,
			reason = not detached and "stop-failed" or not stopped and stop_reason or policy.reason,
			bytes = policy.bytes,
			max_bytes = policy.max_bytes,
			indent = policy.indent,
		})
		return false
	end

	if record and record.language ~= policy.language then
		if not detach(buf) then
			record_status(buf, { attached = true, language = record.language, reason = "stop-failed" })
			return false
		end
		record = nil
	end
	if record then
		local started = parser_is_started(buf, policy.language)
		if started == nil then
			record_status(buf, { attached = true, language = policy.language, reason = "parser-state-error" })
			return false
		end
		if not started then
			record.parser_managed = false
			local ok, result = pcall(config.start, buf, policy.language)
			if not ok or result == false then
				if record.indent_owned and current_indentexpr(buf) ~= record.indent_value then
					record.indent_external = true
				end
				restore_indent(buf, record)
				record_status(buf, { attached = true, language = policy.language, reason = "start-failed" })
				return false
			end
			record.parser_managed = true
		end
	end

	if not record then
		local preexisting = parser_is_started(buf, policy.language)
		if preexisting == nil then
			record_status(buf, { attached = false, language = policy.language, reason = "parser-state-error" })
			return false
		end
		record = {
			language = policy.language,
			parser_managed = false,
			stop = config.stop,
			indent_owned = false,
			indent_external = false,
		}
		if not preexisting then
			local ok, result = pcall(config.start, buf, policy.language)
			if not ok or result == false then
				record_status(buf, { attached = false, language = policy.language, reason = "start-failed" })
				return false
			end
		end
		record.parser_managed = true
		attached[buf] = record
	end
	ensure_indent(buf, record, policy.indent)
	record_status(buf, {
		attached = true,
		eligible = true,
		language = policy.language,
		reason = "attached",
		bytes = policy.bytes,
		max_bytes = policy.max_bytes,
		indent = policy.indent,
	})
	return true
end

local function schedule_evaluate(buf)
	if not config then
		return
	end
	local generation = setup_generation
	local token = (pending[buf] or 0) + 1
	pending[buf] = token
	local callback = function()
		if config and setup_generation == generation and pending[buf] == token then
			pending[buf] = nil
			evaluate(buf)
		end
	end
	local ok = pcall(config.defer, callback, config.reevaluate_debounce_ms)
	if not ok then
		pending[buf] = nil
		evaluate(buf)
	end
end

local function register_autocmds()
	local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		callback = function(args)
			pending[args.buf] = nil
			attached[args.buf] = nil
			buffer_status[args.buf] = nil
			emit("buffer_deleted", { buf = args.buf })
		end,
	})
	if not config.enabled or not config.highlight then
		return
	end
	vim.api.nvim_create_autocmd({ "BufEnter", "BufNewFile", "BufReadPost", "FileType" }, {
		group = group,
		callback = function(args)
			evaluate(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		callback = function(args)
			schedule_evaluate(args.buf)
		end,
	})
end

---Configure an installed-only Tree-sitter runtime profile.
---@param opts table
---@return table
function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	local options_ok, options_err = exact_options(opts, SETUP_KEYS, "setup")
	if not options_ok then
		error(options_err)
	end
	local allowlist, allowlist_err = as_list(opts.allowlist, "allowlist")
	if not allowlist then
		error(allowlist_err)
	end
	if type(opts.installed) ~= "function" then
		error("treesitter_runtime.setup requires installed()")
	end
	local maximum = opts.max_bytes
	if maximum == nil then
		maximum = DEFAULT_MAX_BYTES
	end
	local max_bytes, max_bytes_err = non_negative_integer(maximum, "max_bytes")
	if not max_bytes then
		error(max_bytes_err)
	end
	local debounce_value = opts.reevaluate_debounce_ms
	if debounce_value == nil then
		debounce_value = DEFAULT_REEVALUATE_DEBOUNCE_MS
	end
	local debounce, debounce_err = non_negative_integer(debounce_value, "reevaluate_debounce_ms")
	if not debounce then
		error(debounce_err)
	end
	local languages, languages_err = normalize_languages(opts.languages)
	if not languages then
		error(languages_err)
	end
	local profile = opts.profile
	if profile == nil then
		profile = "default"
	end
	if type(profile) ~= "string" or profile == "" then
		error("profile must be a non-empty string")
	end
	for _, name in ipairs({ "start", "stop", "is_started", "language", "buffer_bytes", "defer", "on_state_change" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "function" then
			error(name .. " must be a function")
		end
	end
	if opts.indentexpr ~= nil and (type(opts.indentexpr) ~= "string" or opts.indentexpr == "") then
		error("indentexpr must be a non-empty string")
	end
	for _, name in ipairs({ "enabled", "highlight", "indent" }) do
		if opts[name] ~= nil and type(opts[name]) ~= "boolean" then
			error(name .. " must be boolean")
		end
	end

	local next_config = {
		profile = profile,
		enabled = opts.enabled ~= false,
		allowlist = allowlist,
		allowed = list_set(allowlist),
		max_bytes = max_bytes,
		languages = languages,
		reevaluate_debounce_ms = debounce,
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
		defer = opts.defer or vim.defer_fn,
		on_state_change = opts.on_state_change,
	}
	local installed_ok, installed = pcall(opts.installed)
	if not installed_ok then
		error("installed() failed: " .. tostring(installed))
	end
	local snapshot, snapshot_err = installed_set(installed)
	if not snapshot then
		error(snapshot_err)
	end
	next_config.installed_set = snapshot
	if config then
		local detached, detach_err = detach_for_reconfiguration(next_config)
		if not detached then
			error("treesitter_runtime.setup could not reconfigure: " .. tostring(detach_err))
		end
	end
	config = next_config
	setup_generation = setup_generation + 1
	pending = {}
	register_autocmds()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		evaluate(buf)
	end
	return M
end

---Return caller-owned non-callback configuration.
---@return table|nil
function M.effective_config()
	if not config then
		return {
			profile = "default",
			enabled = true,
			allowlist = {},
			max_bytes = DEFAULT_MAX_BYTES,
			highlight = false,
			indent = false,
			indentexpr = DEFAULT_INDENTEXPR,
			languages = {},
			reevaluate_debounce_ms = DEFAULT_REEVALUATE_DEBOUNCE_MS,
		}
	end
	return copy({
		profile = config.profile,
		enabled = config.enabled,
		allowlist = config.allowlist,
		max_bytes = config.max_bytes,
		highlight = config.highlight,
		indent = config.indent,
		indentexpr = config.indentexpr,
		languages = config.languages,
		reevaluate_debounce_ms = config.reevaluate_debounce_ms,
	})
end

---Return the current caller-owned eligibility policy for one buffer.
---This query never starts or stops a parser and does not update runtime state.
---@param buf? integer
---@return table
function M.policy(buf)
	local selected = buf
	if selected == nil or selected == 0 then
		selected = vim.api.nvim_get_current_buf()
	end
	return copy(current_policy(selected))
end

---Return a caller-owned, side-effect-free buffer status snapshot.
---@param buf? integer
---@return table
function M.status(buf)
	if buf == nil then
		local buffers = {}
		local ids = vim.tbl_keys(buffer_status)
		table.sort(ids)
		for _, id in ipairs(ids) do
			buffers[#buffers + 1] = copy(buffer_status[id])
		end
		return { configured = config ~= nil, buffers = buffers }
	end
	local selected = buf == 0 and vim.api.nvim_get_current_buf() or buf
	if buffer_status[selected] then
		return copy(buffer_status[selected])
	end
	return {
		buf = selected,
		attached = attached[selected] ~= nil,
		reason = config and "not-evaluated" or "not-configured",
	}
end

---Retry attachment after an explicit parser install or recoverable failure.
---@param buf? integer
---@return boolean
function M.retry(buf)
	if not config then
		return false
	end
	if not refresh_installed() then
		return false
	end
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
		pending[buf] = nil
		local ok = detach(buf)
		record_status(buf, { attached = attached[buf] ~= nil, reason = ok and "torn-down" or "stop-failed" })
		return ok
	end
	setup_generation = setup_generation + 1
	pending = {}
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
	buffer_status = {}
	return complete
end

return M
