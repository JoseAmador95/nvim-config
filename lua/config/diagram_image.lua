-- Resolve a Markdown image reference to a local file and hand the diagram
-- viewer an SVG document it can rasterize. Wrapping a raster image in SVG keeps
-- the existing rsvg-convert pipeline — and therefore its zoom, pan, cache, and
-- cancellation — without adding a second image tool.
--
-- Remote references stay unrendered on purpose: the reading view disables the
-- renderer's automatic media for the same reason, and an explicit keypress must
-- not become a network fetch.
local M = {}

M.MAX_BYTES = 8 * 1024 * 1024

local MEDIA = {
	png = "image/png",
	jpeg = "image/jpeg",
	gif = "image/gif",
}

local SOF_MARKERS = {
	[0xC0] = true,
	[0xC1] = true,
	[0xC2] = true,
	[0xC3] = true,
	[0xC5] = true,
	[0xC6] = true,
	[0xC7] = true,
	[0xC9] = true,
	[0xCA] = true,
	[0xCB] = true,
	[0xCD] = true,
	[0xCE] = true,
	[0xCF] = true,
}

local function be16(data, offset)
	local high, low = data:byte(offset, offset + 1)
	if not low then
		return nil
	end
	return high * 256 + low
end

local function be32(data, offset)
	local a, b, c, d = data:byte(offset, offset + 3)
	if not d then
		return nil
	end
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le16(data, offset)
	local low, high = data:byte(offset, offset + 1)
	if not high then
		return nil
	end
	return high * 256 + low
end

local function png_size(data)
	if data:sub(1, 8) ~= "\137PNG\r\n\26\n" or data:sub(13, 16) ~= "IHDR" then
		return nil
	end
	return be32(data, 17), be32(data, 21)
end

local function gif_size(data)
	local signature = data:sub(1, 6)
	if signature ~= "GIF87a" and signature ~= "GIF89a" then
		return nil
	end
	return le16(data, 7), le16(data, 9)
end

local function jpeg_size(data)
	if data:sub(1, 2) ~= "\255\216" then
		return nil
	end
	local pos = 3
	while pos + 3 <= #data do
		if data:byte(pos) ~= 0xFF then
			return nil
		end
		local marker = data:byte(pos + 1)
		-- Fill bytes repeat 0xFF before the real marker.
		while marker == 0xFF and pos + 2 <= #data do
			pos = pos + 1
			marker = data:byte(pos + 1)
		end
		if marker == 0xD8 or marker == 0xD9 or (marker >= 0xD0 and marker <= 0xD7) then
			pos = pos + 2
		else
			local length = be16(data, pos + 2)
			if not length or length < 2 then
				return nil
			end
			if SOF_MARKERS[marker] then
				local height = be16(data, pos + 5)
				local width = be16(data, pos + 7)
				if width and height and width > 0 and height > 0 then
					return width, height
				end
				return nil
			end
			pos = pos + 2 + length
		end
	end
	return nil
end

local function svg_like(data)
	local head = data:sub(1, 1024)
	if head:byte(1) == 0xEF then
		head = head:sub(4)
	end
	head = head:gsub("^%s+", "")
	if head:sub(1, 4) == "<svg" then
		return true
	end
	if head:sub(1, 2) == "<?" or head:sub(1, 4) == "<!--" or head:sub(1, 2) == "<!" then
		return head:find("<svg", 1, true) ~= nil
	end
	return false
end

---Classify the bytes and return the raster size when there is one.
---@param data string
---@return string|nil format "png"|"jpeg"|"gif"|"svg"
---@return integer|nil width
---@return integer|nil height
function M.identify(data)
	if type(data) ~= "string" or data == "" then
		return nil
	end
	local width, height = png_size(data)
	if width then
		return "png", width, height
	end
	width, height = jpeg_size(data)
	if width then
		return "jpeg", width, height
	end
	width, height = gif_size(data)
	if width then
		return "gif", width, height
	end
	if svg_like(data) then
		return "svg"
	end
	return nil
end

local function percent_decode(text)
	return (text:gsub("%%(%x%x)", function(pair)
		return string.char(tonumber(pair, 16))
	end))
