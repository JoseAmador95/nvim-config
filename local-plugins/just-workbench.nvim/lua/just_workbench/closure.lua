local M = {}

local uv = vim.uv
local MAX_FILE_BYTES = 1024 * 1024
local MAX_TOTAL_BYTES = 8 * MAX_FILE_BYTES
local MAX_FILES = 128

local function valid_string(value)
	return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
end

local function decode_quoted(value)
	local quote = value:sub(1, 1)
	if quote ~= "'" and quote ~= '"' then
		return nil, "path must be a quoted string"
	end
	local result = {}
	local index = 2
	while index <= #value do
		local char = value:sub(index, index)
		if char == quote then
			if value:sub(index + 1):match("^%s*$") then
				local decoded = table.concat(result)
				if decoded == "" or decoded:find("\0", 1, true) then
					return nil, "path must not be empty or contain NUL"
				end
				return decoded
			end
			return nil, "unexpected text after quoted path"
		end
		if char == "\\" and quote == '"' then
			local escaped = value:sub(index + 1, index + 1)
			local replacements = { ['"'] = '"', ["\\"] = "\\", n = "\n", r = "\r", t = "\t" }
			if replacements[escaped] == nil then
				return nil, "unsupported escape in path"
			end
			result[#result + 1] = replacements[escaped]
			index = index + 2
		else
			result[#result + 1] = char
			index = index + 1
		end
	end
	return nil, "unterminated quoted path"
end

local function strip_comment(line)
	local quote
	local escaped = false
	for index = 1, #line do
		local char = line:sub(index, index)
		if quote then
			if quote == '"' and char == "\\" and not escaped then
				escaped = true
			elseif char == quote and not escaped then
				quote = nil
			else
				escaped = false
			end
		elseif char == "'" or char == '"' then
			quote = char
		elseif char == "#" then
			return line:sub(1, index - 1)
		end
	end
	return line
end

local function parse_directives(contents, path)
	local directives = {}
	local line_number = 0
	for raw in (contents .. "\n"):gmatch("(.-)\n") do
		line_number = line_number + 1
		if raw ~= "" and not raw:match("^%s") then
			local line = vim.trim(strip_comment(raw))
			if line:match("^import[%?%s]") then
				local optional, rest = line:match("^import(%??)%s+(.+)$")
				if not rest then
					return nil, ("%s:%d: malformed import statement"):format(path, line_number)
				end
				local target, target_err = decode_quoted(rest)
				if not target then
					return nil, ("%s:%d: %s"):format(path, line_number, target_err)
				end
				directives[#directives + 1] = { kind = "import", optional = optional == "?", target = target }
			elseif line:match("^mod[%?%s]") then
				local optional, name, rest = line:match("^mod(%??)%s+([%w_%-]+)%s*(.*)$")
				if not name then
					return nil, ("%s:%d: malformed module statement"):format(path, line_number)
				end
				local target
				if rest ~= "" then
					local target_err
					target, target_err = decode_quoted(rest)
					if not target then
						return nil, ("%s:%d: %s"):format(path, line_number, target_err)
					end
				end
				directives[#directives + 1] = {
					kind = "module",
					name = name,
					optional = optional == "?",
					target = target,
				}
			end
		end
	end
	return directives
end

local function absolute_target(base, target, home)
	if target:sub(1, 2) == "~/" then
		if not valid_string(home) or home:sub(1, 1) ~= "/" then
			return nil, "HOME is required to resolve ~/ paths"
		end
		return vim.fs.normalize(vim.fs.joinpath(home, target:sub(3)))
	end
	if target:sub(1, 1) == "/" then
		return vim.fs.normalize(target)
	end
	return vim.fs.normalize(vim.fs.joinpath(base, target))
end

local function directory_module(path)
	local stat = uv.fs_stat(path)
	if not stat or stat.type ~= "directory" then
		return path
	end
	for _, name in ipairs({ "mod.just", "justfile", ".justfile" }) do
		local candidate = vim.fs.joinpath(path, name)
		local candidate_stat = uv.fs_stat(candidate)
		if candidate_stat and candidate_stat.type == "file" then
			return candidate
		end
	end
	local handle = uv.fs_scandir(path)
	if handle then
		while true do
			local name, kind = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local lower = name:lower()
			if kind == "file" and (lower == "justfile" or lower == ".justfile") then
				return vim.fs.joinpath(path, name)
			end
		end
	end
	return vim.fs.joinpath(path, "mod.just")
end

local function default_module(base, name)
	local candidates = {
		vim.fs.joinpath(base, name .. ".just"),
		vim.fs.joinpath(base, name, "mod.just"),
		vim.fs.joinpath(base, name, "justfile"),
		vim.fs.joinpath(base, name, ".justfile"),
	}
	for _, candidate in ipairs(candidates) do
		local stat = uv.fs_stat(candidate)
		if stat and stat.type == "file" then
			return candidate
		end
	end
	return candidates[1]
end

local function read_regular(path)
	local lexical = vim.fs.normalize(path)
	if lexical:sub(1, 1) ~= "/" or lexical:find("\0", 1, true) then
		return nil, "source path must be absolute"
	end
	local link_stat = uv.fs_lstat(lexical)
	if not link_stat then
		return nil, "source does not exist: " .. lexical
	end
	if link_stat.type ~= "file" then
		return nil, "source must be a regular non-symlink file: " .. lexical
	end
	local canonical = uv.fs_realpath(lexical)
	if not canonical then
		return nil, "source could not be resolved: " .. lexical
	end
	local fd, open_err = uv.fs_open(canonical, "r", 0)
	if not fd then
		return nil, tostring(open_err)
	end
	local stat, stat_err = uv.fs_fstat(fd)
	if not stat or stat.type ~= "file" or stat.size > MAX_FILE_BYTES then
		uv.fs_close(fd)
		return nil, stat_err or ("source exceeds %d bytes: %s"):format(MAX_FILE_BYTES, canonical)
	end
	local contents, read_err = uv.fs_read(fd, stat.size, 0)
	local closed, close_err = uv.fs_close(fd)
	if contents == nil or not closed then
		return nil, tostring(read_err or close_err)
	end
	local after = uv.fs_lstat(canonical)
	if
		not after
		or after.type ~= "file"
		or after.dev ~= stat.dev
		or after.ino ~= stat.ino
		or after.size ~= stat.size
		or after.mtime.sec ~= stat.mtime.sec
		or after.mtime.nsec ~= stat.mtime.nsec
	then
		return nil, "source changed while it was read: " .. canonical
	end
	return { path = canonical, contents = contents, size = stat.size }
end

local function same_entries(left, right)
	if #left ~= #right then
		return false
	end
	for index, entry in ipairs(left) do
		local other = right[index]
		if entry.path ~= other.path or entry.digest ~= other.digest then
			return false
		end
	end
	return true
end

function M.scan(root_path, opts)
	opts = opts or {}
	local hash = opts.hash or vim.fn.sha256
	local trust = opts.trust
	if type(hash) ~= "function" then
		return nil, "hash must be a function"
	end
	if opts.authorize ~= false and type(trust) ~= "function" then
		return nil, "trust must be a function"
	end

	local state = { entries = {}, imports = {}, modules = {}, seen = {}, total = 0 }
	local function visit(path, optional, relation)
		local source, source_err = read_regular(path)
		if not source then
			if optional and not uv.fs_lstat(path) then
				return true
			end
			return nil, source_err
		end
		if state.seen[source.path] then
			return true
		end
		if #state.entries >= MAX_FILES then
			return nil, ("closure exceeds %d files"):format(MAX_FILES)
		end
		state.total = state.total + source.size
		if state.total > MAX_TOTAL_BYTES then
			return nil, ("closure exceeds %d bytes"):format(MAX_TOTAL_BYTES)
		end
		local digest = hash(source.contents)
		if not valid_string(digest) then
			return nil, "hash returned an invalid digest"
		end
		if opts.authorize ~= false then
			local ok, trusted, trust_err = pcall(trust, source.path, source.contents, digest)
			if not ok or trusted ~= true then
				return nil, tostring(ok and trust_err or trusted or ("source was not trusted: " .. source.path))
			end
		end
		state.seen[source.path] = true
		state.entries[#state.entries + 1] = { path = source.path, digest = digest, size = source.size }
		if relation then
			local item = { from = relation.from, path = source.path }
			if relation.kind == "module" then
				item.name = relation.name
				state.modules[#state.modules + 1] = item
			else
				state.imports[#state.imports + 1] = item
			end
		end

		local directives, directives_err = parse_directives(source.contents, source.path)
		if not directives then
			return nil, directives_err
		end
		local base = vim.fs.dirname(source.path)
		for _, directive in ipairs(directives) do
			local child
			if directive.kind == "import" then
				child = absolute_target(base, directive.target, opts.home)
			else
				child = directive.target and absolute_target(base, directive.target, opts.home)
					or default_module(base, directive.name)
				child = child and directory_module(child)
			end
			if not child then
				return nil, "could not resolve " .. directive.kind
			end
			local visited, visit_err = visit(child, directive.optional, {
				kind = directive.kind,
				name = directive.name,
				from = source.path,
			})
			if not visited then
				return nil, visit_err
			end
		end
		return true
	end

	local ok, err = visit(root_path, false)
	if not ok then
		return nil, err
	end
	table.sort(state.entries, function(left, right)
		return left.path < right.path
	end)
	table.sort(state.imports, function(left, right)
		return left.path < right.path
	end)
	table.sort(state.modules, function(left, right)
		return left.path < right.path
	end)
	state.fingerprint = hash(vim.json.encode(state.entries))
	state.seen = nil
	state.total = nil
	return vim.deepcopy(state)
end

function M.equal(left, right)
	return type(left) == "table"
		and type(right) == "table"
		and left.fingerprint == right.fingerprint
		and same_entries(left.entries or {}, right.entries or {})
end

M._parse_directives = parse_directives
M.MAX_FILE_BYTES = MAX_FILE_BYTES
M.MAX_TOTAL_BYTES = MAX_TOTAL_BYTES
M.MAX_FILES = MAX_FILES

return M
