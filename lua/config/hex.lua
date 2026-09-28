local M = {}

local bit = require("bit")
local uv = vim.uv

local DEFAULT_MAX_BYTES = 8 * 1024 * 1024
local HARD_MAX_BYTES = 16 * 1024 * 1024
local DEFAULT_TIMEOUT_MS = 5000
local HARD_TIMEOUT_MS = 30000
local ERROR_DETAIL_BYTES = 256
local HEX_COLUMNS = 16
local HEX_FIELD_BYTES = 47
local DECODE_BATCH_LINES = 1024
local DECODE_BLOCK_BYTES = 64 * 1024
local REPLACE_BATCH_LINES = 8192

local bom_by_encoding = {
	["ucs-2"] = "\254\255",
	["ucs-2le"] = "\255\254",
	["ucs-4"] = "\0\0\254\255",
	["ucs-4le"] = "\255\254\0\0",
	["utf-8"] = "\239\187\191",
	["utf-16"] = "\254\255",
	["utf-16le"] = "\255\254",
	["utf-32"] = "\0\0\254\255",
	["utf-32le"] = "\255\254\0\0",
}

local known_boms = { "\255\254\0\0", "\0\0\254\255", "\239\187\191", "\255\254", "\254\255" }

local binary_extensions = {
	bin = true,
	dll = true,
	exe = true,
	jpeg = true,
	jpg = true,
	out = true,
	png = true,
}

local config = {
	max_bytes = DEFAULT_MAX_BYTES,
	timeout_ms = DEFAULT_TIMEOUT_MS,
}
local states = {}
local pending = {}
local delete_write_autocmds
local xxd_path
local write_group
local temporary_counter = 0

local function utf8_prefix(value, limit)
	if #value <= limit then
		return value
	end
	local first = limit
	while first > 0 do
		local byte = value:byte(first)
		if not byte or byte < 128 or byte >= 192 then
			break
		end
		first = first - 1
	end
	local lead = value:byte(first)
	local width = lead and (lead < 128 and 1 or lead < 224 and 2 or lead < 240 and 3 or lead < 248 and 4 or 1) or 1
	if first + width - 1 > limit then
		return value:sub(1, first - 1)
	end
	return value:sub(1, limit)
end

local function sanitize(value)
	local raw = tostring(value or "")
	local ok, translated = pcall(vim.fn.strtrans, raw)
	local detail = ok and translated or raw:gsub("[%z\1-\31\127-\255]", "?")
	detail = detail:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if #detail > ERROR_DETAIL_BYTES then
		detail = utf8_prefix(detail, ERROR_DETAIL_BYTES) .. "..."
	end
	return detail ~= "" and detail or "unknown error"
end

local function notify(message, level)
	vim.notify(message, level, { title = "Hex" })
end

local function result_error(result)
	local detail = sanitize(result and result.stderr)
	if detail ~= "unknown error" then
		return detail
	end
	return string.format("xxd exited with code %s", tostring(result and result.code))
end

local function render_limit(size)
	if size == 0 then
		return 0
	end
	return math.ceil(size / HEX_COLUMNS) * 76
end

local function run_xxd(stdin)
	if #stdin > config.max_bytes then
		return nil, ("buffer exceeds the configured %d-byte hex limit"):format(config.max_bytes)
	end
	local ok, process = pcall(vim.system, { xxd_path, "-g", "1", "-u" }, { stdin = stdin })
	if not ok then
		return nil, sanitize(process)
	end
	local waited, result = pcall(function()
		return process:wait(config.timeout_ms)
	end)
	if not waited then
		return nil, sanitize(result)
	end
	if type(result) ~= "table" or result.code ~= 0 then
		return nil, result_error(result)
	end
	local output = result.stdout or ""
	if #output > render_limit(#stdin) then
		return nil, "xxd returned more output than the bounded canonical form"
	end
	return output
end

local function split_bytes(data)
	local endofline = data:sub(-1) == "\n"
	local lines = vim.split(data, "\n", { plain = true })
	if endofline then
		table.remove(lines)
	end
	if #lines == 0 then
		lines = { "" }
	end
	return lines, endofline
end

local function normalized_target(path)
	local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local parent = vim.fs.dirname(absolute)
	return vim.fs.joinpath(uv.fs_realpath(parent) or parent, vim.fs.basename(absolute))
end

local function buffer_path(buf)
	if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
		return nil
	end
	return normalized_target(vim.api.nvim_buf_get_name(buf))
end

local function timestamp_parts(value)
	if type(value) ~= "table" then
		return nil, nil
	end
	return value.sec, value.nsec
end

local function identity_from_info(info)
	local mtime_sec, mtime_nsec = timestamp_parts(info.mtime)
	local ctime_sec, ctime_nsec = timestamp_parts(info.ctime)
	return {
		dev = info.dev,
		flags = info.flags,
		gid = info.gid,
		ino = info.ino,
		mode = info.mode,
		size = info.size,
		uid = info.uid,
		mtime_sec = mtime_sec,
		mtime_nsec = mtime_nsec,
		ctime_sec = ctime_sec,
		ctime_nsec = ctime_nsec,
	}
