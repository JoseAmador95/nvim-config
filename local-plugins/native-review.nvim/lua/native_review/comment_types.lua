-- Runtime review comment type catalogue. `issue` is the only built-in type;
-- setup may add ordered types without changing how saved comments are read.
local M = {}

local ISSUE = {
	id = "issue",
	icon = "●",
	highlight = "NvimReviewCommentIssue",
	default_link = "DiagnosticSignError",
	rail_rank = 1,
	severity = vim.diagnostic.severity.ERROR,
}
local MAX_EXTRA_TYPES = 32
local MAX_ID_BYTES = 64
local MAX_HIGHLIGHT_BYTES = 80
local ALLOWED_FIELDS = {
	id = true,
	icon = true,
	highlight = true,
	default_link = true,
	rail_rank = true,
	severity = true,
}

local definitions = {}
local by_id = {}

local function copy(value)
	return vim.deepcopy(value)
end

local function valid_id(id)
	return type(id) == "string" and #id > 0 and #id <= MAX_ID_BYTES and id:match("^[a-z][a-z0-9_!%-]*$") ~= nil
end

local function valid_group(value)
	return type(value) == "string"
		and #value > 0
		and #value <= MAX_HIGHLIGHT_BYTES
		and value:match("^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function valid_icon(icon)
	if type(icon) ~= "string" or icon == "" or #icon > 16 or icon:find("%c") then
		return false
	end
	local utf8_ok = pcall(vim.str_utfindex, icon)
	local width_ok, width = pcall(vim.fn.strdisplaywidth, icon)
	return utf8_ok and width_ok and width >= 1 and width <= 2
end

function M.validate(extras)
	if extras == nil then
		extras = {}
	end
	assert(type(extras) == "table" and vim.islist(extras), "native-review comment_types must be a list")
	assert(#extras <= MAX_EXTRA_TYPES, "native-review comment_types exceeds 32 additional types")
	local seen_ids = { issue = true, rationale = true }
	local seen_ranks = { [1] = true }
	local normalized = {}
	for index, definition in ipairs(extras) do
		local label = ("native-review comment_types[%d]"):format(index)
		assert(type(definition) == "table" and not vim.islist(definition), label .. " must be an object")
		for key in pairs(definition) do
			assert(ALLOWED_FIELDS[key], label .. " contains an unknown field: " .. tostring(key))
		end
		assert(valid_id(definition.id), label .. ".id must be a lowercase ASCII token of at most 64 bytes")
		assert(not seen_ids[definition.id], label .. ".id is duplicated or reserved")
		assert(valid_icon(definition.icon), label .. ".icon must occupy one or two display cells")
		assert(valid_group(definition.highlight), label .. ".highlight must be a highlight group name")
		assert(valid_group(definition.default_link), label .. ".default_link must be a highlight group name")
		assert(
			type(definition.rail_rank) == "number" and definition.rail_rank % 1 == 0 and definition.rail_rank > 1,
			label .. ".rail_rank must be an integer above the issue priority of 1"
		)
		assert(not seen_ranks[definition.rail_rank], label .. ".rail_rank is duplicated")
		local severity = definition.severity
		if severity == nil then
			severity = vim.diagnostic.severity.INFO
		end
		assert(
			type(severity) == "number" and severity % 1 == 0 and severity >= 1 and severity <= 4,
			label .. ".severity must be a diagnostic severity from 1 to 4"
		)
		seen_ids[definition.id] = true
		seen_ranks[definition.rail_rank] = true
		normalized[#normalized + 1] = {
			id = definition.id,
			icon = definition.icon,
			highlight = definition.highlight,
			default_link = definition.default_link,
			rail_rank = definition.rail_rank,
			severity = severity,
		}
	end
	return normalized
end

function M.configure(extras)
	local normalized = M.validate(extras)
	local next_definitions = { copy(ISSUE) }
	local next_by_id = {}
	for _, definition in ipairs(normalized) do
		next_definitions[#next_definitions + 1] = definition
	end
	for index, definition in ipairs(next_definitions) do
		definition.cycle_rank = index
		next_by_id[definition.id] = definition
	end
	definitions = next_definitions
	by_id = next_by_id
	return M.all()
end

function M.reset()
	return M.configure({})
end

function M.all()
	return copy(definitions)
end

function M.ids()
	local values = {}
	for _, definition in ipairs(definitions) do
		values[#values + 1] = definition.id
	end
	return values
end

function M.rail_ids()
	local ranked = M.all()
	table.sort(ranked, function(left, right)
		return left.rail_rank < right.rail_rank
	end)
	local values = {}
	for _, definition in ipairs(ranked) do
		values[#values + 1] = definition.id
	end
	return values
end

-- Retired configured IDs remain safe to display and round-trip, but cannot be
-- selected for new comments. Keep the previous rationale rename on read.
function M.canonical(id)
	if not valid_id(id) then
		return nil
	end
	return id == "rationale" and "objection!" or id
end

function M.get(id)
	local canonical = M.canonical(id)
	if not canonical then
		return nil
	end
	local definition = by_id[canonical]
	if definition then
		return copy(definition)
	end
	return {
		id = canonical,
		icon = "·",
		highlight = "Comment",
		default_link = "Comment",
		rail_rank = math.huge,
		severity = vim.diagnostic.severity.INFO,
	}
end

function M.contains(id)
	return by_id[id] ~= nil
end

function M.cycle(id, delta)
	local current = by_id[id]
	if not current then
		return definitions[1].id
	end
	local offset = tonumber(delta) or 1
	offset = offset >= 0 and 1 or -1
	local index = (current.cycle_rank - 1 + offset) % #definitions + 1
	return definitions[index].id
end

M.reset()

return M
