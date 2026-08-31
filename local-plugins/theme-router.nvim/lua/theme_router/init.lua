local M = {}

local STATE_VERSION = 1
local MAX_STATE_BYTES = 64 * 1024
local FILE_MODE = 384 -- 0600
local DIRECTORY_MODE = 448 -- 0700

local state = {
	configured = false,
	opts = nil,
	painters = {},
	selection = nil,
}

local function copy(value)
	return vim.deepcopy(value)
end

local function nonempty_string(value, label)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	return value
end

local function colorscheme_name(value, label)
	local name, err = nonempty_string(value, label)
	if not name then
		return nil, err
	end
	if name:find("[^%w_.@+/%-]") then
		return nil, label .. " contains unsupported characters"
	end
	return name
end

local function notify(message, level)
	if not state.opts or not state.opts.notify then
		return
	end
	pcall(state.opts.notify, message, level)
end

local function emit(kind, details)
	if not state.opts or not state.opts.event then
		return
	end
	local event = copy(details or {})
	event.kind = kind
	local ok, err = pcall(state.opts.event, event)
	if not ok then
		notify("Theme event callback failed: " .. tostring(err), vim.log.levels.WARN)
	end
end

local function lstat(path)
	local info, err = vim.uv.fs_lstat(path)
	if not info and err and not tostring(err):find("ENOENT", 1, true) then
		return nil, err
	end
	return info
end

local function inspect_parent(create)
	local parent = vim.fs.dirname(state.opts.state_path)
	local info, err = lstat(parent)
	if err then
		return nil, "Could not inspect theme state directory: " .. tostring(err)
	end
	if info then
		if info.type ~= "directory" then
			return nil, "Theme state directory must be real; symlinks and non-directories are rejected"
		end
		local secured, chmod_err = vim.uv.fs_chmod(parent, DIRECTORY_MODE)
		if not secured then
			return nil, "Could not secure theme state directory: " .. tostring(chmod_err)
		end
		return true
	end
	if not create then
		return true
	end
	local grandparent = vim.fs.dirname(parent)
	local grandparent_info, grandparent_err = lstat(grandparent)
	if grandparent_err then
		return nil, "Could not inspect theme state parent: " .. tostring(grandparent_err)
	end
	if not grandparent_info or grandparent_info.type ~= "directory" then
		return nil, "Theme state parent must be an existing real directory"
	end
	local created, mkdir_err = vim.uv.fs_mkdir(parent, DIRECTORY_MODE)
	if not created then
		return nil, "Could not create theme state directory: " .. tostring(mkdir_err)
	end
	return true
end

local function inspect_target(path)
	local info, err = lstat(path)
	if err then
		return nil, "Could not inspect theme state: " .. tostring(err)
	end
	if info and info.type ~= "file" then
		return nil, "Theme state must be a regular file; symlinks and non-regular targets are rejected"
	end
	return info or false
end

local function read_bounded_file(path, info)
	if info.size > MAX_STATE_BYTES then
		return nil, "Theme state exceeds the 64 KiB limit"
	end
	local fd, open_err = vim.uv.fs_open(path, "r", FILE_MODE)
	if not fd then
		return nil, "Could not open theme state: " .. tostring(open_err)
	end
	local contents, read_err = vim.uv.fs_read(fd, info.size, 0)
	local close_ok, close_err = vim.uv.fs_close(fd)
	if not contents then
		return nil, "Could not read theme state: " .. tostring(read_err)
	end
	if not close_ok then
		return nil, "Could not close theme state: " .. tostring(close_err)
	end
	return contents
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_yaml_comment(value)
	local single = false
	local double = false
	local escaped = false
	for index = 1, #value do
		local char = value:sub(index, index)
		if double then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				double = false
			end
		elseif single then
			if char == "'" then
				if value:sub(index + 1, index + 1) ~= "'" then
					single = false
				end
			end
		elseif char == '"' then
			double = true
		elseif char == "'" then
			single = true
		elseif char == "#" and (index == 1 or value:sub(index - 1, index - 1):match("%s")) then
			return trim(value:sub(1, index - 1))
		end
	end
	if single or double or escaped then
		return nil, "unterminated quoted scalar"
	end
	return trim(value)
end

