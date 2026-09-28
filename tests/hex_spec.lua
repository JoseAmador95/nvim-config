vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function write_bytes(path, data)
	local file = assert(io.open(path, "wb"))
	assert(file:write(data))
	assert(file:close())
end

local function read_bytes(path)
	local file = assert(io.open(path, "rb"))
	local data = assert(file:read("*a"))
	assert(file:close())
	return data
end

local function buffer_bytes()
	local data = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	if vim.bo.endofline then
		data = data .. "\n"
	end
	return data
end

local function xxd_lines(data)
	local result = vim.system({ "xxd", "-g", "1", "-u" }, { stdin = data }):wait()
	equal(0, result.code, "test fixture xxd failed")
	local output = result.stdout or ""
	if output == "" then
		return { "" }
	end
	assert(output:sub(-1) == "\n", "xxd fixture output lacks its final newline")
	return vim.split(output:sub(1, -2), "\n", { plain = true })
end

local function set_hex_bytes(data)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, xxd_lines(data))
	vim.bo.endofline = true
	vim.bo.modified = true
end

local function buffer_snapshot()
	return {
		binary = vim.bo.binary,
		bomb = vim.bo.bomb,
		endofline = vim.bo.endofline,
		fileencoding = vim.bo.fileencoding,
		fileformat = vim.bo.fileformat,
		filetype = vim.bo.filetype,
		fixendofline = vim.bo.fixendofline,
		lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
		modified = vim.bo.modified,
	}
end

local function reject_decode(hex, lines, expected)
	local decoded, err = hex._decode_lines(lines)
	assert(decoded == nil, "invalid xxd input was accepted")
	assert(tostring(err):find(expected, 1, true), "unexpected decode error: " .. tostring(err))
end

local function with_uv_override(name, replacement, callback)
	local original = vim.uv[name]
	vim.uv[name] = replacement
	local ok, err = xpcall(callback, debug.traceback)
	vim.uv[name] = original
	if not ok then
		error(err)
	end
end

local function edit(path)
	vim.cmd("enew!")
	vim.cmd.edit(vim.fn.fnameescape(path))
end

local original_cwd = assert(vim.uv.cwd())
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
vim.fn.chdir(fixture)
equal(vim.uv.fs_realpath(fixture), vim.uv.fs_realpath(assert(vim.uv.cwd())), "could not enter the fixture directory")

local plugin = require("plugins.hex")[1]
equal("config.hex", plugin.main, "hex.nvim does not use the host adapter")
assert(plugin.config == nil, "hex.nvim still runs its upstream setup")

local hex = require("config.hex")
hex.setup()

