local M = {}

local DEFAULT_LIMIT = 5
local MAXIMUM_LIMIT = 20

local limit = DEFAULT_LIMIT
local ids = {}

local function trim()
	while #ids > limit do
		table.remove(ids)
	end
end

---Apply the host-only session history bound.
---@param value integer
function M.configure(value)
	assert(
		type(value) == "number" and value % 1 == 0 and value >= 0 and value <= MAXIMUM_LIMIT,
		("action palette recent limit must be an integer between 0 and %d"):format(MAXIMUM_LIMIT)
	)
	limit = value
	trim()
	return M
end

---Observe one action-palette event. Only completed palette dispatches count.
---@param event table
function M.observe(event)
	if type(event) ~= "table" or event.kind ~= "executed" or event.surface ~= "palette" then
		return false
	end
	if type(event.id) ~= "string" or event.id == "" or limit == 0 then
		return false
	end
	for index = #ids, 1, -1 do
		if ids[index] == event.id then
			table.remove(ids, index)
		end
	end
	table.insert(ids, 1, event.id)
	trim()
	return true
end

---Pin visible recent items ahead of the remaining catalog order.
---@param items table[]
---@return table[]
function M.order(items)
	local by_id = {}
	for _, item in ipairs(items) do
		by_id[item.id] = item
	end

	local ordered = {}
	local included = {}
	for _, id in ipairs(ids) do
		local item = by_id[id]
		if item then
			item.recent = true
			ordered[#ordered + 1] = item
			included[id] = true
		end
	end
	for _, item in ipairs(items) do
		if not included[item.id] then
			ordered[#ordered + 1] = item
		end
	end
	return ordered
end

function M.ids()
	return vim.deepcopy(ids)
end

function M.limit()
	return limit
end

function M.teardown()
	limit = DEFAULT_LIMIT
	ids = {}
	return true
end

return M
