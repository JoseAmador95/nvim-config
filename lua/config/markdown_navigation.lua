local editor = require("config.editor")
local pager = require("config.pager")
local clipboard = require("config.clipboard")

local M = {}

local TITLE = "Markdown"
local MAX_BARE_LINE_BYTES = 8192
local MAX_BARE_TARGET_BYTES = 2048
local MAX_DESTINATION_BYTES = 2048
local MAX_ENTITY_REFERENCES = 64
local MAX_ENTITY_NAME_BYTES = 32
local MAX_NUMERIC_ENTITY_DIGITS = 8
local MAX_NODE_VISITS = 128
local REFERENCE_NODES = {
	collapsed_reference_link = true,
	full_reference_link = true,
	shortcut_link = true,
}
local ESCAPABLE_ASCII = {}
for byte = 0x21, 0x2f do
	ESCAPABLE_ASCII[string.char(byte)] = true
end
for byte = 0x3a, 0x40 do
	ESCAPABLE_ASCII[string.char(byte)] = true
end
for byte = 0x5b, 0x60 do
	ESCAPABLE_ASCII[string.char(byte)] = true
end
for byte = 0x7b, 0x7e do
	ESCAPABLE_ASCII[string.char(byte)] = true
end
local NAMED_ENTITIES = {
	amp = "&",
	apos = "'",
	gt = ">",
	lt = "<",
	quot = '"',
}
local TRAILING_PUNCTUATION = {
	["!"] = true,
	[","] = true,
	["."] = true,
	[":"] = true,
	[";"] = true,
	["?"] = true,
}
local TRAILING_DELIMITERS = {
	[")"] = "(",
	["]"] = "[",
	["}"] = "{",
}

local configured
local owned_mappings = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = TITLE })
end

local function profile_enabled()
	return not vim.g.vscode and not pager.active
end

local function node_text(node, bufnr)
	local ok, value = pcall(vim.treesitter.get_node_text, node, bufnr)
	return ok and type(value) == "string" and value or nil
end

local function strip_angles(value)
	if value and value:sub(1, 1) == "<" and value:sub(-1) == ">" then
		return value:sub(2, -2)
	end
	return value
end

local function scalar_character(value)
	if
		value == 0
		or value > 0x10ffff
		or (value >= 0xd800 and value <= 0xdfff)
		or value < 0x20
		or (value >= 0x7f and value <= 0x9f)
	then
		return nil
	end
	local ok, character = pcall(vim.fn.nr2char, value)
	return ok and type(character) == "string" and character ~= "" and character or nil
end

local function decode_entity(value, index)
	local suffix = value:sub(index)
	local hex = suffix:match("^&#[xX]([%da-fA-F]+);")
	if hex then
		if #hex > MAX_NUMERIC_ENTITY_DIGITS then
			return nil, nil, "numeric character reference is too long"
		end
		local character = scalar_character(tonumber(hex, 16))
		if not character then
			return nil, nil, "numeric character reference is not a Unicode scalar"
		end
		return character, #hex + 4
	end
	local decimal = suffix:match("^&#(%d+);")
	if decimal then
		if #decimal > MAX_NUMERIC_ENTITY_DIGITS then
			return nil, nil, "numeric character reference is too long"
		end
		local character = scalar_character(tonumber(decimal, 10))
		if not character then
			return nil, nil, "numeric character reference is not a Unicode scalar"
		end
		return character, #decimal + 3
	end
	local name = suffix:match("^&([%a][%w]+);")
	if not name then
		return nil
	end
	if #name > MAX_ENTITY_NAME_BYTES then
		return nil, nil, "named character reference is too long"
	end
	local character = NAMED_ENTITIES[name]
	if not character then
		return nil, nil, "unsupported named character reference: &" .. name .. ";"
	end
	return character, #name + 2
end