local function parse_colorscheme_scalar(raw)
	local scalar, comment_err = strip_yaml_comment(raw)
	if not scalar then
		return nil, comment_err
	end
	if scalar == "" then
		return nil, "colorscheme must not be empty"
	end
	local first = scalar:sub(1, 1)
	if first == '"' then
		local ok, decoded = pcall(vim.json.decode, scalar)
		if not ok or type(decoded) ~= "string" then
			return nil, "colorscheme has a malformed double-quoted scalar"
		end
		return colorscheme_name(decoded, "colorscheme")
	end
	if first == "'" then
		if scalar:sub(-1) ~= "'" or #scalar < 2 then
			return nil, "colorscheme has a malformed single-quoted scalar"
		end
		local inner = scalar:sub(2, -2)
		if inner:gsub("''", ""):find("'", 1, true) then
			return nil, "colorscheme has a malformed single-quoted scalar"
		end
		return colorscheme_name(inner:gsub("''", "'"), "colorscheme")
	end
	return colorscheme_name(scalar, "colorscheme")
end

local function parse_yaml(contents)
	if type(contents) ~= "string" then
		return nil, "Theme state must be text"
	end
	local fields = {}
	local seen = {}
	local lines = vim.split(contents, "\n", { plain = true })
	for line_number, line in ipairs(lines) do
		if line:find("\0", 1, true) then
			return nil, ("Theme state line %d contains a NUL byte"):format(line_number)
		end
		if not line:match("^%s*$") and not line:match("^%s*#") then
			if line:match("^%s") then
				return nil, ("Theme state line %d must use a top-level key"):format(line_number)
			end
			local key, raw = line:match("^([%a_][%w_-]*)%s*:%s*(.-)%s*$")
			if not key then
				return nil, ("Theme state line %d is malformed"):format(line_number)
			end
			if key ~= "version" and key ~= "colorscheme" then
				return nil, ("Theme state contains unknown key '%s'"):format(key)
			end
			if seen[key] then
				return nil, ("Theme state contains duplicate key '%s'"):format(key)
			end
			seen[key] = true
			if key == "version" then
				local scalar, scalar_err = strip_yaml_comment(raw)
				if not scalar then
					return nil, "Theme state version is malformed: " .. scalar_err
				end
				if not scalar:match("^[0-9]+$") then
					return nil, "Theme state version must be an integer scalar"
				end
				fields.version = tonumber(scalar)
			else
				local colorscheme, scalar_err = parse_colorscheme_scalar(raw)
				if not colorscheme then
					return nil, "Theme state colorscheme is malformed: " .. scalar_err
				end
				fields.colorscheme = colorscheme
			end
		end
	end
	if fields.version == nil then
		return nil, "Theme state is missing required key 'version'"
	end
	if fields.version ~= STATE_VERSION then
		return nil, "Unsupported theme state version: " .. tostring(fields.version)
	end
	if fields.colorscheme == nil then
		return nil, "Theme state is missing required key 'colorscheme'"
	end
	return { version = STATE_VERSION, colorscheme = fields.colorscheme }
end

local function yaml_contents(name)
	return table.concat({
		"# Shared Neovim and nvimpager theme selection.",
		"version: 1",
		"colorscheme: " .. vim.json.encode(name),
		"",
	}, "\n")
end

local function atomic_write(name)
	local parent_ok, parent_err = inspect_parent(true)
	if not parent_ok then
		return nil, parent_err
	end
	local path = state.opts.state_path
	local _, target_err = inspect_target(path)
	if target_err then
		return nil, target_err
	end
	local contents = yaml_contents(name)
	local temporary = path .. (".tmp.%d.%d"):format(vim.uv.os_getpid(), vim.uv.hrtime())
	local fd, open_err = vim.uv.fs_open(temporary, "wx", FILE_MODE)
	if not fd then
		return nil, "Could not create temporary theme state: " .. tostring(open_err)
	end
	local offset = 0
	while offset < #contents do
		local written, write_err = vim.uv.fs_write(fd, contents:sub(offset + 1), offset)
		if not written then
			vim.uv.fs_close(fd)
			vim.uv.fs_unlink(temporary)
			return nil, "Could not write temporary theme state: " .. tostring(write_err)
		end
		offset = offset + written
	end
	local sync_ok, sync_err = vim.uv.fs_fsync(fd)
	local close_ok, close_err = vim.uv.fs_close(fd)
	if not sync_ok or not close_ok then
		vim.uv.fs_unlink(temporary)
		return nil, "Could not flush temporary theme state: " .. tostring(sync_err or close_err)
	end
	local chmod_ok, chmod_err = vim.uv.fs_chmod(temporary, FILE_MODE)
	if not chmod_ok then
		vim.uv.fs_unlink(temporary)
		return nil, "Could not secure temporary theme state: " .. tostring(chmod_err)
	end
	local _, recheck_err = inspect_target(path)
	if recheck_err then
		vim.uv.fs_unlink(temporary)
		return nil, recheck_err
	end
	local replaced, rename_err = vim.uv.fs_rename(temporary, path)
	if not replaced then
		vim.uv.fs_unlink(temporary)
		return nil, "Could not replace theme state atomically: " .. tostring(rename_err)
	end
	local final_ok, final_err = vim.uv.fs_chmod(path, FILE_MODE)
	if not final_ok then
		return nil, "Could not secure theme state: " .. tostring(final_err)
	end
	return true
