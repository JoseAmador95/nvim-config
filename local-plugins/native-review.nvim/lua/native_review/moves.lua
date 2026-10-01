-- Exact, unique common blocks among removed/added lines, with bounded input.
local M = {}

local MAX_TOKENS = 100000

local function changed_runs(value, side)
	local source = value.sources[side]
	local runs = {}
	for _, hunk in ipairs(value.hunks) do
		local first, count = hunk[side .. "_start"], hunk[side .. "_count"]
		local nonempty, alphanumeric = 0, 0
		for line = first, first + count - 1 do
			local text = source.lines[line].text
			nonempty = nonempty + (text:find("%S") and 1 or 0)
			local _, characters = text:gsub("%w", "")
			alphanumeric = alphanumeric + characters
		end
		if nonempty >= 3 and alphanumeric >= 20 then
			runs[#runs + 1] = { first = first, last = first + count - 1 }
		end
	end
	return runs
end

local function extend(states, last, token, side, line)
	local current = #states + 1
	local node = { length = states[last].length + 1, next = {}, old = 0, new = 0 }
	if side then
		node[side], node[side .. "_end"] = 1, line
	end
	states[current] = node
	local previous = last
	while previous and not states[previous].next[token] do
		states[previous].next[token] = current
		previous = states[previous].link
	end
	if not previous then
		node.link = 1
	else
		local target = states[previous].next[token]
		if states[previous].length + 1 == states[target].length then
			node.link = target
		else
			local clone = #states + 1
			states[clone] = {
				length = states[previous].length + 1,
				next = vim.tbl_extend("force", {}, states[target].next),
				link = states[target].link,
				old = 0,
				new = 0,
			}
			while previous and states[previous].next[token] == target do
				states[previous].next[token] = clone
				previous = states[previous].link
			end
			states[target].link, node.link = clone, clone
		end
	end
	return current
end

local function build(value, runs)
	local states = { { length = 0, next = {}, old = 0, new = 0 } }
	local vocabulary, serial, last = {}, 0, 1
	for _, side in ipairs({ "old", "new" }) do
		for _, run in ipairs(runs[side]) do
			for line = run.first, run.last do
				local record = value.sources[side].lines[line]
				local raw = record.text .. record.terminator
				if not vocabulary[raw] then
					serial = serial + 1
					vocabulary[raw] = serial
				end
				last = extend(states, last, vocabulary[raw], side, line)
			end
			-- Each gap has a distinct symbol, so a match cannot cross hunks/sides.
			serial = serial + 1
			last = extend(states, last, serial)
		end
	end
	local order = {}
	for index = 2, #states do
		order[#order + 1] = index
	end
	table.sort(order, function(a, b)
		return states[a].length > states[b].length or (states[a].length == states[b].length and a < b)
	end)
	for _, index in ipairs(order) do
		local node = states[index]
		local parent = states[node.link]
		for _, side in ipairs({ "old", "new" }) do
			parent[side] = parent[side] + node[side]
			parent[side .. "_end"] = parent[side .. "_end"] or node[side .. "_end"]
		end
	end
	return states, order
end

local function metrics(source)
	local nonempty, alphanumeric = { [0] = 0 }, { [0] = 0 }
	for line, record in ipairs(source.lines) do
		local text = record.text
		nonempty[line] = nonempty[line - 1] + (text:find("%S") and 1 or 0)
		local _, characters = text:gsub("%w", "")
		alphanumeric[line] = alphanumeric[line - 1] + characters
	end
	return function(first, last)
		return nonempty[last] - nonempty[first - 1] >= 3 and alphanumeric[last] - alphanumeric[first - 1] >= 20
	end
end

local function range(source, first, last)
	return { start_line = first, start_col = 0, end_line = last, end_col = #source.lines[last].text }
end

---Find unambiguous, byte-identical moves without changing the textual diff.
---@param value table Valid textual projection, with canonical/display hunk counts.
---@return table[] relations
---@return boolean limited
function M.detect(value)
	local runs = { old = changed_runs(value, "old"), new = changed_runs(value, "new") }
	if #runs.old == 0 or #runs.new == 0 then
		return {}, false
	end
	local tokens = 0
	for _, side in ipairs({ "old", "new" }) do
		for _, run in ipairs(runs[side]) do
			tokens = tokens + run.last - run.first + 2
		end
	end
	if tokens > MAX_TOKENS then
		return {}, true
	end
	local states, order = build(value, runs)
	local qualifies = metrics(value.sources.old)
	local used = { old = {}, new = {} }
	local result = {}
	for _, index in ipairs(order) do
		local node = states[index]
		if node.old == 1 and node.new == 1 and node.length >= 3 then
			local old_first = node.old_end - node.length + 1
			local new_first = node.new_end - node.length + 1
			if
				not used.old[node.old_end]
				and not used.old[old_first]
				and not used.new[node.new_end]
				and not used.new[new_first]
				and qualifies(old_first, node.old_end)
			then
				local relation = {
					kind = "move",
					old = range(value.sources.old, old_first, node.old_end),
					new = range(value.sources.new, new_first, node.new_end),
				}
				result[#result + 1] = relation
				for _, side in ipairs({ "old", "new" }) do
					for line = relation[side].start_line, relation[side].end_line do
						used[side][line] = true
					end
				end
			end
		end
	end
	table.sort(result, function(a, b)
		return a.old.start_line < b.old.start_line
	end)
	return result, false
end

return M
