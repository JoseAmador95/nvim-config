-- Decode only the bounded, SHA-256-verified Temurin tar stream. Extraction never
-- delegates path handling to tar: links become copies of archive-owned files.
local M = {}

local MAX_BYTES = 256 * 1024 * 1024
local MAX_ENTRIES = 4096

function M.relative(path)
	if type(path) ~= "string" or path == "" or #path > 1024 or path:find("[%z\r\n\\]") or path:sub(1, 1) == "/" then
		return nil
	end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." or #part > 255 then
			return nil
		end
		parts[#parts + 1] = part
	end
	return table.concat(parts, "/") == path and path or nil
end

local function field(header, start, size)
	return header:sub(start, start + size - 1):match("^[^%z]*")
end

local function octal(value)
	local text = value:match("^%s*([0-7]+)[%z ]*$")
	return text and tonumber(text, 8) or nil
end

local function pax(data)
	local result, offset = {}, 1
	while offset <= #data do
		local length = tonumber(data:sub(offset):match("^(%d+) "))
		if not length or length < 5 or offset + length - 1 > #data then
			return nil, "invalid PAX record length"
		end
		local key, value = data:sub(offset, offset + length - 1):match("^%d+ ([^=]+)=(.*)\n$")
		if not key or result[key] or key:find("sparse", 1, true) then
			return nil, "invalid or unsupported PAX record"
		end
		result[key] = value
		offset = offset + length
	end
	return result
end

local function link_target(name, target, symbolic)
	if target:sub(1, 1) == "/" or target:find("[%z\r\n\\]") then
		return nil
	end
	local parts = {}
	local joined = symbolic and ((name:match("^(.*)/") or "") .. "/" .. target) or target
	for part in joined:gmatch("[^/]+") do
		if part == ".." then
			if #parts == 0 then
				return nil
			end
			table.remove(parts)
		elseif part ~= "." then
			parts[#parts + 1] = part
		end
	end
	return M.relative(table.concat(parts, "/"))
end

function M.parse(data, root)
	if type(data) ~= "string" or #data > MAX_BYTES or #data < 1024 or not M.relative(root) then
		return nil, "archive size or root is invalid"
	end
	local entries, by_name = {}, {}
	local offset, pending, long_name, long_link = 1, {}, nil, nil
	local ended = false
	while offset + 511 <= #data do
		local header = data:sub(offset, offset + 511)
		if header == string.rep("\0", 512) then
			if data:sub(offset):find("[^%z]") or #data - offset + 1 < 1024 then
				return nil, "invalid archive terminator"
			end
			ended = true
			break
		end
		local checksum = octal(header:sub(149, 156))
		local sum = 8 * 32
		for index = 1, 512 do
			if index < 149 or index > 156 then
				sum = sum + header:byte(index)
			end
		end
		local size = octal(header:sub(125, 136))
		local mode = octal(header:sub(101, 108))
		if checksum ~= sum or not size or not mode or size > MAX_BYTES or offset + 512 + size > #data + 1 then
			return nil, "invalid archive header"
		end
		local kind = header:sub(157, 157)
		local name = field(header, 1, 100)
		local magic = header:sub(258, 263)
		if magic == "ustar\0" then
			local prefix = field(header, 346, 155)
			if prefix ~= "" then
				name = prefix .. "/" .. name
			end
		elseif magic ~= "ustar " then
			return nil, "unsupported archive header format"
		end
		local start = offset + 512
		local payload = function()
			return data:sub(start, start + size - 1)
		end
		if kind == "x" or kind == "g" then
			local values, err = pax(payload())
			if not values then
				return nil, err
			end
			if kind == "g" then
				if values.path or values.linkpath or values.size then
					return nil, "global PAX may not override entry identity"
				end
			else
				pending = values
			end
		elseif kind == "L" or kind == "K" then
			local value = payload():match("^[^%z]*")
			if kind == "L" then
				long_name = value
			else
				long_link = value
			end
		else
			name = pending.path or long_name or name
			name = name:gsub("/$", "")
			if not M.relative(name) or (name ~= root and name:sub(1, #root + 1) ~= root .. "/") then
				return nil, "archive path escapes its pinned root"
			end
			if pending.size and tonumber(pending.size) ~= size then
				return nil, "PAX size differs from the bounded header"
			end
			if by_name[name] then
				return nil, "duplicate archive entry"
			end
			local entry = { name = name, mode = math.floor(mode / 64) % 2 == 1 and 448 or 384 }
			if kind == "0" or kind == "\0" then
				entry.kind, entry.start, entry.size = "file", start, size
			elseif kind == "5" and size == 0 then
				entry.kind = "directory"
			elseif (kind == "1" or kind == "2") and size == 0 then
				entry.kind = "link"
				entry.target = link_target(name, pending.linkpath or long_link or field(header, 158, 100), kind == "2")
				if not entry.target or entry.target:sub(1, #root + 1) ~= root .. "/" then
					return nil, "archive link escapes its pinned root"
				end
			else
				return nil, "unsupported archive entry kind"
			end
			if name == root and entry.kind ~= "directory" then
				return nil, "archive root is not a directory"
			end
			entries[#entries + 1], by_name[name] = entry, entry
			if #entries > MAX_ENTRIES then
				return nil, "archive has too many entries"
			end
			pending, long_name, long_link = {}, nil, nil
		end
		offset = start + math.ceil(size / 512) * 512
	end
	if not ended or next(pending) or long_name or long_link or not by_name[root] then
		return nil, "archive is incomplete"
	end
	local materialized_bytes = 0
	for _, entry in ipairs(entries) do
		local parent = entry.name:match("^(.*)/")
		while parent and parent ~= root do
			if by_name[parent] and by_name[parent].kind ~= "directory" then
				return nil, "archive parent is not a directory"
			end
			parent = parent:match("^(.*)/")
		end
		local resolved, seen = entry, {}
		while resolved.kind == "link" do
			if seen[resolved.name] then
				return nil, "archive link cycle"
			end
			seen[resolved.name] = true
			resolved = by_name[resolved.target]
			if not resolved then
				return nil, "archive link target is absent"
			end
		end
		if entry.kind == "link" then
			if resolved.kind ~= "file" then
				return nil, "archive directory links are unsupported"
			end
			entry.kind, entry.start, entry.size, entry.mode = "file", resolved.start, resolved.size, resolved.mode
		end
		entry.path = entry.name:sub(#root + 2)
		materialized_bytes = materialized_bytes + (entry.size or 0)
		if materialized_bytes > MAX_BYTES then
			return nil, "materialized archive exceeds its byte limit"
		end
	end
	return entries
end

return M