test("automatic dump treats a hostile binary filename as argv", function()
	local sentinel = vim.fs.joinpath(fixture, "hex-pwned")
	local path = vim.fs.joinpath(fixture, [[payload "$(touch hex-pwned)" `touch hex-pwned` ".bin]])
	local original = string.char(0, 1, 2, 10, 255, 65)
	write_bytes(path, original)

	edit(path)
	assert(vim.b.hex == true, "binary file was not detected automatically")
	equal("xxd", vim.bo.filetype, "binary file did not enter the xxd view")
	assert((vim.api.nvim_get_current_line() or ""):match("^00000000:"), "xxd output is missing")
	assert(vim.uv.fs_stat(sentinel) == nil, "hostile automatic filename executed shell code")

	vim.cmd("HexAssemble")
	assert(vim.b.hex == false, "HexAssemble left the buffer in hex mode")
	equal(original, buffer_bytes(), "HexAssemble did not recover the original bytes")
	assert(vim.uv.fs_stat(sentinel) == nil, "hostile assemble path executed shell code")

	vim.cmd("HexDump")
	assert(vim.b.hex == true, "manual HexDump did not enter hex mode")
	vim.cmd("HexToggle")
	assert(vim.b.hex == false, "HexToggle did not assemble the buffer")
	vim.cmd("HexToggle")
	assert(vim.b.hex == true, "HexToggle did not dump the buffer")
	assert(vim.uv.fs_stat(sentinel) == nil, "hostile manual filename executed shell code")
end)

test("writing a hostile binary path round-trips through the hex view", function()
	local sentinel = vim.fs.joinpath(fixture, "hex-pwned")
	local path = vim.fs.joinpath(fixture, [[write "$(touch hex-pwned)" `touch hex-pwned` ".bin]])
	write_bytes(path, "before")
	edit(path)

	local desired = string.char(0, 255, 65, 66, 67)
	set_hex_bytes(desired)
	vim.api.nvim_win_set_cursor(0, { 1, 7 })

	vim.cmd.write()
	equal(desired, read_bytes(path), "hex write changed the assembled bytes")
	assert(vim.b.hex == true, "write did not restore the hex view")
	equal("xxd", vim.bo.filetype, "write did not restore the xxd filetype")
	equal({ 1, 7 }, vim.api.nvim_win_get_cursor(0), "write did not restore the hex cursor")
	assert(vim.uv.fs_stat(sentinel) == nil, "hostile write filename executed shell code")

	vim.cmd("HexToggle")
	equal(desired, buffer_bytes(), "post-write HexToggle did not recover the saved bytes")
end)

test("all byte values round-trip and restore the original options", function()
	local chunks = {}
	for byte = 0, 255 do
		chunks[#chunks + 1] = string.char(byte)
	end
	local original = table.concat(chunks)
	local path = vim.fs.joinpath(fixture, "all-bytes.bin")
	write_bytes(path, original)

	edit(path)
	assert(vim.b.hex == true, "all-byte fixture did not enter hex mode")
	vim.cmd("HexAssemble")
	equal(original, buffer_bytes(), "all byte values did not survive assemble")
	equal(false, vim.bo.binary, "assemble did not restore the original binary option")
	equal("", vim.bo.filetype, "assemble did not restore the original filetype")
	equal(false, vim.bo.endofline, "assemble invented a final newline")
end)

test("dump and assemble never expose the other representation through undo", function()
	local path = vim.fs.joinpath(fixture, "undo-boundary.bin")
	local original = string.char(0, 1, 2, 65, 10, 66)
	write_bytes(path, original)

	edit(path)
	assert(vim.b.hex == true, "fixture did not enter hex mode")
	local dumped = buffer_snapshot()
	vim.cmd("silent! undo")
	equal(dumped, buffer_snapshot(), "undo crossed from the hex view into raw bytes")
	vim.cmd("silent! earlier 1")
	equal(dumped, buffer_snapshot(), "earlier crossed from the hex view into raw bytes")

	assert(hex.assemble(), "fixture did not assemble")
	local assembled = buffer_snapshot()
	assert(vim.b.hex == false, "assemble retained hex lifecycle state")
	vim.cmd("silent! undo")
	equal(assembled, buffer_snapshot(), "undo restored xxd text after leaving hex mode")
	vim.cmd("silent! earlier 1")
	equal(assembled, buffer_snapshot(), "earlier restored xxd text after leaving hex mode")
	equal(original, read_bytes(path), "undo boundary changed the file")
end)

test("manual dump rejects modified buffers without changing their state", function()
	local path = vim.fs.joinpath(fixture, "modified.txt")
	write_bytes(path, "clean\n")
	edit(path)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dirty" })
	vim.bo.modified = true
	local before = buffer_snapshot()

	assert(not hex.dump(), "HexDump accepted a modified buffer")
	equal(before, buffer_snapshot(), "rejected HexDump changed the buffer")
	equal("clean\n", read_bytes(path), "rejected HexDump changed the file")
end)

test("strict decoder rejects malformed, discontinuous, and oversized records", function()
	local canonical = xxd_lines("AB")[1]
	reject_decode(hex, { "not xxd" }, "canonical xxd record")
	reject_decode(hex, { "FFFFFFFF" .. canonical:sub(9) }, "non-contiguous xxd offset")
	reject_decode(hex, { canonical:sub(1, 10) .. "GG" .. canonical:sub(13) }, "invalid xxd byte field")
	local mismatched_ascii = canonical:sub(1, -2) .. (canonical:sub(-1) == "A" and "B" or "A")
	reject_decode(hex, { mismatched_ascii }, "ASCII column")
	reject_decode(hex, { xxd_lines("A")[1], xxd_lines("B")[1] }, "short final xxd record")

	hex.setup({ max_bytes = 16 })
	reject_decode(hex, xxd_lines(string.rep("A", 32)), "configured line limit")
	hex.setup()
end)

test("invalid hex writes fail without changing the file or view", function()
	local path = vim.fs.joinpath(fixture, "invalid-write.bin")
	write_bytes(path, "safe")
	edit(path)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "this is not xxd" })
	vim.bo.modified = true
	local before = buffer_snapshot()

	local wrote = pcall(vim.cmd.write)
	assert(not wrote, "invalid hex view reported a successful write")
	equal("safe", read_bytes(path), "invalid hex write changed the file")
	equal(before, buffer_snapshot(), "invalid hex write changed the view")
	assert(vim.b.hex == true, "invalid write left hex mode")
end)

test("writing another path never redirects or cleans the hex buffer", function()
	local path = vim.fs.joinpath(fixture, "write-source.bin")
	local destination = vim.fs.joinpath(fixture, "write-destination.bin")
	write_bytes(path, "source")
	edit(path)
	set_hex_bytes("changed")
	local before = buffer_snapshot()

	local wrote = pcall(vim.cmd, "write " .. vim.fn.fnameescape(destination))
	assert(not wrote, "hex view accepted a write to another path")
	equal("source", read_bytes(path), "redirected write changed the original path")
	assert(vim.uv.fs_lstat(destination) == nil, "redirected write created the destination")
	equal(before, buffer_snapshot(), "redirected write changed or cleaned the hex view")
end)

test("atomic write failure preserves the target and a retry succeeds", function()
	local path = vim.fs.joinpath(fixture, "atomic-failure.bin")
	write_bytes(path, "before")
	assert(vim.uv.fs_chmod(path, tonumber("640", 8)))
	edit(path)
	local desired = string.char(0, 255, 65, 10, 66)
	set_hex_bytes(desired)
	vim.api.nvim_win_set_cursor(0, { 1, 9 })
	local before = buffer_snapshot()

	with_uv_override("fs_write", function()
		return nil, "injected\27]8;;unsafe\7 write failure"
	end, function()
		local wrote = pcall(vim.cmd.write)
		assert(not wrote, "injected atomic write failure reported success")
	end)

	equal("before", read_bytes(path), "failed atomic write changed the target")
	equal(before, buffer_snapshot(), "failed atomic write changed the hex view")
	equal({ 1, 9 }, vim.api.nvim_win_get_cursor(0), "failed atomic write moved the cursor")
	equal({}, vim.fn.glob(vim.fs.joinpath(fixture, ".nvim-hex.*.tmp"), false, true), "failed write leaked a temp file")

	vim.cmd.write()
	equal(desired, read_bytes(path), "retry did not write the requested bytes")
	equal(tonumber("640", 8), assert(vim.uv.fs_lstat(path)).mode % 512, "atomic write changed permissions")
	assert(vim.b.hex == true, "successful write left hex mode")
	assert(not vim.bo.modified, "successful write left the hex view modified")
	equal({ 1, 9 }, vim.api.nvim_win_get_cursor(0), "successful write moved the cursor")

	set_hex_bytes("second")
	vim.cmd.write()
	equal("second", read_bytes(path), "a second atomic write used stale identity")
end)

test("atomic writes preserve extended metadata when the host exposes xattr", function()
	local xattr = vim.fn.exepath("xattr")
	if xattr == "" then
		return
	end
	local path = vim.fs.joinpath(fixture, "metadata.bin")
	local attribute = "com.openai.nvim-hex-test"
	write_bytes(path, "before")
	local wrote_attribute = vim.system({ xattr, "-w", attribute, "retained", path }):wait()
	equal(0, wrote_attribute.code, "could not create xattr fixture")

	edit(path)
	set_hex_bytes("after")
	vim.cmd.write()
	local read_attribute = vim.system({ xattr, "-p", attribute, path }):wait()
	equal(0, read_attribute.code, "atomic write removed the xattr")
	equal("retained", vim.trim(read_attribute.stdout or ""), "atomic write changed the xattr")
end)

test("atomic writes reject special mode bits before changing bytes or metadata", function()
	for _, special in ipairs({ tonumber("4000", 8), tonumber("2000", 8), tonumber("1000", 8) }) do
		local path = vim.fs.joinpath(fixture, ("special-%04o.bin"):format(special))
		write_bytes(path, "before")
		assert(vim.uv.fs_chmod(path, tonumber("755", 8)))
		edit(path)
		set_hex_bytes("after")
		local before = buffer_snapshot()
		local original_lstat = vim.uv.fs_lstat
		local original_open = vim.uv.fs_open
		local created_temporary = false
		local wrote
		with_uv_override("fs_lstat", function(candidate)
			local info, err = original_lstat(candidate)
			if info and vim.fs.basename(candidate) == vim.fs.basename(path) then
				info = vim.deepcopy(info)
				info.mode = bit.bor(info.mode, special)
			end
			return info, err
		end, function()
			with_uv_override("fs_open", function(candidate, flags, permissions)
				if candidate:find(".nvim%-hex%.", 1, false) then
					created_temporary = true
				end
				return original_open(candidate, flags, permissions)
			end, function()
				wrote = pcall(vim.cmd.write)
			end)
		end)
		assert(not wrote, ("write accepted special mode %04o"):format(special))
		assert(not created_temporary, "special-mode rejection created a temporary file")
		equal("before", read_bytes(path), ("write changed bytes for mode %04o"):format(special))
		equal(tonumber("755", 8), assert(vim.uv.fs_lstat(path)).mode % 512, "fixture permissions changed")
		equal(before, buffer_snapshot(), ("write changed the view for mode %04o"):format(special))
	end
end)

test("external target changes are never overwritten", function()
	local path = vim.fs.joinpath(fixture, "external-change.bin")
	write_bytes(path, "original")
	edit(path)
	set_hex_bytes("from-view")
	local before = buffer_snapshot()
	write_bytes(path, "external-change")

	local wrote = pcall(vim.cmd.write)
	assert(not wrote, "write overwrote an externally changed target")
	equal("external-change", read_bytes(path), "external target contents were lost")
	equal(before, buffer_snapshot(), "external-change rejection changed the view")
end)

test("short reads and post-rename races never report a successful write", function()
	local short = vim.fs.joinpath(fixture, "short-read.bin")
	write_bytes(short, "0123456789")
	with_uv_override("fs_read", function()
		return "0"
	end, function()
		edit(short)
	end)
	assert(vim.b.hex ~= true, "short read entered hex mode")
	equal("0123456789", read_bytes(short), "short read changed the target")

	local path = vim.fs.joinpath(fixture, "post-rename-race.bin")
	write_bytes(path, "before")
	edit(path)
	set_hex_bytes("desired")
	local before = buffer_snapshot()
	local original_rename = vim.uv.fs_rename
	with_uv_override("fs_rename", function(source, destination)
		local renamed, err = original_rename(source, destination)
		if renamed then
			write_bytes(destination, "replace")
		end
		return renamed, err
	end, function()
		local wrote = pcall(vim.cmd.write)
		assert(not wrote, "post-rename replacement reported success")
	end)
	equal("replace", read_bytes(path), "same-size post-rename competitor was overwritten")
	equal(before, buffer_snapshot(), "post-rename race cleaned or changed the hex view")
end)

test("decoder validates buffer bounds before fetching and reads valid data in batches", function()
	local data = string.rep("0123456789abcdef", 1250)
	local path = vim.fs.joinpath(fixture, "batched.bin")
	write_bytes(path, data)
	edit(path)
	local original_get_lines = vim.api.nvim_buf_get_lines
	local original_get_offset = vim.api.nvim_buf_get_offset
	local largest_batch = 0
	local offset_calls = 0
	vim.api.nvim_buf_get_offset = function(buf, row)
		offset_calls = offset_calls + 1
		return original_get_offset(buf, row)
	end
	vim.api.nvim_buf_get_lines = function(buf, first, last, strict)
		assert(last >= 0, "decoder requested every line at once")
		largest_batch = math.max(largest_batch, last - first)
		assert(last - first <= 1024, "decoder exceeded its line batch bound")
		return original_get_lines(buf, first, last, strict)
	end
	local ok, assembled = xpcall(hex.assemble, debug.traceback)
	vim.api.nvim_buf_get_lines = original_get_lines
	vim.api.nvim_buf_get_offset = original_get_offset
	assert(ok and assembled, tostring(assembled))
	assert(largest_batch > 0 and largest_batch <= 1024)
	local rendered_lines = math.ceil(#data / 16)
	assert(
		offset_calls <= 1 + 2 * math.ceil(rendered_lines / 1024),
		("decoder made %d offset calls for %d lines"):format(offset_calls, rendered_lines)
	)
	equal(data, buffer_bytes(), "batched decoder changed bytes")

	write_bytes(path, "small")
	edit(path)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 1000) })
	vim.bo.modified = true
	vim.api.nvim_buf_get_lines = function()
		error("oversized line was fetched")
	end
	ok, assembled = xpcall(hex.assemble, debug.traceback)
	vim.api.nvim_buf_get_lines = original_get_lines
	assert(ok and not assembled, "oversized rendered line reached the decoder")
end)

test("reloading or replacing a hex buffer resets and rebuilds its lifecycle", function()
	local path = vim.fs.joinpath(fixture, "reload.bin")
	local original = string.char(0, 1, 65, 10)
	write_bytes(path, original)
	edit(path)
	set_hex_bytes("discarded")
	vim.cmd("edit!")
	assert(vim.b.hex == true and vim.bo.filetype == "xxd", "edit! did not rebuild the hex view")
	assert(hex.assemble(), "reloaded hex view did not assemble")
	equal(original, buffer_bytes(), "edit! kept stale edited hex contents")
	equal(original, read_bytes(path), "edit! changed the file")

	local canonical = xxd_lines("A")[1] .. "\n"
	local canonical_path = vim.fs.joinpath(fixture, "canonical-looking.bin")
	write_bytes(canonical_path, canonical)
	edit(canonical_path)
	assert(vim.b.hex == true, "canonical-looking raw file did not enter hex mode")
	vim.cmd("edit!")
	assert(vim.b.hex == true and vim.bo.filetype == "xxd", "reload left raw bytes under a hex lifecycle")
	vim.cmd.write()
	equal(canonical, read_bytes(canonical_path), "reload decoded canonical-looking raw bytes as a hex view")

	local text = vim.fs.joinpath(fixture, "after-hex.txt")
	write_bytes(text, "plain text\n")
	vim.cmd.edit(vim.fn.fnameescape(text))
	assert(vim.b.hex ~= true, "editing a text file inherited hex lifecycle state")
	equal("plain text\n", buffer_bytes(), "editing a text file retained xxd contents")
end)

test("automatic hex mode refuses links and oversized files", function()
	local target = vim.fs.joinpath(fixture, "symlink-target")
	local link = vim.fs.joinpath(fixture, "symlink.bin")
	write_bytes(target, "target")
	assert(vim.uv.fs_symlink(target, link))
	edit(link)
	assert(vim.b.hex ~= true, "symlink entered automatic hex mode")
	equal("target", buffer_bytes(), "symlink rejection changed the buffer")

	local hardlink = vim.fs.joinpath(fixture, "hardlink.bin")
	assert(vim.uv.fs_link(target, hardlink))
	edit(hardlink)
	assert(vim.b.hex ~= true, "hardlink entered automatic hex mode")
	equal("target", read_bytes(target), "hardlink rejection changed the shared inode")

	hex.setup({ max_bytes = 16 })
	local large = vim.fs.joinpath(fixture, "too-large.bin")
	write_bytes(large, string.rep("x", 17))
	edit(large)
	assert(vim.b.hex ~= true, "oversized file entered automatic hex mode")
	equal(string.rep("x", 17), buffer_bytes(), "oversized rejection changed the buffer")
	hex.setup()
end)

test("CRLF files leave hex mode with their text options intact", function()
	local path = vim.fs.joinpath(fixture, "dos.txt")
	write_bytes(path, "one\r\ntwo\r\n")
	edit(path)
	local before = buffer_snapshot()
	equal("dos", before.fileformat, "fixture was not detected as DOS text")
	assert(hex.dump(), "manual CRLF dump failed")
	assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("0D 0A", 1, true), "hex view lost CRLF bytes")
	assert(hex.assemble(), "manual CRLF assemble failed")
	equal(before, buffer_snapshot(), "CRLF assemble did not restore text state")
end)

test("BOM files assemble and write without duplicating their marker", function()
	local utf8 = vim.fs.joinpath(fixture, "utf8-bom.txt")
	write_bytes(utf8, "\239\187\191A\n")
	edit(utf8)
	assert(vim.bo.bomb, "UTF-8 BOM fixture did not set bomb")
	assert(hex.dump(), "manual UTF-8 BOM dump failed")
	assert(hex.assemble(), "manual UTF-8 BOM assemble failed")
	equal({ "A" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "UTF-8 BOM became buffer content")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "B" })
	vim.cmd.write()
	equal("\239\187\191B\n", read_bytes(utf8), "UTF-8 BOM was duplicated or removed")

	local utf16 = vim.fs.joinpath(fixture, "utf16le.txt")
	write_bytes(utf16, "\255\254A\0\n\0")
	edit(utf16)
	assert(vim.b.hex == true, "UTF-16LE file did not enter automatic hex mode")
	assert(hex.assemble(), "UTF-16LE assemble failed")
	equal({ "A" }, vim.api.nvim_buf_get_lines(0, 0, -1, false), "UTF-16LE BOM became buffer content")
	assert(vim.bo.bomb and vim.bo.fileencoding == "utf-16le", "UTF-16LE options were not restored")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "B" })
	vim.cmd.write()
	equal("\255\254B\0\n\0", read_bytes(utf16), "UTF-16LE BOM was duplicated or removed")