end

local LEGACY_PREFIX = {
	"-- lua/localconfig/theme.lua -- machine-local theme selection.",
	"-- Written by :Theme. NOT under version control; see .gitignore.",
	"-- The versioned starting point lives in lua/config/theme_default.lua,",
	"-- and :ThemeReset deletes this file to come back to it.",
	"",
	"return {",
}

local function parse_legacy(contents)
	local lines = vim.split(contents, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines ~= 8 then
		return nil
	end
	for index, expected in ipairs(LEGACY_PREFIX) do
		if lines[index] ~= expected then
			return nil
		end
	end
	if lines[8] ~= "}" then
		return nil
	end
	local name = lines[7]:match('^\tcolorscheme = "([%w_.@+/%-]+)",$')
	return name and colorscheme_name(name, "legacy colorscheme") or nil
end

local function read_legacy()
	local path = state.opts.legacy_path
	if not path then
		return nil, "absent"
	end
	local info, err = lstat(path)
	if err then
		return nil, "Could not inspect legacy theme state: " .. tostring(err)
	end
	if not info then
		return nil, "absent"
	end
	if info.type ~= "file" then
		return nil, "Legacy theme state is not a regular file and was ignored"
	end
	local contents, read_err = read_bounded_file(path, info)
	if not contents then
		return nil, read_err
	end
	local name = parse_legacy(contents)
	if not name then
		return nil, "Legacy theme state did not match the generated format and was ignored"
	end
	return name
end

local function default_selection(validity)
	return {
		colorscheme = state.opts.default,
		source = "default",
		validity = validity or { valid = true },
	}
end

local function load_selection()
	local parent_ok, parent_err = inspect_parent(false)
	if not parent_ok then
		notify(parent_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = parent_err })
	end
	local info, target_err = inspect_target(state.opts.state_path)
	if target_err then
		notify(target_err, vim.log.levels.ERROR)
		return default_selection({ valid = false, error = target_err })
	end
	if info then
		local contents, read_err = read_bounded_file(state.opts.state_path, info)
		if not contents then
			notify(read_err, vim.log.levels.ERROR)
			return default_selection({ valid = false, error = read_err })
		end
		local chmod_ok, chmod_err = vim.uv.fs_chmod(state.opts.state_path, FILE_MODE)
		if not chmod_ok then
			local message = "Could not secure theme state: " .. tostring(chmod_err)
			notify(message, vim.log.levels.ERROR)
			return default_selection({ valid = false, error = message })
		end
		local parsed, parse_err = parse_yaml(contents)
		if not parsed then
			notify(parse_err, vim.log.levels.WARN)
			return default_selection({ valid = false, error = parse_err })
		end
		return { colorscheme = parsed.colorscheme, source = "local", validity = { valid = true } }
	end

	local legacy, legacy_err = read_legacy()
	if legacy then
		local migrated, migration_err = atomic_write(legacy)
		if migrated then
			emit("migrated", { colorscheme = legacy, legacy_path = state.opts.legacy_path })
			return { colorscheme = legacy, source = "local", validity = { valid = true, migrated = true } }
		end
		notify("Could not migrate legacy theme state: " .. tostring(migration_err), vim.log.levels.ERROR)
		return default_selection({ valid = false, error = migration_err })
	end
	if legacy_err ~= "absent" then
		notify(legacy_err, vim.log.levels.WARN)
	end
	return default_selection()
end