end

---Resolve an image reference against the owning buffer's directory.
---@param link string
---@param base_dir string|nil
---@return string|nil path, string|nil error
function M.resolve(link, base_dir)
	if type(link) ~= "string" then
		return nil, "the image reference is not text"
	end
	link = vim.trim(link)
	local angled = link:match("^<(.*)>$")
	if angled then
		link = vim.trim(angled)
	end
	if link == "" then
		return nil, "the image reference is empty"
	end
	if link:sub(1, 2) == "//" then
		return nil, "remote images are not rendered: " .. link
	end
	local scheme = link:match("^(%a[%w%+%-%.]*):")
	if scheme then
		return nil, ("remote images are not rendered (%s: reference): %s"):format(scheme:lower(), link)
	end
	-- Strip a trailing fragment before decoding: a percent-encoded "#" is part of
	-- the filename, so decoding first would truncate a legitimate path.
	link = percent_decode((link:gsub("#[^/#]*$", "")))
	if link == "" then
		return nil, "the image reference has no path"
	end
	local path
	if link:sub(1, 1) == "~" then
		path = vim.fn.expand(link)
	elseif link:sub(1, 1) == "/" then
		path = link
	else
		if type(base_dir) ~= "string" or base_dir == "" then
			return nil, "the buffer has no directory to resolve a relative image: " .. link
		end
		path = vim.fs.joinpath(base_dir, link)
	end
	path = vim.fs.normalize(path)
	local real = vim.uv.fs_realpath(path)
	if not real then
		return nil, "image not found: " .. path
	end
	local stat = vim.uv.fs_stat(real)
	if not stat or stat.type ~= "file" then
		return nil, "image is not a regular file: " .. real
	end
	return vim.fs.normalize(real)
end

local function read_file(path, limit)
	local fd, open_err = vim.uv.fs_open(path, "r", 384)
	if not fd then
		return nil, "could not open the image: " .. tostring(open_err)
	end
	local info, stat_err = vim.uv.fs_fstat(fd)
	if not info then
		vim.uv.fs_close(fd)
		return nil, "could not inspect the image: " .. tostring(stat_err)
	end
	if info.size > limit then
		vim.uv.fs_close(fd)
		return nil,
			("the image is %.1f MiB, over the %.1f MiB viewer limit"):format(info.size / 1048576, limit / 1048576)
	end
	local data, read_err = vim.uv.fs_read(fd, info.size, 0)
	vim.uv.fs_close(fd)
	if not data then
		return nil, "could not read the image: " .. tostring(read_err)
	end
	return data
end

---Wrap raster bytes in a minimal SVG that carries the image inline.
---@param data string
---@param media string
---@param width integer
---@param height integer
---@return string
function M.wrap(data, media, width, height)
	return table.concat({
		'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"',
		(' width="%d" height="%d" viewBox="0 0 %d %d">'):format(width, height, width, height),
		('<image x="0" y="0" width="%d" height="%d" preserveAspectRatio="none"'):format(width, height),
		(' xlink:href="data:%s;base64,%s"/>'):format(media, vim.base64.encode(data)),
		"</svg>",
	})
end

---Read a resolved image and return the SVG source the renderer rasterizes.
---@param path string
---@param limit integer|nil byte ceiling, defaults to M.MAX_BYTES
---@return table|nil loaded { source, format, width?, height?, bytes }
---@return string|nil error
function M.load(path, limit)
	local data, read_err = read_file(path, limit or M.MAX_BYTES)
	if not data then
		return nil, read_err
	end
	local format, width, height = M.identify(data)
	if not format then
		return nil, "unsupported image format (the viewer renders PNG, JPEG, GIF and SVG): " .. path
	end
	if format == "svg" then
		return { source = data, format = format, bytes = #data }
	end
	if not width or not height or width < 1 or height < 1 then
		return nil, "the image reports no usable size: " .. path
	end
	return {
		source = M.wrap(data, MEDIA[format], width, height),
		format = format,
		width = width,
		height = height,
		bytes = #data,
	}
end

return M