end)

test("binary mode treats a leading BOM marker as payload", function()
	local path = vim.fs.joinpath(fixture, "binary-bom.dat")
	local original = "\239\187\191A"
	write_bytes(path, original)
	edit(path)
	vim.bo.binary = true
	vim.bo.bomb = true
	vim.bo.endofline = false
	assert(hex.dump(), "manual binary BOM dump failed")
	assert(hex.assemble(), "manual binary BOM assemble failed")
	equal(original, buffer_bytes(), "binary assemble removed the BOM payload")
	assert(vim.bo.binary and vim.bo.bomb and not vim.bo.endofline, "binary BOM options were not restored")
	vim.cmd.write()
	equal(original, read_bytes(path), "binary write removed or duplicated the BOM payload")
end)

test("a BOM incompatible with fileencoding is rejected without normalization", function()
	local path = vim.fs.joinpath(fixture, "mismatched-bom.txt")
	write_bytes(path, "\239\187\191A\n")
	edit(path)
	assert(hex.dump(), "manual BOM dump failed")
	set_hex_bytes("\255\254A\n")
	local before = buffer_snapshot()
	assert(not hex.assemble(), "mismatched BOM was accepted")
	equal(before, buffer_snapshot(), "mismatched BOM rejection changed the view")
	equal("\239\187\191A\n", read_bytes(path), "mismatched BOM rejection changed the file")
end)

