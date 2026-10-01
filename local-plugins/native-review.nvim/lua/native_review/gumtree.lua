-- GumTree annotates the complete textual diff using only frozen source bytes.
local M = {}
local MAX_INPUT_BYTES = 1024 * 1024
local MAX_NODES = 50000
local MAX_DEPTH = 512
local LANGUAGES = {
	lua = "lua",
	py = "python",
	c = "c",
	h = "c",
	cc = "cpp",
	cpp = "cpp",
	cxx = "cpp",
	hpp = "cpp",
	hh = "cpp",
	hxx = "cpp",
}
local IDENTIFIERS = {
	identifier = true,
	field_identifier = true,
	type_identifier = true,
	namespace_identifier = true,
	statement_identifier = true,
}
local ACTIONS = {
	["move-tree"] = "old",
	["update-node"] = "old",
	["delete-node"] = "old",
	["delete-tree"] = "old",
	["insert-node"] = "new",
	["insert-tree"] = "new",
}

M._parser = vim.treesitter.get_string_parser

local function integer(value)
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

local function list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not integer(key) or key < 1 or key > #value then
			return false
		end
	end
	return true
end

local function source(text)
	local value = { text = text, boundaries = { [0] = true }, lines = { 0 } }
	local offset = 1
	while offset <= #text do
		local first = text:byte(offset)
		local length, minimum, maximum, codepoint = 1, 128, 191, first
		if first >= 194 and first <= 223 then
			length, codepoint = 2, first - 192
		elseif first >= 224 and first <= 239 then
			length, codepoint = 3, first - 224
			minimum = first == 224 and 160 or 128
			maximum = first == 237 and 159 or 191
		elseif first >= 240 and first <= 244 then
			length, codepoint = 4, first - 240
			minimum = first == 240 and 144 or 128
			maximum = first == 244 and 143 or 191
		elseif first >= 128 then
			return nil, "frozen source is not valid UTF-8"
		end
		for index = 1, length - 1 do
			local byte = text:byte(offset + index)
			if not byte or byte < (index == 1 and minimum or 128) or byte > (index == 1 and maximum or 191) then
				return nil, "frozen source is not valid UTF-8"
			end
			codepoint = codepoint * 64 + byte - 128
		end
		if
			(codepoint < 32 and codepoint ~= 9 and codepoint ~= 10 and codepoint ~= 13)
			or codepoint == 65534
			or codepoint == 65535
		then
			return nil, "frozen source contains characters forbidden by XML 1.0"
		end
		if first == 10 then
			value.lines[#value.lines + 1] = offset
		end
		offset = offset + length
		value.boundaries[offset - 1] = true
	end
	return value
end

local function escape(text)
	return (
		text:gsub("&", "&amp;")
			:gsub("<", "&lt;")
			:gsub(">", "&gt;")
			:gsub('"', "&quot;")
			:gsub("\r", "&#13;")
			:gsub("\n", "&#10;")
			:gsub("\t", "&#9;")
	)
end

local function position(value, byte)
	local low, high = 1, #value.lines
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if value.lines[middle] <= byte then
			low = middle
		else
			high = middle - 1
		end
	end
	return low, byte - value.lines[low]
end

local function range(value, first, last)
	local start_line, start_col = position(value, first)
	local end_line, end_col = position(value, last)
	return { start_line = start_line, start_col = start_col, end_line = end_line, end_col = end_col }
end

local function export_tree(value, language, budget)
	local parser = M._parser(value.text, language, { injections = { [language] = "" } })
	local parsed = parser:parse(false)
	if type(parsed) ~= "table" or #parsed ~= 1 then
		return nil, "parser did not produce exactly one frozen syntax tree"
	end
	local root = parsed[1]:root()
	if root:has_error() then
		return nil, "frozen syntax tree contains ERROR or MISSING nodes"
	end
	local result = { source = value, nodes = {}, lookup = {}, language = language }
	local chunks = { '<?xml version="1.0" encoding="UTF-8"?><root>' }
	local stack = { { node = root, depth = 1 } }
	while #stack > 0 do
		local frame = table.remove(stack)
		if frame.close then
			chunks[#chunks + 1] = "</tree>"
		else
			budget.count = budget.count + 1
			if budget.count > MAX_NODES then
				return nil, "combined frozen syntax trees exceed the 50000 node limit"
			elseif frame.depth > MAX_DEPTH then
				return nil, "frozen syntax tree exceeds the 512 level depth limit"
			end
			local node = frame.node
			if node:missing() or node:type() == "ERROR" then
				return nil, "frozen syntax tree contains ERROR or MISSING nodes"
			end
			local _, _, first = node:start()
			local _, _, last = node:end_()
			if
				not integer(first)
				or not integer(last)
				or first > last
				or not value.boundaries[first]
				or not value.boundaries[last]
			then
				return nil, "syntax tree has invalid original byte boundaries"
			end
			if frame.parent and (first < frame.parent.first or last > frame.parent.last) then
				return nil, "syntax tree child is outside its parent"
			end
			local kind = node:type()
			if type(kind) ~= "string" or kind == "" or not source(kind) then
				return nil, "syntax tree has an invalid node type"
			end
			local children = node:child_count()
			local label = children == 0 and value.text:sub(first + 1, last) or ""
			local key = kind .. (label ~= "" and (": " .. label) or "") .. (" [%d,%d]"):format(first, last)
			local record = {
				first = first,
				last = last,
				type = kind,
				label = label,
				leaf = children == 0,
				key = key,
				parent = frame.parent,
			}
			result.nodes[#result.nodes + 1] = record
			if result.lookup[key] ~= nil then
				result.lookup[key] = false -- Never guess between identical upstream node strings.
			else
				result.lookup[key] = record
			end
			chunks[#chunks + 1] = ('<tree type="%s" label="%s" pos="%d" length="%d">'):format(
				escape(kind),
				escape(label),
				first,
				last - first
			)
			stack[#stack + 1] = { close = true }
			for index = children - 1, 0, -1 do
				stack[#stack + 1] = { node = node:child(index), depth = frame.depth + 1, parent = record }
			end
		end
	end
	chunks[#chunks + 1] = "</root>"
	result.xml = table.concat(chunks)
	return result
end

local function language_for(path)
	if type(path) ~= "string" or path:find("\0", 1, true) then
		return nil
	end
	-- Uppercase .C is conventionally C++, unlike lowercase .c.
	local extension = path:match("%.([^./]+)$")
	return extension == "C" and "cpp" or LANGUAGES[extension]
end

---Export complete installed-parser trees without reading a current file or buffer.
---@return table? trees
---@return string? reason Controlled Main fallback reason.
function M.export(entry)
	if type(entry) ~= "table" or type(entry.old_text) ~= "string" or type(entry.new_text) ~= "string" then
		return nil, "GumTree requires both frozen snapshot texts"
	end
	if entry.metadata_only or entry.binary then
		return nil, "Binary or metadata-only file"
	end
	if #entry.old_text + #entry.new_text > MAX_INPUT_BYTES then
		return nil, "combined frozen sources exceed the 1 MiB limit"
	end
	local old_language = language_for(entry.old_path or entry.path or entry.new_path)
	local new_language = language_for(entry.new_path or entry.path or entry.old_path)
	if not old_language or old_language ~= new_language then
		return nil, "GumTree supports matching Lua, Python, C, or C++ file extensions only"
	end
	local trees, budget = {}, { count = 0 }
	for _, side in ipairs({ "old", "new" }) do
		local value, err = source(entry[side .. "_text"])
		if not value then
			return nil, "GumTree " .. side .. ": " .. err
		end
		local ok, tree, tree_err = pcall(export_tree, value, old_language, budget)
		if not ok or not tree then
			return nil,
				"GumTree " .. side .. " parser unavailable or unsupported: " .. tostring(ok and tree_err or tree):sub(
					1,
					512
				)
		end
		trees[side] = tree
	end
	return trees
end

local function recognized(tree, key)
	local node = type(key) == "string" and tree.lookup[key]
	if not node then
		return nil
	end
	local value = tree.source
	if not value.boundaries[node.first] or not value.boundaries[node.last] or node.first > node.last then
		return nil
	end
	if node.leaf and node.label ~= value.text:sub(node.first + 1, node.last) then
		return nil
	end
	return node
end

local function ancestor(outer, inner)
	local node = inner.parent
	while node do
		if node == outer then
			return true
		end
		node = node.parent
	end
	return false
end

local function ordered(left, right)
	if left.old.first ~= right.old.first then
		return left.old.first < right.old.first
	elseif left.old.last ~= right.old.last then
		return left.old.last > right.old.last
	elseif left.new.first ~= right.new.first then
		return left.new.first < right.new.first
	elseif left.new.last ~= right.new.last then
		return left.new.last > right.new.last
	end
	return left.kind < right.kind
end

---Accept only exact exported nodes and matches; never infer a move from its parent.
---@return table? result
---@return string? err
function M.normalize(trees, decoded)
	if type(decoded) ~= "table" or not list(decoded.matches) or not list(decoded.actions) then
		return nil, "Invalid GumTree JSON: matches and actions arrays are required"
	end
	if #decoded.matches > MAX_NODES or #decoded.actions > MAX_NODES * 2 then
		return nil, "GumTree output exceeds the bounded node/action contract"
	end
	local matches, destinations = {}, {}
	for _, match in ipairs(decoded.matches) do
		local old = type(match) == "table" and recognized(trees.old, match.src)
		local new = type(match) == "table" and recognized(trees.new, match.dest)
		if
			not old
			or not new
			or old.type ~= new.type
			or (matches[old] and matches[old] ~= new)
			or (destinations[new] and destinations[new] ~= old)
		then
			return nil, "GumTree match is unknown, ambiguous, conflicting, or changes node type"
		end
		matches[old], destinations[new] = new, old
	end
	local candidates, seen = {}, {}
	for _, action in ipairs(decoded.actions) do
		local side = type(action) == "table" and ACTIONS[action.action]
		local old = side and recognized(trees[side], action.tree)
		if not old then
			return nil, "GumTree action or original node is unknown or ambiguous"
		end
		if action.action == "move-tree" or action.action == "update-node" then
			local new = matches[old]
			if not new then
				return nil, "GumTree move/update has no exact destination match"
			end
			local kind = "move"
			if action.action == "update-node" then
				if type(action.label) ~= "string" or action.label ~= new.label or old.label == new.label then
					return nil, "GumTree update label contradicts frozen source content"
				end
				kind = old.leaf and new.leaf and IDENTIFIERS[old.type] and "identifier_update" or nil
			end
			local identity = kind and (kind .. "\0" .. old.key .. "\0" .. new.key)
			if identity and not seen[identity] and old.first < old.last and new.first < new.last then
				seen[identity] = true
				candidates[#candidates + 1] = { kind = kind, old = old, new = new }
			end
		end
	end
	-- Canonical OLD order survives crossing matches. Suppress only descendants
	-- carried by a moved ancestor with exactly the same relative displacement.
	table.sort(candidates, ordered)
	local result, moved = { presentation = "native", structural_only = false, relations = {} }, {}
	for _, candidate in ipairs(candidates) do
		local redundant = false
		if candidate.kind == "move" then
			local parent = candidate.old.parent
			while parent do
				local outer = moved[parent]
				if
					outer
					and ancestor(outer.new, candidate.new)
					and candidate.old.first - outer.old.first == candidate.new.first - outer.new.first
					and candidate.old.last - outer.old.first == candidate.new.last - outer.new.first
				then
					redundant = true
					break
				end
				parent = parent.parent
			end
			moved[candidate.old] = candidate
		end
		if not redundant then
			result.relations[#result.relations + 1] = {
				kind = candidate.kind,
				old = range(trees.old.source, candidate.old.first, candidate.old.last),
				new = range(trees.new.source, candidate.new.first, candidate.new.last),
			}
		end
	end
	return result
end

---Prepare optional relations over Main, keeping all textual changes visible.
---@return function cancel
function M.prepare(entry, adapter, callback)
	local cancelled, completed, stop = false, false, nil
	local function complete(result, err)
		if not cancelled and not completed then
			completed = true
			callback(result, err)
		end
	end
	local function cancel()
		if not cancelled then
			cancelled = true
			if stop then
				pcall(stop)
			end
		end
	end
	local trees, reason = M.export(entry)
	if not trees then
		complete({ fallback_reason = reason })
		return cancel
	end
	if type(adapter) ~= "table" or type(adapter.analyze) ~= "function" then
		complete(nil, "GumTree is unavailable; run :NvimConfigToolsInstall gumtree")
		return cancel
	end
	local ok, handle = pcall(
		adapter.analyze,
		{ entry = vim.deepcopy(entry), trees = { old = trees.old.xml, new = trees.new.xml } },
		function(raw, err)
			if cancelled or completed then
				return
			end
			if type(raw) ~= "string" then
				complete(nil, err or "GumTree returned no JSON")
				return
			end
			local decoded_ok, decoded = pcall(vim.json.decode, raw)
			if not decoded_ok then
				complete(nil, "Invalid GumTree JSON")
				return
			end
			local result, normalize_err = M.normalize(trees, decoded)
			complete(result, normalize_err)
		end
	)
	if not ok then
		complete(nil, "Cannot analyze frozen GumTree trees: " .. tostring(handle):sub(1, 512))
	elseif type(handle) == "function" then
		stop = handle
	end
	return cancel
end

return M