local function decode_destination(value)
	value = strip_angles(value)
	if type(value) ~= "string" then
		return nil, "could not read link destination", false
	end
	if #value > MAX_DESTINATION_BYTES then
		return nil, ("link destination exceeds %d bytes"):format(MAX_DESTINATION_BYTES), false
	end
	local decoded = {}
	local index = 1
	local entities = 0
	local fragment = false
	while index <= #value do
		local character = value:sub(index, index)
		if character == "\\" then
			local escaped = value:sub(index + 1, index + 1)
			if ESCAPABLE_ASCII[escaped] then
				decoded[#decoded + 1] = escaped
				index = index + 2
			else
				decoded[#decoded + 1] = character
				index = index + 1
			end
		elseif character == "&" then
			local entity, length, err = decode_entity(value, index)
			if err then
				return nil, err, false
			elseif entity then
				entities = entities + 1
				if entities > MAX_ENTITY_REFERENCES then
					return nil,
						("link destination exceeds %d character references"):format(MAX_ENTITY_REFERENCES),
						false
				end
				decoded[#decoded + 1] = entity
				index = index + length
			else
				decoded[#decoded + 1] = character
				index = index + 1
			end
		else
			if character == "#" then
				fragment = true
			end
			decoded[#decoded + 1] = character
			index = index + 1
		end
	end
	return table.concat(decoded), nil, fragment
end

local function destination_target(value, decode)
	local normalized, err, fragment
	if decode then
		normalized, err, fragment = decode_destination(value)
	else
		normalized = strip_angles(value)
		if type(normalized) == "string" and #normalized > MAX_DESTINATION_BYTES then
			err = ("link destination exceeds %d bytes"):format(MAX_DESTINATION_BYTES)
			normalized = nil
		else
			fragment = type(normalized) == "string" and normalized:find("#", 1, true) ~= nil
		end
	end
	return { kind = "destination", value = normalized, error = err, fragment = fragment }
end

local function find_descendant(node, wanted)
	local visits = 0
	local function visit(current)
		visits = visits + 1
		if visits > MAX_NODE_VISITS then
			return nil
		end
		if wanted[current:type()] then
			return current
		end
		for child in current:iter_children() do
			local found = visit(child)
			if found then
				return found
			end
		end
	end
	return visit(node)
end

local function target_from_node(node, bufnr)
	while node do
		local kind = node:type()
		if kind == "uri_autolink" then
			return destination_target(node_text(node, bufnr), false)
		end
		if kind == "email_autolink" then
			local value = strip_angles(node_text(node, bufnr))
			return value and destination_target("mailto:" .. value, false) or nil
		end
		if kind == "link_destination" then
			return destination_target(node_text(node, bufnr), true)
		end
		if kind == "inline_link" or kind == "image" then
			local destination = find_descendant(node, { link_destination = true })
			return destination and destination_target(node_text(destination, bufnr), true) or nil
		end
		if REFERENCE_NODES[kind] then
			return { kind = "reference", value = node_text(node, bufnr) }
		end
		node = node:parent()
	end
end

local function treesitter_target(bufnr, row, byte_column)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown", { error = false })
	if not ok or not parser then
		return nil
	end
	local parsed = pcall(parser.parse, parser, { row, byte_column, row, byte_column + 1 })
	if not parsed then
		return nil
	end

	local target
	local iterated = pcall(parser.for_each_tree, parser, function(tree, language_tree)
		if target or language_tree:lang() ~= "markdown_inline" then
			return
		end
		local root = tree:root()
		local node = root:named_descendant_for_range(row, byte_column, row, byte_column)
		if node then
			target = target_from_node(node, bufnr)
		end
	end)
	return iterated and target or nil
end

local function trim_bare_target(line, first, last)
	local counts = {}
	for delimiter, opening in pairs(TRAILING_DELIMITERS) do
		counts[delimiter] = 0
		counts[opening] = 0
	end
	for index = first, last do
		local character = line:sub(index, index)
		if counts[character] ~= nil then
			counts[character] = counts[character] + 1
		end
	end
	while last >= first do
		local character = line:sub(last, last)
		local opening = TRAILING_DELIMITERS[character]
		if TRAILING_PUNCTUATION[character] then
			last = last - 1
		elseif opening and counts[character] > counts[opening] then
			counts[character] = counts[character] - 1
			last = last - 1
		else
			break
		end
	end
	return last
end

local function bare_target(line, byte_column)
	if #line > MAX_BARE_LINE_BYTES then
		return nil
	end
	local cursor = byte_column + 1
	for _, prefix in ipairs({ "https://", "http://", "mailto:" }) do
		local search = 1
		while search <= #line do
			local first = line:find(prefix, search, true)
			if not first then
				break
			end
			local previous = first > 1 and line:sub(first - 1, first - 1) or ""
			local last = first + #prefix - 1
			while last < #line and not line:sub(last + 1, last + 1):find("[%s<>\"'`]") do
				last = last + 1
			end
			last = trim_bare_target(line, first, last)
			local length = last - first + 1
			if
				(previous == "" or not previous:find("[%w+_.-]"))
				and length <= MAX_BARE_TARGET_BYTES
				and cursor >= first
				and cursor <= last
			then
				local value = line:sub(first, last)
				return { kind = "destination", value = value, fragment = value:find("#", 1, true) ~= nil }
			end
			search = math.max(first + 1, last + 2)
		end
	end
end

---Resolve the Markdown target under one zero-based buffer position.
---@param bufnr integer
---@param row integer
---@param byte_column integer
---@return { kind: "destination"|"reference", value: string?, error: string?, fragment: boolean? }?
function M.target_at(bufnr, row, byte_column)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local column = math.max(0, math.min(byte_column, math.max(#line - 1, 0)))
	return treesitter_target(bufnr, row, column) or bare_target(line, byte_column)
end

local function scheme(value)
	return value:match("^([%a][%w+.-]*):")
end

local function open_external(value)
	local ssh_tty = vim.env.SSH_TTY
	local ssh_connection = vim.env.SSH_CONNECTION
	if (type(ssh_tty) == "string" and ssh_tty ~= "") or (type(ssh_connection) == "string" and ssh_connection ~= "") then
		local ok, err = clipboard.copy_text(value, "+")
		if not ok then
			notify("Could not copy link through OSC 52: " .. tostring(err), vim.log.levels.ERROR)
			return false
		end
		notify("Copied link to the local clipboard", vim.log.levels.INFO)
		return true
	end
	local ok, command, err = pcall(vim.ui.open, value)
	if not ok or not command then
		notify("Could not open link: " .. tostring(ok and err or command), vim.log.levels.ERROR)
		return false
	end
	return true
end

local function existing_path(bufnr, value)
	local decoded_ok, decoded = pcall(vim.uri_decode, value)
	if not decoded_ok then
		return nil
	end
	local path = decoded
	if vim.startswith(path, "~/") then
		path = vim.fn.expand(path)
	elseif not path:match("^/") and not path:match("^%a:[/\\]") and not path:match("^\\\\") then
		local buffer_path = vim.api.nvim_buf_get_name(bufnr)
		local base = buffer_path ~= "" and vim.fs.dirname(buffer_path) or vim.fn.getcwd()
		path = vim.fs.joinpath(base, path)
	end
	path = vim.fs.normalize(path)
	local stat = vim.uv.fs_stat(path)
	return stat and stat.type == "file" and path or nil
end

local function open_file_target(bufnr, value)
	local path
	if value:sub(1, 5):lower() == "file:" then
		local normalized_uri = "file:" .. value:sub(6)
		local ok, result = pcall(vim.uri_to_fname, normalized_uri)
		path = ok and result or nil
		local stat = path and vim.uv.fs_stat(path) or nil
		path = stat and stat.type == "file" and vim.fs.normalize(path) or nil
	else
		path = existing_path(bufnr, value)
	end
	if not path then
		notify("Markdown file target does not exist: " .. value)
		return false
	end
	editor.open_file_in_tab(path)
	return true
end

local function follow_target(bufnr, row, byte_column, target)
	if target.kind == "reference" then
		return configured.marksman(bufnr, row + 1, byte_column + 1)
	end
	if target.error then
		notify("Could not follow Markdown link: " .. target.error)
		return false
	end
	local value = vim.trim(target.value or "")
	if value == "" then
		notify("Markdown link has no target")
		return false
	end
	local target_scheme = scheme(value)
	if target_scheme then
		target_scheme = target_scheme:lower()
	end
	if target_scheme == "http" or target_scheme == "https" or target_scheme == "mailto" then
		return open_external(value)
	end
	if target_scheme and target_scheme ~= "file" then
		notify("Unsupported Markdown link scheme: " .. target_scheme)
		return false
	end
	if target.fragment then
		return configured.marksman(bufnr, row + 1, byte_column + 1)
	end
	return open_file_target(bufnr, value)
end

---Check whether the editable source may be used for rendered navigation.
---@param bufnr integer
---@return boolean
function M.rendered_allowed(bufnr)
	return configured ~= nil
		and vim.api.nvim_buf_is_valid(bufnr)
		and vim.bo[bufnr].filetype == "markdown"
		and configured.eligible(bufnr)
		and configured.allowed(bufnr, "Markdown navigation")
end

---Follow a Markdown target, falling back to LSP or native `gd` when absent.
---@param bufnr? integer
---@return boolean
function M.follow(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if
		not configured
		or not vim.api.nvim_buf_is_valid(bufnr)
		or vim.bo[bufnr].filetype ~= "markdown"
		or not configured.eligible(bufnr)
		or not configured.allowed(bufnr, "Markdown navigation")
	then
		return false
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local target = M.target_at(bufnr, cursor[1] - 1, cursor[2])
	if not target then
		return configured.definition(bufnr)
	end
	return follow_target(bufnr, cursor[1] - 1, cursor[2], target)
end

---Follow a link selected in a rendered Markdown view using the source's
---existing destination policy. The caller supplies a source position only
---for fragment links, which Marksman resolves in the editable source.
---@param bufnr integer
---@param row integer Zero-based source row.
---@param byte_column integer? Zero-based source byte column.
---@param url string
---@return boolean
function M.follow_rendered_link(bufnr, row, byte_column, url)
	if not M.rendered_allowed(bufnr) then
		return false
	end
	local target = destination_target(url, true)
	if target.fragment and byte_column == nil then
		notify("Could not locate the rendered link in its Markdown source")
		return false
	end
	return follow_target(bufnr, row, byte_column or 0, target)
end

local function current_gd_mapping(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if mapping.lhs == "gd" then
			return mapping
		end
	end
end

local function clear_owned_mapping(bufnr)
	local callback = owned_mappings[bufnr]
	owned_mappings[bufnr] = nil
	if not callback then
		return
	end
	local mapping = current_gd_mapping(bufnr)
	if mapping and mapping.callback == callback then
		pcall(vim.keymap.del, "n", "gd", { buffer = bufnr })
	end
end

local function apply_mapping(bufnr)
	if
		not vim.api.nvim_buf_is_valid(bufnr)
		or vim.bo[bufnr].filetype ~= "markdown"
		or not configured.eligible(bufnr)
	then
		clear_owned_mapping(bufnr)
		return
	end
	clear_owned_mapping(bufnr)
	local callback = function()
		M.follow(bufnr)
	end
	vim.keymap.set("n", "gd", callback, {
		buffer = bufnr,
		silent = true,
		desc = "Open Markdown target or definition",
	})
	owned_mappings[bufnr] = callback
end

---Return the Markdown `gd` handler for a buffer, if this adapter owns it.
---@param bufnr integer
---@return function?
function M.handler(bufnr)
	if not configured or not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "markdown" then
		return nil
	end
	if not configured.eligible(bufnr) then
		return nil
	end
	if not owned_mappings[bufnr] then
		apply_mapping(bufnr)
	end
	return owned_mappings[bufnr]
end

---Install full-editor Markdown navigation with host-owned LSP callbacks.
---@param options { allowed: fun(bufnr: integer, title: string): boolean, eligible?: fun(bufnr: integer): boolean, definition: fun(bufnr: integer): boolean, marksman: fun(bufnr: integer, line: integer, column: integer): boolean }
---@return boolean
function M.setup(options)
	if not profile_enabled() then
		return false
	end
	if
		type(options) ~= "table"
		or type(options.allowed) ~= "function"
		or (options.eligible ~= nil and type(options.eligible) ~= "function")
		or type(options.definition) ~= "function"
		or type(options.marksman) ~= "function"
	then
		error("markdown navigation requires allowed, definition, marksman, and optional eligible callbacks")
	end
	configured = {
		allowed = options.allowed,
		eligible = options.eligible or function()
			return true
		end,
		definition = options.definition,
		marksman = options.marksman,
	}
	local group = vim.api.nvim_create_augroup("NvimConfigMarkdownNavigation", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "*",
		callback = function(event)
			apply_mapping(event.buf)
		end,
		desc = "Install semantic Markdown definition navigation",
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			owned_mappings[event.buf] = nil
		end,
		desc = "Forget disposed Markdown navigation mappings",
	})
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		apply_mapping(bufnr)
	end
	return true
end

return M