test("invalid encoded byte sequences never reach iconv or change the view", function()
	local utf16 = vim.fs.joinpath(fixture, "invalid-utf16le.txt")
	local valid_utf16 = "\255\254A\0"
	write_bytes(utf16, valid_utf16)
	edit(utf16)
	assert(vim.b.hex == true and vim.bo.fileencoding == "utf-16le", "UTF-16LE fixture was not detected")
	for _, invalid in ipairs({
		"\255\254A",
		"\255\254\0\216",
		"\255\254\0\220",
		"\255\254\0\216A\0",
	}) do
		set_hex_bytes(invalid)
		local before = buffer_snapshot()
		assert(not hex.assemble(), "invalid UTF-16LE bytes were assembled")
		equal(before, buffer_snapshot(), "invalid UTF-16LE assemble changed the hex view")
		equal(valid_utf16, read_bytes(utf16), "invalid UTF-16LE assemble changed the file")
	end

	local utf32 = vim.fs.joinpath(fixture, "invalid-utf32le.txt")
	local valid_utf32 = "\255\254\0\0A\0\0\0"
	write_bytes(utf32, valid_utf32)
	edit(utf32)
	assert(
		vim.b.hex == true and (vim.bo.fileencoding == "utf-32le" or vim.bo.fileencoding == "ucs-4le"),
		"UTF-32LE fixture was not detected"
	)
	for _, invalid in ipairs({
		"\255\254\0\0A\0\0",
		"\255\254\0\0\0\0\17\0",
		"\255\254\0\0\0\216\0\0",
	}) do
		set_hex_bytes(invalid)
		local before = buffer_snapshot()
		assert(not hex.assemble(), "invalid UTF-32LE bytes were assembled")
		equal(before, buffer_snapshot(), "invalid UTF-32LE assemble changed the hex view")
		equal(valid_utf32, read_bytes(utf32), "invalid UTF-32LE assemble changed the file")
	end

	local utf8 = vim.fs.joinpath(fixture, "invalid-utf8.txt")
	local valid_utf8 = "\239\187\191A"
	write_bytes(utf8, valid_utf8)
	edit(utf8)
	vim.bo.fileencoding = "utf-8"
	assert(hex.dump(), "explicit UTF-8 fixture did not enter hex mode")
	for _, invalid in ipairs({ "\239\187\191\192\175", "\239\187\191\237\160\128", "\239\187\191\244\144\128\128" }) do
		set_hex_bytes(invalid)
		local before = buffer_snapshot()
		assert(not hex.assemble(), "invalid UTF-8 bytes were assembled")
		equal(before, buffer_snapshot(), "invalid UTF-8 assemble changed the hex view")
		equal(valid_utf8, read_bytes(utf8), "invalid UTF-8 assemble changed the file")
	end
end)

