-- Canonical, side-effect-free review comment type catalogue.
local M = {}

local DEFINITIONS = {
	{
		id = "issue",
		icon = "●",
		highlight = "NvimReviewCommentIssue",
		default_link = "DiagnosticSignError",
		rail_rank = 1,
	},
	{
		id = "suggestion",
		icon = "◆",
		highlight = "NvimReviewCommentSuggestion",
		default_link = "DiagnosticSignWarn",
		rail_rank = 2,
	},
	{
		id = "rationale",
		icon = "R",
		highlight = "NvimReviewCommentRationale",
		default_link = "Special",
		rail_rank = 4,
	},
	{
		id = "question",
		icon = "?",
		highlight = "NvimReviewCommentQuestion",
		default_link = "DiagnosticSignInfo",
		rail_rank = 3,
	},
	{
		id = "pedantic",
		icon = "·",
		highlight = "NvimReviewCommentPedantic",
		default_link = "DiagnosticSignHint",
		rail_rank = 5,
	},
	{
		id = "praise",
		icon = "♥",
		highlight = "NvimReviewCommentPraise",
		default_link = "DiagnosticSignOk",
		rail_rank = 6,
	},
}

local BY_ID = {}
for index, definition in ipairs(DEFINITIONS) do
	definition.cycle_rank = index
	BY_ID[definition.id] = definition
end

local function copy(value)
	return vim.deepcopy(value)
end

function M.all()
	return copy(DEFINITIONS)
end

function M.ids()
	local values = {}
	for _, definition in ipairs(DEFINITIONS) do
		values[#values + 1] = definition.id
	end
	return values
end

function M.rail_ids()
	local definitions = M.all()
	table.sort(definitions, function(left, right)
		return left.rail_rank < right.rail_rank
	end)
	local values = {}
	for _, definition in ipairs(definitions) do
		values[#values + 1] = definition.id
	end
	return values
end

function M.get(id)
	local definition = BY_ID[id]
	return definition and copy(definition) or nil
end

function M.contains(id)
	return BY_ID[id] ~= nil
end

function M.cycle(id, delta)
	local current = BY_ID[id] or DEFINITIONS[1]
	local offset = tonumber(delta) or 1
	offset = offset >= 0 and 1 or -1
	local index = (current.cycle_rank - 1 + offset) % #DEFINITIONS + 1
	return DEFINITIONS[index].id
end

return M
