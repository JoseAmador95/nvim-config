local M = {}
local contracts = require("local_plugins.contracts")

local SECTION_KEYS = {
	id = true,
	label = true,
	items = true,
	when = true,
	surfaces = true,
	palette_label = true,
}
local DESCRIPTOR_KEYS = {
	id = true,
	label = true,
	hint = true,
	when = true,
	surfaces = true,
	palette_label = true,
	keywords = true,
}

local function object(value)
	return type(value) == "table" and (next(value) == nil or not vim.islist(value))
end

local function exact_keys(value, allowed, label)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains unknown key " .. vim.inspect(key)
		end
	end
	return true
end

local function nonempty_string(value)
	return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
end

local function surfaces(value, label)
	if value == nil then
		return true
	end
	if not object(value) then
		return nil, label .. " must be an object"
	end
	local keys_ok, keys_err = exact_keys(value, { palette = true, context = true }, label)
	if not keys_ok then
		return nil, keys_err
	end
	for name, enabled in pairs(value) do
		if type(enabled) ~= "boolean" then
			return nil, label .. "." .. name .. " must be boolean"
		end
	end
	return true
end

local function optional_callback(value, label)
	if value ~= nil and type(value) ~= "function" then
		return nil, label .. " must be a function"
	end
	return true
end

local function optional_string(value, label)
	if value ~= nil and not nonempty_string(value) then
		return nil, label .. " must be a non-empty string"
	end
	return true
end

---@param value table
---@return table? target
---@return string? error_message
function M.action_target(value)
	return contracts.normalize_action_target(value)
end

local function validate_descriptor(value, seen, section_index, item_index)
	local label = string.format("sections[%d].items[%d]", section_index, item_index)
	if not object(value) then
		return nil, label .. " must be an object"
	end
	local keys_ok, keys_err = exact_keys(value, DESCRIPTOR_KEYS, label)
	if not keys_ok then
		return nil, keys_err
	end
	if not nonempty_string(value.id) or not value.id:match("^[%w_-]+%.[%w_.-]+$") then
		return nil, label .. ".id is invalid"
	end
	if seen[value.id] then
		return nil, label .. ".id is duplicated: " .. value.id
	end
	if not nonempty_string(value.label) then
		return nil, label .. ".label must be a non-empty string"
	end
	local hint_ok, hint_err = optional_string(value.hint, label .. ".hint")
	if not hint_ok then
		return nil, hint_err
	end
	local palette_ok, palette_err = optional_string(value.palette_label, label .. ".palette_label")
	if not palette_ok then
		return nil, palette_err
	end
	local when_ok, when_err = optional_callback(value.when, label .. ".when")
	if not when_ok then
		return nil, when_err
	end
	local surfaces_ok, surfaces_err = surfaces(value.surfaces, label .. ".surfaces")
	if not surfaces_ok then
		return nil, surfaces_err
	end
	if value.keywords ~= nil then
		if type(value.keywords) ~= "table" or not vim.islist(value.keywords) then
			return nil, label .. ".keywords must be an array"
		end
		for index, keyword in ipairs(value.keywords) do
			if not nonempty_string(keyword) then
				return nil, string.format("%s.keywords[%d] must be a non-empty string", label, index)
			end
		end
	end
	seen[value.id] = true
	return vim.deepcopy(value)
end

---@param value table
---@return table[]? sections
---@return string? error_message
function M.catalog(value)
	if type(value) ~= "table" or not vim.islist(value) then
		return nil, "catalog must be an array"
	end
	local copy = {}
	local seen_sections = {}
	local seen_items = {}
	for section_index, section in ipairs(value) do
		local label = "sections[" .. section_index .. "]"
		if not object(section) then
			return nil, label .. " must be an object"
		end
		local keys_ok, keys_err = exact_keys(section, SECTION_KEYS, label)
		if not keys_ok then
			return nil, keys_err
		end
		if not nonempty_string(section.id) or not section.id:match("^[%w_.-]+$") then
			return nil, label .. ".id is invalid"
		end
		if seen_sections[section.id] then
			return nil, label .. ".id is duplicated: " .. section.id
		end
		if not nonempty_string(section.label) then
			return nil, label .. ".label must be a non-empty string"
		end
		local palette_ok, palette_err = optional_string(section.palette_label, label .. ".palette_label")
		if not palette_ok then
			return nil, palette_err
		end
		local when_ok, when_err = optional_callback(section.when, label .. ".when")
		if not when_ok then
			return nil, when_err
		end
		local surfaces_ok, surfaces_err = surfaces(section.surfaces, label .. ".surfaces")
		if not surfaces_ok then
			return nil, surfaces_err
		end
		if type(section.items) ~= "table" or not vim.islist(section.items) then
			return nil, label .. ".items must be an array"
		end
		local section_copy = vim.deepcopy(section)
		section_copy.items = {}
		for item_index, descriptor in ipairs(section.items) do
			local validated, descriptor_err = validate_descriptor(descriptor, seen_items, section_index, item_index)
			if not validated then
				return nil, descriptor_err
			end
			section_copy.items[#section_copy.items + 1] = validated
		end
		seen_sections[section.id] = true
		copy[#copy + 1] = section_copy
	end
	return copy
end

return M