test("failed setup reentry preserves the active lifecycle transactionally", function()
	hex.setup({ max_bytes = 64, timeout_ms = 1000 })
	local path = vim.fs.joinpath(fixture, "setup-reentry.bin")
	write_bytes(path, "active")
	edit(path)
	assert(vim.b.hex == true, "fixture did not enter hex mode")
	local before = hex.effective_config()
	local original_path = vim.env.PATH
	vim.env.PATH = ""
	local configured = hex.setup({ max_bytes = 1, timeout_ms = 1 })
	vim.env.PATH = original_path
	assert(configured == false, "setup succeeded without xxd")
	equal(before, hex.effective_config(), "failed setup reentry published partial config")
	assert(vim.fn.exists(":HexToggle") == 2, "failed setup removed the previous commands")
	assert(hex.assemble(), "failed setup broke the active assemble handler")
	assert(hex.dump(), "failed setup replaced the prior xxd path or byte limit")
	hex.setup()
end)

test("errors are control-free, UTF-8 safe, bounded, and setup options are strict", function()
	local sanitized = hex._sanitize(string.rep("é", 200) .. "\0\27]8;;unsafe\7\194\128\n")
	assert(#sanitized <= 259, "sanitized error exceeded its bound")
	assert(not sanitized:find("[%z\1-\31\127]"), "sanitized error retained a control byte")
	assert(not sanitized:find("\194\128", 1, true), "sanitized error retained a C1 control")
	assert(vim.iconv(sanitized:sub(1, -4), "utf-8", "utf-16le"), "sanitized error ended in broken UTF-8")

	for _, opts in ipairs({
		{ unknown = true },
		{ max_bytes = 0 },
		{ max_bytes = hex.HARD_MAX_BYTES + 1 },
		{ max_bytes = 1.5 },
		{ timeout_ms = 0 },
		{ timeout_ms = 30001 },
	}) do
		assert(not pcall(hex.setup, opts), "invalid setup options were accepted: " .. vim.inspect(opts))
	end
	hex.setup()
end)

test("manual dump rejects unnamed buffers without invoking xxd", function()
	vim.cmd("enew!")
	assert(not hex.dump(), "HexDump accepted an unnamed buffer")
	assert(vim.b.hex ~= true, "unnamed buffer entered hex mode")
end)

vim.cmd("enew!")
vim.fn.chdir(original_cwd)
assert(vim.fn.delete(fixture, "rf") == 0)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("hex_spec: %d tests passed", count))
vim.cmd("quitall!")