local function paint(name)
	local painter = state.painters[name] or state.opts.paint
	local context = {}
	if state.opts.context then
		local context_ok, context_or_error = pcall(state.opts.context)
		if not context_ok then
			local message = "Theme context callback failed: " .. tostring(context_or_error)
			notify(message, vim.log.levels.WARN)
			emit("error", { colorscheme = name, error = message })
			return false
		end
		context = context_or_error
	end
	local copy_ok, context_copy = pcall(copy, context)
	if not copy_ok then
		local message = "Theme context could not be copied: " .. tostring(context_copy)
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	local ok, result, detail = pcall(painter, name, context_copy)
	if not ok then
		local message = ("Painter for '%s' failed: %s"):format(name, tostring(result))
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	if result == false then
		local message = ("Painter for '%s' failed: %s"):format(name, tostring(detail or "rejected"))
		notify(message, vim.log.levels.WARN)
		emit("error", { colorscheme = name, error = message })
		return false
	end
	emit("applied", { colorscheme = name })
	return true
end

function M.setup(opts)
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	local path, path_err = nonempty_string(opts.state_path, "setup.state_path")
	if not path then
		return nil, path_err
	end
	path = vim.fs.normalize(path)
	if path:sub(1, 1) ~= "/" then
		return nil, "setup.state_path must be absolute"
	end
	local default, default_err = colorscheme_name(opts.default, "setup.default")
	if not default then
		return nil, default_err
	end
	local fallback, fallback_err = colorscheme_name(opts.fallback, "setup.fallback")
	if not fallback then
		return nil, fallback_err
	end
	if opts.legacy_path ~= nil then
		local legacy, legacy_err = nonempty_string(opts.legacy_path, "setup.legacy_path")
		if not legacy then
			return nil, legacy_err
		end
		legacy = vim.fs.normalize(legacy)
		if legacy:sub(1, 1) ~= "/" then
			return nil, "setup.legacy_path must be absolute"
		end
	end
	for _, callback in ipairs({ "notify", "event", "paint" }) do
		if type(opts[callback]) ~= "function" then
			return nil, ("setup.%s must be a function"):format(callback)
		end
	end
	if opts.context ~= nil and type(opts.context) ~= "function" then
		return nil, "setup.context must be a function"
	end
	state.opts = {
		state_path = path,
		legacy_path = opts.legacy_path and vim.fs.normalize(opts.legacy_path) or nil,
		default = default,
		fallback = fallback,
		notify = opts.notify,
		event = opts.event,
		paint = opts.paint,
		context = opts.context,
	}
	state.painters = {}
	state.configured = true
	state.selection = load_selection()
	return M.selection()
end

function M.register(name, painter)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local normalized, err = colorscheme_name(name, "painter name")
	if not normalized then
		return nil, err
	end
	if type(painter) ~= "function" then
		return nil, "painter must be a function"
	end
	state.painters[normalized] = painter
	return true
end

function M.selection()
	if not state.configured then
		return nil, "setup must be called first"
	end
	return copy(state.selection)
end

function M.apply(name)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local requested = name or state.selection.colorscheme
	local normalized, err = colorscheme_name(requested, "colorscheme")
	if not normalized then
		notify(err, vim.log.levels.WARN)
		return false
	end
	return paint(normalized)
end

function M.repaint()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local selected = state.selection.colorscheme
	if paint(selected) then
		return true, selected
	end
	if selected ~= state.opts.default and paint(state.opts.default) then
		emit("fallback", { colorscheme = state.opts.default, failed = selected, source = "default" })
		return true, state.opts.default
	end
	if state.opts.fallback ~= selected and state.opts.fallback ~= state.opts.default and paint(state.opts.fallback) then
		emit("fallback", { colorscheme = state.opts.fallback, failed = selected, source = "fallback" })
		return true, state.opts.fallback
	end
	return false
end

function M.persist(name)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local normalized, err = colorscheme_name(name, "colorscheme")
	if not normalized then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local written, write_err = atomic_write(normalized)
	if not written then
		notify(write_err, vim.log.levels.ERROR)
		emit("error", { colorscheme = normalized, error = write_err })
		return false
	end
	state.selection = { colorscheme = normalized, source = "local", validity = { valid = true } }
	emit("persisted", { colorscheme = normalized })
	return true
end

function M.reset()
	if not state.configured then
		return nil, "setup must be called first"
	end
	local written, write_err = atomic_write(state.opts.default)
	if not written then
		notify(write_err, vim.log.levels.ERROR)
		emit("error", { colorscheme = state.opts.default, error = write_err })
		return false
	end
	state.selection = { colorscheme = state.opts.default, source = "default", validity = { valid = true } }
	emit("reset", { colorscheme = state.opts.default })
	return M.repaint()
end

return M