end

local function file_identity(path)
	local info, err = uv.fs_lstat(path)
	if not info then
		return nil, "cannot inspect target file: " .. tostring(err)
	end
	if info.type ~= "file" then
		return nil, "target must be a regular file (symlinks are not written)"
	end
	if type(info.nlink) == "number" and info.nlink > 1 then
		return nil, "target with multiple hard links cannot be replaced atomically"
	end
	return identity_from_info(info)
end

local function same_identity(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then
		return false
	end
	for _, key in ipairs({
		"dev",
		"ino",
		"mode",
		"size",
		"uid",
		"gid",
		"flags",
		"mtime_sec",
		"mtime_nsec",
		"ctime_sec",
		"ctime_nsec",
	}) do
		if left[key] ~= right[key] then
			return false
		end
	end
	return true
end

local function read_file(path, expected)
	local handle, open_err = uv.fs_open(path, "r", 0)
	if not handle then
		return nil, "cannot open target file: " .. tostring(open_err)
	end
	local info, stat_err = uv.fs_fstat(handle)
	if not info or info.type ~= "file" then
		pcall(uv.fs_close, handle)
		return nil, "cannot inspect opened target file: " .. tostring(stat_err or "not a regular file")
	end
	local opened = identity_from_info(info)
	if not same_identity(expected, opened) then
		pcall(uv.fs_close, handle)
		return nil, "target changed while opening the hex view"
	end
	if opened.size > config.max_bytes then
		pcall(uv.fs_close, handle)
		return nil, ("file exceeds the configured %d-byte hex limit"):format(config.max_bytes)
	end
	local data, read_err = uv.fs_read(handle, opened.size, 0)
	local after_info, after_err = uv.fs_fstat(handle)
	local closed, close_err = uv.fs_close(handle)
	if type(data) ~= "string" or #data ~= opened.size then
		return nil, "cannot read target file: " .. tostring(read_err or "short read")
	end
	if not after_info or not same_identity(opened, identity_from_info(after_info)) then
		return nil, "target changed while reading the hex view: " .. tostring(after_err or "identity mismatch")
	end
	if not closed then
		return nil, "cannot close target file: " .. tostring(close_err)
	end
	return data
end

local function options_snapshot(buf)
	return {
		binary = vim.bo[buf].binary,
		bomb = vim.bo[buf].bomb,
		endofline = vim.bo[buf].endofline,
		fileencoding = vim.bo[buf].fileencoding,
		fileformat = vim.bo[buf].fileformat,
		filetype = vim.bo[buf].filetype,
		fixendofline = vim.bo[buf].fixendofline,
	}
end

local function window_views(buf)
	local views = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			views[#views + 1] = {
				view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
				win = win,
			}
		end
	end
	return views
end

local function restore_window_views(views)
	for _, entry in ipairs(views) do
		if vim.api.nvim_win_is_valid(entry.win) then
			pcall(vim.api.nvim_win_call, entry.win, function()
				vim.fn.winrestview(entry.view)
			end)
		end
	end
end

local function line_slice(lines, first, last)
	local slice = {}
	for index = first, last do
		slice[#slice + 1] = lines[index]
	end
	return slice
end

local function set_lines_batched(buf, lines)
	local current = vim.api.nvim_buf_line_count(buf)
	while current > REPLACE_BATCH_LINES do
		local first = math.max(REPLACE_BATCH_LINES, current - REPLACE_BATCH_LINES)
		vim.api.nvim_buf_set_lines(buf, first, current, false, {})
		current = first
	end
	local first_last = math.min(#lines, REPLACE_BATCH_LINES)
	vim.api.nvim_buf_set_lines(buf, 0, current, false, line_slice(lines, 1, first_last))
	local inserted = first_last
	while inserted < #lines do
		local last = math.min(#lines, inserted + REPLACE_BATCH_LINES)
		vim.api.nvim_buf_set_lines(buf, inserted, inserted, false, line_slice(lines, inserted + 1, last))
		inserted = last
	end
end

local function restore_options(buf, options, restore_endofline)
	vim.bo[buf].binary = options.binary
	vim.bo[buf].bomb = options.bomb
	vim.bo[buf].fileencoding = options.fileencoding
	vim.bo[buf].fileformat = options.fileformat
	vim.bo[buf].fixendofline = options.fixendofline
	if restore_endofline then
		vim.bo[buf].endofline = options.endofline
	end
	vim.bo[buf].filetype = options.filetype
end

local function valid_utf8(data)
	local index = 1
	while index <= #data do
		local first = data:byte(index)
		local width
		local second_min, second_max = 0x80, 0xBF
		if first <= 0x7F then
			width = 1
		elseif first >= 0xC2 and first <= 0xDF then
			width = 2
		elseif first >= 0xE0 and first <= 0xEF then
			width = 3
			if first == 0xE0 then
				second_min = 0xA0
			elseif first == 0xED then
				second_max = 0x9F
			end
		elseif first >= 0xF0 and first <= 0xF4 then
			width = 4
			if first == 0xF0 then
				second_min = 0x90
			elseif first == 0xF4 then
				second_max = 0x8F
			end
		else
			return false
		end
		if index + width - 1 > #data then
			return false
		end
		if width > 1 then
			local second = data:byte(index + 1)
			if second < second_min or second > second_max then
				return false
			end
			for continuation = index + 2, index + width - 1 do
				local byte = data:byte(continuation)
				if byte < 0x80 or byte > 0xBF then
					return false
				end
			end
		end
		index = index + width
	end
	return true
end

local function code_unit_16(data, index, little_endian)
	local first, second = data:byte(index, index + 1)
	if little_endian then
		return first + second * 0x100
	end
	return first * 0x100 + second
end

local function valid_utf16(data, little_endian, allow_surrogate_pairs)
	if #data % 2 ~= 0 then
		return false
	end
	local index = 1
	while index <= #data do
		local value = code_unit_16(data, index, little_endian)
		if value >= 0xD800 and value <= 0xDBFF then
			if not allow_surrogate_pairs or index + 3 > #data then
				return false
			end
			local following = code_unit_16(data, index + 2, little_endian)
			if following < 0xDC00 or following > 0xDFFF then
				return false
			end
			index = index + 4
		elseif value >= 0xDC00 and value <= 0xDFFF then
			return false
		else
			index = index + 2
		end
	end
	return true
end

local function code_unit_32(data, index, little_endian)
	local first, second, third, fourth = data:byte(index, index + 3)
	if little_endian then
		return first + second * 0x100 + third * 0x10000 + fourth * 0x1000000
	end
	return first * 0x1000000 + second * 0x10000 + third * 0x100 + fourth
end

local function valid_utf32(data, little_endian)
	if #data % 4 ~= 0 then
		return false
	end
	for index = 1, #data, 4 do
		local value = code_unit_32(data, index, little_endian)
		if value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) then
			return false
		end
	end
	return true
end

local function structurally_valid(data, encoding)
	if encoding == "utf-8" then
		return valid_utf8(data)
	elseif encoding == "utf-16" then
		return valid_utf16(data, false, true)
	elseif encoding == "utf-16le" then
		return valid_utf16(data, true, true)
	elseif encoding == "ucs-2" then
		return valid_utf16(data, false, false)
	elseif encoding == "ucs-2le" then
		return valid_utf16(data, true, false)
	elseif encoding == "utf-32" or encoding == "ucs-4" then
		return valid_utf32(data, false)
	elseif encoding == "utf-32le" or encoding == "ucs-4le" then
		return valid_utf32(data, true)
	end
	return true
end

local function convert_to_editor_encoding(data, source_encoding)
	local source = source_encoding:lower()
	if not structurally_valid(data, source) then
		return nil, "decoded bytes are structurally invalid for " .. source_encoding
	end
	local target = vim.o.encoding:lower()
	if source == target then
		return data
	end
	local converted_ok, converted = pcall(vim.iconv, data, source_encoding, vim.o.encoding)
	if not converted_ok or type(converted) ~= "string" then
		return nil, "decoded bytes are invalid for " .. source_encoding
	end
	if target == "utf-8" and not valid_utf8(converted) then
		return nil, "conversion produced invalid UTF-8"
	end
	local round_trip_ok, round_trip = pcall(vim.iconv, converted, vim.o.encoding, source_encoding)
	if not round_trip_ok or type(round_trip) ~= "string" or round_trip ~= data then
		return nil, "decoded bytes cannot be converted losslessly from " .. source_encoding
	end
	return converted
end

local function decoded_buffer_lines(data, options)
	-- In binary mode 'bomb' is not a file-writing transform: every byte in the
	-- buffer is payload.  Treating a leading marker as metadata would silently
	-- delete it when the assembled buffer is written.
	local effective_bomb = options.bomb == true
	if not options.binary and effective_bomb then
		local encoding = options.fileencoding ~= "" and options.fileencoding:lower() or vim.o.encoding:lower()
		local expected = bom_by_encoding[encoding]
		local observed
		for _, prefix in ipairs(known_boms) do
			if data:sub(1, #prefix) == prefix then
				observed = prefix
				break
			end
		end
		if observed and observed ~= expected then
			return nil, nil, "decoded BOM does not match the original fileencoding"
		end
		if observed then
			data = data:sub(#observed + 1)
		else
			effective_bomb = false
		end
	end
	if not options.binary and options.fileencoding ~= "" then
		local converted, conversion_err = convert_to_editor_encoding(data, options.fileencoding)
		if not converted then
			return nil, nil, conversion_err
		end
		data = converted
	end

	local separator = "\n"
	if not options.binary and options.fileformat == "dos" then
		separator = "\r\n"
	elseif not options.binary and options.fileformat == "mac" then
		separator = "\r"
	end
	local endofline = data:sub(-#separator) == separator
	local lines = vim.split(data, separator, { plain = true })
	if endofline then
		table.remove(lines)
	end
	if #lines == 0 then
		lines = { "" }
	end
	for _, line in ipairs(lines) do
		if line:find("\n", 1, true) then
			return nil, nil, "decoded bytes contain a newline incompatible with the original fileformat"
		end
	end
	return lines, endofline, nil, effective_bomb
end

local function replace_buffer(buf, data, options)
	local before_options = options_snapshot(buf)
	local before_modified = vim.bo[buf].modified
	local before_undolevels = vim.bo[buf].undolevels
	local before_views = window_views(buf)
	local lines = options.lines
	local endofline = options.endofline
	if not lines then
		lines, endofline = split_bytes(data)
	end
	local prepared, prepare_err = pcall(function()
		vim.bo[buf].binary = options.binary
		if options.bomb ~= nil then
			vim.bo[buf].bomb = options.bomb
		end
		vim.bo[buf].fixendofline = false
	end)
	if not prepared then
		pcall(restore_options, buf, before_options, true)
		return nil, sanitize(prepare_err)
	end
	local undo_disabled, undo_disable_err = pcall(function()
		vim.bo[buf].undolevels = -1
	end)
	if not undo_disabled then
		pcall(restore_options, buf, before_options, true)
		vim.bo[buf].modified = before_modified
		return nil, sanitize(undo_disable_err)
	end
	local replaced, replace_err = pcall(function()
		if options.batched then
			set_lines_batched(buf, lines)
		else
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end
	end)
	local undo_restored, undo_restore_err = pcall(function()
		vim.bo[buf].undolevels = before_undolevels
	end)
	if not replaced then
		local rolled_back = false
		if options.rollback_bytes then
			local rollback_output = run_xxd(options.rollback_bytes)
			if rollback_output then
				local rollback_lines = split_bytes(rollback_output)
				rolled_back = pcall(set_lines_batched, buf, rollback_lines)
			end
		end
		pcall(restore_options, buf, before_options, true)
		vim.bo[buf].modified = before_modified
		restore_window_views(before_views)
		if options.batched and not rolled_back then
			local state = states[buf]
			if state then
				delete_write_autocmds(state)
			end
			states[buf] = nil
			vim.b[buf].hex = false
			vim.b[buf].hex_ft = nil
			vim.bo[buf].modifiable = false
			return nil, "critical batched replacement failure; buffer writes were disabled: " .. sanitize(replace_err)
		end
		return nil, sanitize(replace_err)
	end
	if not undo_restored then
		return nil, sanitize(undo_restore_err)
	end
	vim.bo[buf].endofline = endofline
	vim.bo[buf].modified = options.modified == true
	local filetype_ok, filetype_err = pcall(function()
		vim.bo[buf].filetype = options.filetype
	end)
	if not filetype_ok then
		notify("Hex filetype hook failed: " .. sanitize(filetype_err), vim.log.levels.WARN)
	end
	restore_window_views(before_views)
	return true
end

local function expected_ascii(byte)
	return byte >= 32 and byte <= 126 and string.char(byte) or "."
end

local function decode_record(line, line_number, size, saw_short_line)
	if saw_short_line then
		return nil, nil, nil, ("line %d follows a short final xxd record"):format(line_number)
	end
	if #line < 60 or #line > 75 or line:sub(9, 10) ~= ": " or line:sub(58, 59) ~= "  " then
		return nil, nil, nil, ("line %d is not a canonical xxd record"):format(line_number)
	end
	local address = line:sub(1, 8)
	if not address:match("^[0-9a-fA-F]+$") or tonumber(address, 16) ~= size then
		return nil, nil, nil, ("line %d has a non-contiguous xxd offset"):format(line_number)
	end
	local field = line:sub(11, 10 + HEX_FIELD_BYTES)
	local bytes = {}
	local absent = false
	for index = 0, HEX_COLUMNS - 1 do
		local column = index * 3 + 1
		local pair = field:sub(column, column + 1)
		if pair == "  " then
			absent = true
		elseif absent or not pair:match("^[0-9a-fA-F][0-9a-fA-F]$") then
			return nil, nil, nil, ("line %d has an invalid xxd byte field"):format(line_number)
		else
			bytes[#bytes + 1] = tonumber(pair, 16)
		end
		if index < HEX_COLUMNS - 1 and field:sub(column + 2, column + 2) ~= " " then
			return nil, nil, nil, ("line %d has invalid xxd byte spacing"):format(line_number)
		end
	end
	if #bytes == 0 then
		return nil, nil, nil, ("line %d contains no xxd bytes"):format(line_number)
	end
	local ascii = line:sub(60)
	if #ascii ~= #bytes or #line ~= 59 + #bytes then
		return nil, nil, nil, ("line %d has an invalid xxd ASCII column width"):format(line_number)
	end
	local decoded = {}
	for index, byte in ipairs(bytes) do
		if ascii:sub(index, index) ~= expected_ascii(byte) then
			return nil, nil, nil, ("line %d has an xxd ASCII column that disagrees with its bytes"):format(line_number)
		end
		decoded[index] = string.char(byte)
	end
	local next_size = size + #bytes
	if next_size > config.max_bytes then
		return nil, nil, nil, ("decoded bytes exceed the configured %d-byte limit"):format(config.max_bytes)
	end
	return table.concat(decoded), next_size, #bytes < HEX_COLUMNS
end

local function new_accumulator()
	return { blocks = {}, pending = {}, pending_bytes = 0 }
end

local function accumulate(accumulator, chunk)
	accumulator.pending[#accumulator.pending + 1] = chunk
	accumulator.pending_bytes = accumulator.pending_bytes + #chunk
	if accumulator.pending_bytes >= DECODE_BLOCK_BYTES then
		accumulator.blocks[#accumulator.blocks + 1] = table.concat(accumulator.pending)
		accumulator.pending = {}
		accumulator.pending_bytes = 0
	end
end

local function accumulated_bytes(accumulator)
	if #accumulator.pending > 0 then
		accumulator.blocks[#accumulator.blocks + 1] = table.concat(accumulator.pending)
	end
	return table.concat(accumulator.blocks)
end

local function decode_sequence(line_count, fetch)
	if line_count > math.ceil(config.max_bytes / HEX_COLUMNS) then
		return nil, "hex view exceeds the configured line limit"
	end
	local accumulator = new_accumulator()
	local size = 0
	local saw_short_line = false
	for first = 1, line_count, DECODE_BATCH_LINES do
		local batch, fetch_err = fetch(first, math.min(line_count, first + DECODE_BATCH_LINES - 1))
		if not batch then
			return nil, fetch_err
		end
		for offset, line in ipairs(batch) do
			local line_number = first + offset - 1
			if line_count == 1 and line == "" then
				return ""
			end
			local chunk, next_size, short, decode_err = decode_record(line, line_number, size, saw_short_line)
			if not chunk then
				return nil, decode_err
			end
			accumulate(accumulator, chunk)
			size = next_size
			saw_short_line = short
		end
	end
	return accumulated_bytes(accumulator)
end

local function decode_lines(lines)
	return decode_sequence(#lines, function(first, last)
		local batch = {}
		for index = first, last do
			batch[#batch + 1] = lines[index]
		end
		return batch
	end)
end

local function decode_buffer(buf)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local total_bytes = vim.api.nvim_buf_get_offset(buf, line_count)
	if total_bytes < 0 or total_bytes > render_limit(config.max_bytes) then
		return nil, "hex view exceeds the configured rendered-size limit"
	end
	return decode_sequence(line_count, function(first, last)
		local start_offset = vim.api.nvim_buf_get_offset(buf, first - 1)
		local finish_offset = vim.api.nvim_buf_get_offset(buf, last)
		local rows = last - first + 1
		if start_offset < 0 or finish_offset < start_offset or finish_offset - start_offset > rows * 76 then
			return nil, ("lines %d-%d exceed the canonical xxd width bound"):format(first, last)
		end
		return vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
	end)
end

delete_write_autocmds = function(state)
	for _, id in ipairs(state.write_autocmds or {}) do
		pcall(vim.api.nvim_del_autocmd, id)
	end
	state.write_autocmds = {}
end

local function cleanup_private(temporary, directory)
	if temporary then
		pcall(uv.fs_unlink, temporary)
	end
	if directory then
		pcall(uv.fs_rmdir, directory)
	end
end

local function private_directory_matches(directory, expected)
	local info = uv.fs_lstat(directory)
	return info
		and info.type == "directory"
		and info.dev == expected.dev
		and info.ino == expected.ino
		and info.uid == expected.uid
		and bit.band(info.mode, 0x1FF) == tonumber("700", 8)
end

local function create_private_directory(path)
	local parent = vim.fs.dirname(path)
	local parent_info, parent_err = uv.fs_lstat(parent)
	if not parent_info or parent_info.type ~= "directory" then
		return nil, "cannot inspect target directory: " .. tostring(parent_err or "not a directory")
	end
	local writable_by_others = bit.band(parent_info.mode, tonumber("022", 8)) ~= 0
	local sticky = bit.band(parent_info.mode, tonumber("1000", 8)) ~= 0
	if writable_by_others and not sticky then
		return nil, "target directory is writable by other users without sticky protection"
	end
	temporary_counter = temporary_counter + 1
	local template = vim.fs.joinpath(
		parent,
		(".nvim-hex.%d.%s.%d.XXXXXX"):format(uv.os_getpid(), tostring(uv.hrtime()), temporary_counter)
	)
	local directory, create_err = uv.fs_mkdtemp(template)
	if not directory then
		return nil, "cannot create private temporary directory: " .. tostring(create_err)
	end
	local info, inspect_err = uv.fs_lstat(directory)
	if
		not info
		or info.type ~= "directory"
		or info.uid ~= uv.getuid()
		or bit.band(info.mode, 0x1FF) ~= tonumber("700", 8)
	then
		cleanup_private(nil, directory)
		return nil, "temporary directory is not private: " .. tostring(inspect_err or "identity mismatch")
	end
	return {
		dev = info.dev,
		directory = directory,
		ino = info.ino,
		temporary = vim.fs.joinpath(directory, "replacement"),
		uid = info.uid,
	}
end

local function metadata_matches(expected, actual)
	for _, key in ipairs({ "mode", "uid", "gid", "flags" }) do
		if expected[key] ~= nil and actual[key] ~= expected[key] then
			return false, key
		end
	end
	return true
end

local function copy_metadata_template(path, temporary, handle, reserved, expected, private)
	if not private_directory_matches(private.directory, private) then
		return nil, "private temporary directory changed before metadata copy"
	end
	local ok, process = pcall(vim.system, { "/bin/cp", "-p", path, temporary }, { text = false })
	if not ok then
		return nil, "cannot start metadata-preserving copy: " .. tostring(process)
	end
	local waited, result = pcall(function()
		return process:wait(config.timeout_ms)
	end)
	if not waited or type(result) ~= "table" or result.code ~= 0 then
		local detail = waited and sanitize(result and result.stderr) or sanitize(result)
		return nil, "metadata-preserving copy failed: " .. detail
	end
	if not private_directory_matches(private.directory, private) then
		return nil, "private temporary directory changed during metadata copy"
	end
	local copied_info, stat_err = uv.fs_fstat(handle)
	local copied_path, path_err = uv.fs_lstat(temporary)
	if not copied_info or not copied_path then
		return nil, "cannot inspect metadata-preserving copy: " .. tostring(stat_err or path_err)
	end
	local copied = identity_from_info(copied_info)
	local published_path = identity_from_info(copied_path)
	if copied.dev ~= reserved.dev or copied.ino ~= reserved.ino or not same_identity(copied, published_path) then
		return nil, "temporary file changed during metadata-preserving copy"
	end
	if copied.size ~= expected.size then
		return nil, "metadata-preserving copy has the wrong size"
	end
	local metadata_ok, field = metadata_matches(expected, copied)
	if not metadata_ok then
		return nil, "metadata-preserving copy changed " .. tostring(field)
	end
	return copied
end

local function write_bytes_atomic(path, data, expected)
	local before, inspect_err = file_identity(path)
	if not before then
		return nil, inspect_err
	end
	if bit.band(before.mode, 0xE00) ~= 0 then
		return nil, "target has setuid, setgid, or sticky mode bits and cannot be replaced safely"
	end
	if expected and not same_identity(expected, before) then
		return nil, "target changed since the hex view was created"
	end

	local private, private_err = create_private_directory(path)
	if not private then
		return nil, private_err
	end
	local temporary = private.temporary
	local handle, open_err = uv.fs_open(temporary, "wx+", tonumber("600", 8))
	if not handle then
		cleanup_private(nil, private.directory)
		return nil, "cannot create temporary file: " .. tostring(open_err)
	end
	local reserved_info, reserved_err = uv.fs_fstat(handle)
	local reserved = reserved_info and identity_from_info(reserved_info) or nil
	if not reserved then
		pcall(uv.fs_close, handle)
		cleanup_private(temporary, private.directory)
		return nil, "cannot inspect temporary file: " .. tostring(reserved_err)
	end
	local copied, copy_err = copy_metadata_template(path, temporary, handle, reserved, before, private)
	if not copied then
		pcall(uv.fs_close, handle)
		cleanup_private(temporary, private.directory)
		return nil, copy_err
	end
	local truncated, truncate_err = uv.fs_ftruncate(handle, 0)
	if not truncated then
		pcall(uv.fs_close, handle)
		cleanup_private(temporary, private.directory)
		return nil, "cannot truncate temporary file: " .. tostring(truncate_err)
	end

	local offset = 0
	while offset < #data do
		local written, write_err = uv.fs_write(handle, data:sub(offset + 1), offset)
		if not written or written <= 0 then
			pcall(uv.fs_close, handle)
			cleanup_private(temporary, private.directory)
			return nil, "cannot write temporary file: " .. tostring(write_err or "zero-byte write")
		end
		offset = offset + written
	end
	local temporary_info, stat_err = uv.fs_fstat(handle)
	local synced, sync_err = uv.fs_fsync(handle)
	local closed, close_err = uv.fs_close(handle)
	if not temporary_info or not synced or not closed then
		cleanup_private(temporary, private.directory)
		return nil, "cannot finalize temporary file: " .. tostring(stat_err or sync_err or close_err)
	end
	local prepared_metadata_ok, prepared_field = metadata_matches(before, identity_from_info(temporary_info))
	if not prepared_metadata_ok then
		cleanup_private(temporary, private.directory)
		return nil, "prepared replacement changed " .. tostring(prepared_field)
	end

	local current, current_err = file_identity(path)
	if not current or not same_identity(before, current) then
		cleanup_private(temporary, private.directory)
		return nil, current_err or "target changed while preparing the write"
	end
	if not private_directory_matches(private.directory, private) then
		cleanup_private(temporary, private.directory)
		return nil, "private temporary directory changed before atomic replacement"
	end
	local renamed, rename_err = uv.fs_rename(temporary, path)
	if not renamed then
		cleanup_private(temporary, private.directory)
		return nil, "cannot replace target atomically: " .. tostring(rename_err)
	end
	local removed_directory, remove_err = uv.fs_rmdir(private.directory)
	if not removed_directory then
		notify("Hex left an empty private temporary directory: " .. sanitize(remove_err), vim.log.levels.WARN)
	end
	local published, published_err = file_identity(path)
	local temporary_identity = identity_from_info(temporary_info)
	local metadata_ok = published and metadata_matches(before, published)
	if
		not published
		or published.dev ~= temporary_identity.dev
		or published.ino ~= temporary_identity.ino
		or published.size ~= temporary_identity.size
		or not metadata_ok
	then
		return nil, published_err or "target changed immediately after atomic replacement"
	end
	local published_data, verify_err = read_file(path, published)
	if published_data ~= data then
		return nil, verify_err or "published target bytes do not match the hex view"
	end
	return published
end

local function write_hex(buf, requested)
	local state = states[buf]
	if not state or vim.b[buf].hex ~= true then
		error("Hex write state is unavailable", 0)
	end
	local decoded, decode_err = decode_buffer(buf)
	if not decoded then
		local message = "Hex write aborted: " .. sanitize(decode_err)
		notify(message, vim.log.levels.ERROR)
		error(message, 0)
	end
	local path = buffer_path(buf)
	if not path then
		local message = "Hex write aborted: buffer is not backed by a named file"
		notify(message, vim.log.levels.ERROR)
		error(message, 0)
	end
	if type(requested) ~= "string" or requested == "" then
		local message = "Hex write aborted: write target is unavailable"
		notify(message, vim.log.levels.ERROR)
		error(message, 0)
	end
	local requested_path = path
	if not requested:match("^<buffer=%d+>$") then
		requested_path = normalized_target(requested)
	end
	if requested_path ~= path then
		local message = "Hex write aborted: assemble the hex view before writing another path"
		notify(message, vim.log.levels.ERROR)
		error(message, 0)
	end
	local identity, write_err = write_bytes_atomic(path, decoded, state.identity)
	if not identity then
		local message = "Hex write aborted: " .. sanitize(write_err)
		notify(message, vim.log.levels.ERROR)
		error(message, 0)
	end
	vim.bo[buf].modified = false
	state.identity = identity
	return true
end

local function install_write_autocmds(buf, state)
	state.write_autocmds = {
		vim.api.nvim_create_autocmd("BufWriteCmd", {
			group = write_group,
			buffer = buf,
			callback = function(event)
				write_hex(event.buf, event.file)
			end,
		}),
		vim.api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd" }, {
			group = write_group,
			buffer = buf,
			callback = function()
				error("Assemble the hex view before writing another path or range", 0)
			end,
		}),
	}
end

local function detach_lsp(buf)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, _uninitialized = true })) do
		pcall(vim.lsp.buf_detach_client, buf, client.id)
	end
end

local function enter_hex(buf, original)
	if vim.bo[buf].modified then
		return nil, "save or discard buffer changes before entering the hex view"
	end
	local path = buffer_path(buf)
	local identity, identity_err = file_identity(path)
	if not identity then
		return nil, identity_err
	end
	local bytes, read_err = read_file(path, identity)
	if not bytes then
		return nil, read_err
	end
	local output, render_err = run_xxd(bytes)
	if not output then
		return nil, render_err
	end
	local state = {
		identity = identity,
		options = original or options_snapshot(buf),
		write_autocmds = {},
	}
	local replaced, replace_err = replace_buffer(buf, output, {
		binary = true,
		bomb = false,
		filetype = "xxd",
		modified = false,
	})
	if not replaced then
		return nil, replace_err
	end
	states[buf] = state
	pending[buf] = nil
	vim.b[buf].hex = true
	vim.b[buf].hex_ft = state.options.filetype
	install_write_autocmds(buf, state)
	detach_lsp(buf)
	return true
end

function M.dump()
	local buf = vim.api.nvim_get_current_buf()
	if vim.b[buf].hex == true then
		notify("Buffer is already dumped", vim.log.levels.WARN)
		return false
	end
	if not buffer_path(buf) then
		notify("HexDump requires a named file buffer", vim.log.levels.ERROR)
		return false
	end
	local entered, err = enter_hex(buf)
	if not entered then
		notify("Hex dump failed: " .. sanitize(err), vim.log.levels.ERROR)
		return false
	end
	return true
end

function M.assemble()
	local buf = vim.api.nvim_get_current_buf()
	local state = states[buf]
	if vim.b[buf].hex ~= true or not state then
		notify("Buffer is already assembled", vim.log.levels.WARN)
		return false
	end
	local decoded, decode_err = decode_buffer(buf)
	if not decoded then
		notify("Hex assemble failed: " .. sanitize(decode_err), vim.log.levels.ERROR)
		return false
	end
	local view_modified = vim.bo[buf].modified
	local decoded_lines, decoded_endofline, conversion_err, decoded_bomb = decoded_buffer_lines(decoded, state.options)
	if not decoded_lines then
		notify("Hex assemble failed: " .. sanitize(conversion_err), vim.log.levels.ERROR)
		return false
	end
	local replaced, replace_err = replace_buffer(buf, decoded, {
		batched = vim.api.nvim_buf_line_count(buf) > REPLACE_BATCH_LINES,
		binary = state.options.binary,
		bomb = decoded_bomb,
		endofline = decoded_endofline,
		filetype = state.options.filetype,
		lines = decoded_lines,
		modified = view_modified,
		rollback_bytes = decoded,
	})
	if not replaced then
		notify("Hex assemble failed: " .. sanitize(replace_err), vim.log.levels.ERROR)
		return false
	end
	delete_write_autocmds(state)
	states[buf] = nil
	vim.b[buf].hex = false
	vim.b[buf].hex_ft = nil
	local restored_options = vim.deepcopy(state.options)
	restored_options.bomb = decoded_bomb
	restore_options(buf, restored_options, not view_modified)
	vim.bo[buf].modified = view_modified
	return true
end

function M.toggle()
	if vim.b.hex == true then
		return M.assemble()
	end
	return M.dump()
end

local function is_binary_pre_read(buf)
	local path = buffer_path(buf)
	if not path or vim.bo[buf].filetype ~= "" then
		return false
	end
	if vim.bo[buf].binary then
		return true
	end
	return binary_extensions[vim.fn.fnamemodify(path, ":e"):lower()] == true
end

local function is_binary_post_read(buf)
	local encoding = vim.bo[buf].fileencoding
	if encoding == "" then
		encoding = vim.o.encoding
	end
	return encoding:lower() ~= "utf-8"
end

local function clear_buffer_state(buf)
	local state = states[buf]
	if state then
		delete_write_autocmds(state)
	end
	states[buf] = nil
	pending[buf] = nil
end

local function reset_hex_before_read(buf)
	local state = states[buf]
	if not state then
		return
	end
	clear_buffer_state(buf)
	vim.b[buf].hex = false
	vim.b[buf].hex_ft = nil
	if vim.api.nvim_buf_is_valid(buf) then
		restore_options(buf, state.options, true)
	end
end

function M.setup(opts)
	opts = opts or {}
	for key in pairs(opts) do
		if key ~= "max_bytes" and key ~= "timeout_ms" then
			error("hex setup contains unknown option: " .. tostring(key))
		end
	end
	local max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES
	local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
	if type(max_bytes) ~= "number" or max_bytes % 1 ~= 0 or max_bytes < 1 or max_bytes > HARD_MAX_BYTES then
		error(("hex max_bytes must be an integer between 1 and %d"):format(HARD_MAX_BYTES))
	end
	if type(timeout_ms) ~= "number" or timeout_ms % 1 ~= 0 or timeout_ms < 1 or timeout_ms > HARD_TIMEOUT_MS then
		error(("hex timeout_ms must be an integer between 1 and %d"):format(HARD_TIMEOUT_MS))
	end
	local detected_xxd = vim.fn.exepath("xxd")
	if detected_xxd == "" then
		notify("xxd is not installed; hex editing is disabled", vim.log.levels.WARN)
		return false
	end
	config = { max_bytes = max_bytes, timeout_ms = timeout_ms }
	xxd_path = detected_xxd

	for _, command in ipairs({ "HexDump", "HexAssemble", "HexToggle" }) do
		pcall(vim.api.nvim_del_user_command, command)
	end
	vim.api.nvim_create_user_command("HexDump", M.dump, { desc = "Convert the current file to a hex view" })
	vim.api.nvim_create_user_command("HexAssemble", M.assemble, { desc = "Convert the current hex view to bytes" })
	vim.api.nvim_create_user_command("HexToggle", M.toggle, { desc = "Toggle the current file's hex view" })

	local group = vim.api.nvim_create_augroup("NvimConfigHex", { clear = true })
	write_group = group
	for buf, state in pairs(states) do
		state.write_autocmds = {}
		if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].hex == true then
			install_write_autocmds(buf, state)
		else
			states[buf] = nil
			pending[buf] = nil
		end
	end
	vim.api.nvim_create_autocmd("BufReadPre", {
		group = group,
		callback = function(event)
			reset_hex_before_read(event.buf)
			if is_binary_pre_read(event.buf) then
				pending[event.buf] = options_snapshot(event.buf)
				vim.bo[event.buf].binary = true
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		callback = function(event)
			local original = pending[event.buf]
			if original or is_binary_post_read(event.buf) then
				if original then
					original.endofline = vim.bo[event.buf].endofline
					original.bomb = vim.bo[event.buf].bomb
					original.fileencoding = vim.bo[event.buf].fileencoding
					original.fileformat = vim.bo[event.buf].fileformat
					original.filetype = vim.bo[event.buf].filetype
					original.fixendofline = vim.bo[event.buf].fixendofline
				else
					original = options_snapshot(event.buf)
				end
				local entered, err = enter_hex(event.buf, original)
				if not entered then
					pending[event.buf] = nil
					restore_options(event.buf, original, true)
					local message = "Hex dump failed: " .. sanitize(err)
					vim.schedule(function()
						notify(message, vim.log.levels.ERROR)
					end)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			clear_buffer_state(event.buf)
		end,
	})
	return M
end

function M.effective_config()
	return vim.deepcopy(config)
end

M._decode_lines = decode_lines
M._sanitize = sanitize
M.HARD_MAX_BYTES = HARD_MAX_BYTES

return M
