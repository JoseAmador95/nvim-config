local M = {}

local REPLACEMENT = "\239\191\189"

local function continuation(byte)
	return byte and byte >= 128 and byte <= 191
end

local function valid_prefix(bytes, index, available)
	local first = bytes:byte(index)
	for offset = 1, available - 1 do
		if not continuation(bytes:byte(index + offset)) then
			return false
		end
	end
	if available < 2 then
		return true
	end
	local second = bytes:byte(index + 1)
	if first == 224 and second < 160 then
		return false
	end
	if first == 237 and second > 159 then
		return false
	end
	if first == 240 and second < 144 then
		return false
	end
	if first == 244 and second > 143 then
		return false
	end
	return true
end

local function sequence_length(byte)
	if byte >= 194 and byte <= 223 then
		return 2
	end
	if byte >= 224 and byte <= 239 then
		return 3
	end
	if byte >= 240 and byte <= 244 then
		return 4
	end
end

-- Decode one bounded byte chunk. Incomplete trailing codepoints are retained
-- separately, never placed in a Neovim buffer, and are capped at three bytes.
function M.feed(carry, chunk)
	if type(carry) ~= "string" or type(chunk) ~= "string" then
		return nil, nil, "decoder input must be strings"
	end
	if #carry > 3 then
		return nil, nil, "decoder carry exceeds three bytes"
	end
	local bytes = carry .. chunk
	local output = {}
	local index = 1
	while index <= #bytes do
		local byte = bytes:byte(index)
		if byte >= 1 and byte <= 127 then
			output[#output + 1] = string.char(byte)
			index = index + 1
		elseif byte == 0 then
			output[#output + 1] = REPLACEMENT
			index = index + 1
		else
			local length = sequence_length(byte)
			if not length then
				output[#output + 1] = REPLACEMENT
				index = index + 1
			else
				local available = math.min(length, #bytes - index + 1)
				if not valid_prefix(bytes, index, available) then
					output[#output + 1] = REPLACEMENT
					index = index + 1
				elseif available < length then
					return table.concat(output), bytes:sub(index)
				else
					output[#output + 1] = bytes:sub(index, index + length - 1)
					index = index + length
				end
			end
		end
	end
	return table.concat(output), ""
end

-- Keep the newest complete UTF-8 suffix without exceeding max_bytes.
function M.suffix(text, max_bytes)
	if type(text) ~= "string" or type(max_bytes) ~= "number" or max_bytes < 0 then
		return nil, "suffix requires text and a non-negative byte limit"
	end
	max_bytes = math.floor(max_bytes)
	if #text <= max_bytes then
		return text
	end
	local first = #text - max_bytes + 1
	while first <= #text do
		local byte = text:byte(first)
		if byte < 128 or byte > 191 then
			break
		end
		first = first + 1
	end
	return text:sub(first)
end

return M
