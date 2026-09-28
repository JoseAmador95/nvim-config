-- Explicit dynamic npm-release installer. Discovery is a separate, named
-- lifecycle action; planning, observation, health, and runtime resolution are
-- read-only and never consult npm or the registry.
local source =
	assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.npm_release_installer source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local M = {}

local fs = require("config.fs")
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local verified_tools = require("verified_tools")
local uv = vim.uv
local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
	pcall(
		ffi.cdef,
		[[
				int openat(int dirfd, const char *pathname, int flags, ...);
				int mkdirat(int dirfd, const char *pathname, unsigned int mode);
				int renameat2(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
				int renameatx_np(int oldfd, const char *oldpath, int newfd, const char *newpath, unsigned int flags);
			]]
	)
end

local SYSTEM = uv.os_uname().sysname
local AT_FDCWD = SYSTEM == "Darwin" and -2 or -100
local PUBLISH_OPEN_FLAGS = SYSTEM == "Darwin"
		and { close_exec = 16777216, directory = 1048576, nonblock = 4, no_follow = 256 }
	or { close_exec = 524288, directory = 65536, nonblock = 2048, no_follow = 131072 }
local MAX_METADATA_BYTES = 256 * 1024
local MAX_NODE_ARCHIVE_BYTES = 96 * 1024 * 1024
local MAX_PACKAGE_ARCHIVE_BYTES = 32 * 1024 * 1024
local PRIVATE_DIRECTORY_MODE = 448 -- 0700
local PRIVATE_FILE_MODE = 384 -- 0600
local PRIVATE_EXECUTABLE_MODE = 448 -- 0700
local EEXIST = 17
local MAX_PREREQUISITE_DIAGNOSTIC_BYTES = 512
local MAX_PREREQUISITE_ITEM_BYTES = 192
local MAX_HELPER_FAILURE_BYTES = 160

M._external = function(name)
	return paths.external_executable(name)
end
M._external_candidates = function(name)
	if type(paths.external_candidates) == "function" then
		return paths.external_candidates(name)
	end
	local candidate = M._external(name)
	return candidate and { candidate } or {}
end
M._platform = function()
	local uname = uv.os_uname()
	return uname.sysname, uname.machine
end
M._network_authorized = function()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end
M._helper = function()
	return vim.fs.joinpath(config_root, "scripts", "verified-npm-bundle.py")
end
M._config_root = function()
	return config_root
end
M._validate_external = function(path)
	return verified_tools.validate_external_candidate(path)
end
M._validate_prerequisite = function(path)
	return verified_tools.validate_prerequisite_candidate(path)
end
M._interleave = function() end
M._run = function(command, options, callback)
	local ok, process = pcall(vim.system, command, options or {}, vim.schedule_wrap(callback))
	if not ok then
		vim.schedule(function()
			callback({ code = -1, stderr = tostring(process) })
		end)
		return nil
	end
	return process
end

local function bounded_diagnostic(value, limit)
	local text = tostring(value or "invalid"):gsub("%c", "?")
	if #text <= limit then
		return text
	end
	return text:sub(1, limit - 3) .. "..."
end

local function helper_failure_reason(category, result)
	local stderr = type(result) == "table" and result.stderr or nil
	if type(stderr) ~= "string" then
		return category
	end
	local detail = vim.trim(stderr:gsub("%c", " "):gsub("%s+", " "))
	if detail == "" then
		return category
	end
	local available = MAX_HELPER_FAILURE_BYTES - #category - 2
	return category .. ": " .. bounded_diagnostic(detail, available)
end

local function config_owned_path(path)
	return paths.is_managed_path(path)
		or paths.is_mason_path(path)
		or type(paths.is_verified_shim_path) == "function" and paths.is_verified_shim_path(path)
end

local function select_prerequisite(name)
	local candidates_ok, candidates = pcall(M._external_candidates, name)
	if not candidates_ok or type(candidates) ~= "table" then
		return nil,
			bounded_diagnostic(
				"candidate lookup failed: " .. tostring(candidates_ok and "invalid result" or candidates),
				MAX_PREREQUISITE_DIAGNOSTIC_BYTES
			)
	end

	local failures = {}
	for _, lexical in ipairs(candidates) do
		local canonical
		local reason
		if type(lexical) ~= "string" or lexical:sub(1, 1) ~= "/" then
			reason = "candidate is not an absolute path"
		elseif config_owned_path(lexical) then
			reason = "candidate belongs to config-managed tool state"
		else
			local validation_ok, validated, authority_err = pcall(M._validate_prerequisite, lexical)
			if validation_ok then
				canonical = validated
				reason = authority_err
			else
				reason = validated
			end
			if type(canonical) ~= "string" or canonical:sub(1, 1) ~= "/" then
				canonical = nil
				reason = reason or "authority did not return an absolute path"
			elseif config_owned_path(canonical) then
				canonical = nil
				reason = "canonical path belongs to config-managed tool state"
			elseif vim.fn.executable(canonical) ~= 1 then
				canonical = nil
				reason = "canonical path is not executable"
			end
		end
		if canonical then
			return canonical
		end
		failures[#failures + 1] = bounded_diagnostic(lexical, MAX_PREREQUISITE_ITEM_BYTES)
			.. "="
			.. bounded_diagnostic(reason, MAX_PREREQUISITE_ITEM_BYTES)
	end

	local detail = #failures > 0 and table.concat(failures, "; ") or "no eligible PATH candidates"
	return nil, bounded_diagnostic(detail, MAX_PREREQUISITE_DIAGNOSTIC_BYTES)
end

local function schedule_on_main(callback, ...)
	if not vim.in_fast_event() then
		return callback(...)
	end
	local arguments = { n = select("#", ...), ... }
	vim.schedule(function()
		callback(unpack(arguments, 1, arguments.n))
	end)
end

local function sorted_keys(value)
	local result = vim.tbl_keys(value or {})
	table.sort(result)
	return result
end

local function canonical_encode(value, seen)
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		local ok, encoded = pcall(vim.json.encode, value)
		return ok and encoded or nil
	end
	if kind ~= "table" then
		return nil
	end
	seen = seen or {}
	if seen[value] then
		return nil
	end
	seen[value] = true
	local length = #value
	local parts = {}
	if length > 0 then
		for key in pairs(value) do
			if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then
				seen[value] = nil
				return nil
			end
		end
		for index = 1, length do
			local encoded = canonical_encode(value[index], seen)
			if not encoded then
				seen[value] = nil
				return nil
			end
			parts[#parts + 1] = encoded
		end
		seen[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	for key in pairs(value) do
		if type(key) ~= "string" then
			seen[value] = nil
			return nil
		end
	end
	for _, key in ipairs(sorted_keys(value)) do
		local key_ok, encoded_key = pcall(vim.json.encode, key)
		local encoded_value = canonical_encode(value[key], seen)
		if not key_ok or not encoded_value then
			seen[value] = nil
			return nil
		end
		parts[#parts + 1] = encoded_key .. ":" .. encoded_value
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function exact_keys(value, allowed)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if not allowed[key] then
			return false
		end
	end
	return true
end

local function empty_map(value)
	return value == nil or type(value) == "table" and next(value) == nil
end

local function version_parts(value, stable)
	if type(value) ~= "string" or #value > 64 then
		return nil
	end
	local major, minor, patch = value:match("^(%d+)%.(%d+)%.(%d+)$")
	local precision = 3
	if not major and not stable then
		major, minor = value:match("^(%d+)%.(%d+)$")
		if not major then
			major = value:match("^(%d+)$")
			precision = 1
		else
			precision = 2
		end
		minor = minor or "0"
		patch = "0"
	end
	if not major then
		return nil
	end
	for _, item in ipairs({ major, minor, patch }) do
		if #item > 1 and item:sub(1, 1) == "0" then
			return nil
		end
	end
	return { tonumber(major), tonumber(minor), tonumber(patch) }, precision
end

local function compare_version(left, right)
	for index = 1, 3 do
		if left[index] ~= right[index] then
			return left[index] < right[index] and -1 or 1
		end
	end
	return 0
end

local function comparator_matches(current, token)
	if token == "*" or token:lower() == "x" then
		return true
	end
	local operator, version = "=", token
	for _, prefix in ipairs({ ">=", "<=", ">", "<", "=", "^", "~" }) do
		if token:sub(1, #prefix) == prefix then
			operator, version = prefix, token:sub(#prefix + 1)
			break
		end
	end
	local wildcard_major = version:match("^(%d+)%.[xX*]$")
	if wildcard_major then
		if operator ~= "=" then
			return nil
		end
		if #wildcard_major > 1 and wildcard_major:sub(1, 1) == "0" then
			return nil
		end
		return current[1] == tonumber(wildcard_major)
	end
	local wildcard_minor_major, wildcard_minor = version:match("^(%d+)%.(%d+)%.[xX*]$")
	if wildcard_minor_major then
		if operator ~= "=" then
			return nil
		end
		if
			#wildcard_minor_major > 1 and wildcard_minor_major:sub(1, 1) == "0"
			or #wildcard_minor > 1 and wildcard_minor:sub(1, 1) == "0"
		then
			return nil
		end
		return current[1] == tonumber(wildcard_minor_major) and current[2] == tonumber(wildcard_minor)
	end
	local expected, precision = version_parts(version, false)
	if not expected then
		return nil
	end
	local comparison = compare_version(current, expected)
	local partial_upper = precision == 1 and { expected[1] + 1, 0, 0 }
		or precision == 2 and { expected[1], expected[2] + 1, 0 }
	if operator == ">=" then
		return comparison >= 0
	elseif operator == "<=" then
		if partial_upper then
			return compare_version(current, partial_upper) < 0
		end
		return comparison <= 0
	elseif operator == ">" then
		if partial_upper then
			return compare_version(current, partial_upper) >= 0
		end
		return comparison > 0
	elseif operator == "<" then
		return comparison < 0
	elseif operator == "^" then
		local upper = precision == 1 and { expected[1] + 1, 0, 0 }
			or expected[1] > 0 and { expected[1] + 1, 0, 0 }
			or precision == 2 and { 0, expected[2] + 1, 0 }
			or expected[2] > 0 and { 0, expected[2] + 1, 0 }
			or { 0, 0, expected[3] + 1 }
		return comparison >= 0 and compare_version(current, upper) < 0
	elseif operator == "~" then
		local upper = precision == 1 and { expected[1] + 1, 0, 0 } or { expected[1], expected[2] + 1, 0 }
		return comparison >= 0 and compare_version(current, upper) < 0
	elseif partial_upper then
		return comparison >= 0 and compare_version(current, partial_upper) < 0
	end
	return comparison == 0
end

local function split_engine_clauses(value)
	local clauses = {}
	local cursor = 1
	while true do
		local delimiter_start, delimiter_end = value:find("||", cursor, true)
		local clause = vim.trim(value:sub(cursor, delimiter_start and delimiter_start - 1 or #value))
		if clause == "" or clause:find("|", 1, true) then
			return nil
		end
		clauses[#clauses + 1] = clause
		if not delimiter_start then
			return clauses
		end
		cursor = delimiter_end + 1
	end
end

local function engine_compatible(value, node_version)
	if type(value) ~= "string" or value == "" or #value > 256 then
		return false
	end
	local current = version_parts(node_version, true)
	if not current then
		return false
	end
	local clauses = split_engine_clauses(value)
	if not clauses then
		return false
	end
	local compatible = false
	for _, clause in ipairs(clauses) do
		local matched = true
		local count = 0
		for token in vim.trim(clause):gmatch("%S+") do
			count = count + 1
			local token_matches = comparator_matches(current, token)
			if token_matches == nil then
				return false
			end
			matched = matched and token_matches
		end
		compatible = compatible or count > 0 and matched
	end
	return compatible
end

local function canonical_integrity(value)
	if type(value) ~= "string" or not value:match("^sha512%-%S+$") or value:find("%s") then
		return nil
	end
	local encoded = value:sub(8)
	local ok, decoded = pcall(vim.base64.decode, encoded)
	if not ok or type(decoded) ~= "string" or #decoded ~= 64 then
		return nil
	end
	local encoded_ok, canonical = pcall(vim.base64.encode, decoded)
	return encoded_ok and canonical == encoded and value or nil
end

local function canonical_tarball(version)
	return ("https://registry.npmjs.org/@devcontainers/cli/-/cli-%s.tgz"):format(version)
end

local function normalize_metadata(entry, value, require_dist)
	if type(value) ~= "table" or value.name ~= entry.package then
		return nil, "npm metadata package name is not exact"
	end
	local version = version_parts(value.version, true) and value.version or nil
	if not version then
		return nil, "npm metadata version is not a stable SemVer"
	end
	if not exact_keys(value.bin, { devcontainer = true }) or value.bin.devcontainer ~= "devcontainer.js" then
		return nil, "npm metadata bin map is not exact"
	end
	if
		type(value.engines) ~= "table"
		or not exact_keys(value.engines, { node = true })
		or not engine_compatible(value.engines.node, entry.node.version)
	then
		return nil, "npm package does not support the pinned private Node"
	end
	if
		not empty_map(value.dependencies)
		or not empty_map(value.optionalDependencies)
		or not empty_map(value.peerDependencies)
		or not empty_map(value.peerDependenciesMeta)
		or not empty_map(value.bundledDependencies)
		or not empty_map(value.bundleDependencies)
	then
		return nil, "npm package contains runtime, optional, peer, or bundled dependencies"
	end
	local tarball
	local integrity
	if require_dist then
		if type(value.dist) ~= "table" then
			return nil, "npm metadata dist is absent"
		end
		tarball = value.dist.tarball == canonical_tarball(version) and value.dist.tarball or nil
		integrity = canonical_integrity(value.dist.integrity)
		if not tarball or not integrity then
			return nil, "npm metadata dist tarball or integrity is not canonical"
		end
	end
	return {
		name = value.name,
		version = version,
		bin = { devcontainer = "devcontainer.js" },
		engines = { node = value.engines.node },
		tarball = tarball,
		integrity = integrity,
	}
end

function M.validate_metadata(entry, value)
	return normalize_metadata(entry, value, true)
end

function M.validate_package(entry, expected, value)
	local normalized, err = normalize_metadata(entry, value, false)
	if not normalized then
		return nil, err
	end
	if
		normalized.name ~= expected.name
		or normalized.version ~= expected.version
		or not vim.deep_equal(normalized.bin, expected.bin)
		or not vim.deep_equal(normalized.engines, expected.engines)
	then
		return nil, "extracted package.json differs from selected metadata"
	end
	return normalized
end

function M.discover(entry, callback)
	if type(callback) ~= "function" then
		return nil, "discovery callback is required"
	end
	if not vim.deep_equal(entry, manifest.dynamic_entry(entry and entry.name)) then
		return nil, "dynamic npm manifest is invalid"
	end
	if not M._network_authorized() then
		return nil, "network-disabled"
	end
	local curl, authority_err = select_prerequisite("curl")
	if not curl then
		return nil, "missing-or-unsafe-prerequisite:curl:" .. tostring(authority_err or "invalid")
	end
	local completed = false
	local function finish(ok, value)
		if completed then
			return
		end
		completed = true
		schedule_on_main(callback, ok, value)
	end
	local process = M._run({
		curl,
		"--disable",
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--proto",
		"=https",
		"--proto-redir",
		"=https",
		"--tlsv1.2",
		"--max-time",
		"30",
		"--max-filesize",
		tostring(MAX_METADATA_BYTES),
		entry.metadata_url,
	}, { text = true }, function(result)
		if type(result) ~= "table" or result.code ~= 0 then
			finish(false, "npm-metadata-download-failed")
			return
		end
		local output = result.stdout or ""
		if #output == 0 or #output > MAX_METADATA_BYTES then
			finish(false, "npm-metadata-size-invalid")
			return
		end
		local decoded_ok, decoded = pcall(vim.json.decode, output)
		local selected, select_err
		if decoded_ok then
			selected, select_err = M.validate_metadata(entry, decoded)
		end
		finish(selected ~= nil, selected or select_err or "npm-metadata-json-invalid")
	end)
	if not process then
		finish(false, "npm-metadata-start-failed")
		return nil, "npm-metadata-start-failed"
	end
	return {
		cancel = function()
			if not completed and type(process.kill) == "function" then
				pcall(process.kill, process, 15)
			end
		end,
	}
end

local function canonical_absolute(path)
	local expanded = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	return expanded:sub(1, 1) == "/" and expanded or nil
end

local function expected_header(plan)
	return {
		schema = 1,
		kind = "verified-npm-bundle-receipt",
		name = plan.name,
		package = plan.entry.package,
		version = plan.metadata.version,
		target = plan.target,
		source_tarball = plan.metadata.tarball,
		source_integrity = plan.metadata.integrity,
		source_sha256 = plan.source_sha256,
		node_version = plan.entry.node.version,
		node_archive_sha256 = plan.node_asset.sha256,
		bin = { devcontainer = "devcontainer.js" },
	}
end

local function source_digest(entry, metadata, target, node_asset)
	local encoded = canonical_encode({
		schema = 1,
		backend = "npm-release",
		name = entry.name,
		package = entry.package,
		version = metadata.version,
		target = target,
		tarball = metadata.tarball,
		integrity = metadata.integrity,
		bin = metadata.bin,
		engines = metadata.engines,
		node_version = entry.node.version,
		node_archive = node_asset.archive,
		node_sha256 = node_asset.sha256,
	})
	return encoded and vim.fn.sha256(encoded) or nil
end

-- Planning is deterministic and offline after explicit discovery selected one
-- exact registry version and source integrity.
function M.plan(name, selected)
	local entry = manifest.dynamic_entry(name)
	local metadata, metadata_err
	if entry then
		metadata, metadata_err = M.validate_metadata(entry, {
			name = selected and selected.name,
			version = selected and selected.version,
			bin = selected and selected.bin,
			engines = selected and selected.engines,
			dist = { tarball = selected and selected.tarball, integrity = selected and selected.integrity },
		})
	end
	if not entry or not metadata then
		return nil, metadata_err or "unknown"
	end
	local os_name, arch = M._platform()
	local target = manifest.target_key(os_name, arch)
	local node_asset = target and entry.node.assets[target] or nil
	if not node_asset then
		return nil, "unsupported"
	end
	local digest = source_digest(entry, metadata, target, node_asset)
	if not digest then
		return nil, "npm release selection is not canonically encodable"
	end
	local managed_root = canonical_absolute(paths.managed_root())
	if not managed_root then
		return nil, "managed root is invalid"
	end
	local install_root = vim.fs.joinpath(managed_root, "bundles", name, metadata.version, target, digest)
	local receipt_path = vim.fs.joinpath(managed_root, "bundle-receipts", digest .. ".json")
	local plan = {
		name = name,
		entry = vim.deepcopy(entry),
		metadata = metadata,
		target = target,
		node_asset = vim.deepcopy(node_asset),
		node_url = manifest.node_release_url(entry.node, node_asset),
		node_member = entry.node.assets[target].archive:gsub("%.tar%.gz$", "") .. "/bin/node",
		install_root = install_root,
		receipt_path = receipt_path,
		source_sha256 = digest,
		commands = { devcontainer = "bin/devcontainer" },
		requirements = { "curl", "python3" },
	}
	plan.receipt = expected_header(plan)
	return plan
end

local function validate_plan(value)
	if type(value) ~= "table" or type(value.name) ~= "string" then
		return nil, "plan-invalid"
	end
	local expected, err = M.plan(value.name, value.metadata)
	if not expected or not vim.deep_equal(expected, value) then
		return nil, err or "plan-invalid"
	end
	return expected
end

local function safe_prerequisites(plan)
	local result = {}
	for _, name in ipairs(plan.requirements) do
		local path, authority_err = select_prerequisite(name)
		if not path then
			return nil, "missing-or-unsafe-prerequisite:" .. name .. ":" .. tostring(authority_err or "invalid")
		end
		result[name] = path
	end
	local helper_lexical = canonical_absolute(M._helper())
	local helper, helper_err
	if helper_lexical then
		helper, helper_err = M._validate_external(helper_lexical)
	end
	local config_root = canonical_absolute(M._config_root())
	config_root = config_root and uv.fs_realpath(config_root) or nil
	local expected_helper = config_root and vim.fs.joinpath(config_root, "scripts", "verified-npm-bundle.py") or nil
	local helper_stat = helper and uv.fs_lstat(helper) or nil
	if not helper_stat or helper_stat.type ~= "file" or helper_stat.nlink ~= 1 or helper ~= expected_helper then
		return nil, "npm-bundle-helper-unsafe:" .. tostring(helper_err or "invalid")
	end
	result.helper = helper
	return result
end

function M.preflight(value)
	local plan, plan_err = validate_plan(value)
	if not plan then
		return nil, plan_err
	end
	local commands, commands_err = safe_prerequisites(plan)
	return commands and true or nil, commands_err
end

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function same_directory_snapshot(current, expected)
	return current
		and expected
		and current.type == "directory"
		and expected.type == "directory"
		and current.dev == expected.dev
		and current.ino == expected.ino
		and current.mode == expected.mode
		and current.uid == expected.uid
		and current.gid == expected.gid
end

local function safe_directory_name(value)
	return type(value) == "string"
		and #value > 0
		and #value <= 255
		and value ~= "."
		and value ~= ".."
		and not value:find("/", 1, true)
		and not value:find("\0", 1, true)
end

local function close_directory(directory)
	if not directory or not directory.fd then
		return true
	end
	local closed, close_err = uv.fs_close(directory.fd)
	directory.fd = nil
	return closed, close_err
end

local function directory_bound(directory)
	local opened = directory and directory.fd and uv.fs_fstat(directory.fd) or nil
	local visible = directory and uv.fs_lstat(directory.path) or nil
	return same_directory_snapshot(opened, directory and directory.stat)
		and same_directory_snapshot(visible, directory.stat)
		and uv.fs_realpath(directory.path) == directory.path
end

local function open_directory(path, expected, private)
	if not ffi_ok or (SYSTEM ~= "Darwin" and SYSTEM ~= "Linux") then
		return nil, "descriptor-relative-directory-unavailable"
	end
	path = vim.fs.normalize(path)
	local inspected = uv.fs_lstat(path)
	if
		not same_directory_snapshot(inspected, expected)
		or uv.fs_realpath(path) ~= path
		or private
			and (inspected.mode % 512 ~= PRIVATE_DIRECTORY_MODE or uv.getuid and inspected.uid ~= uv.getuid())
	then
		return nil, "directory-changed"
	end
	local flags = PUBLISH_OPEN_FLAGS.directory
		+ PUBLISH_OPEN_FLAGS.nonblock
		+ PUBLISH_OPEN_FLAGS.no_follow
		+ PUBLISH_OPEN_FLAGS.close_exec
	local raw_fd = ffi.C.openat(AT_FDCWD, path, flags)
	if raw_fd < 0 then
		return nil, "directory-open-failed:errno " .. tostring(ffi.errno())
	end
	local directory = { fd = tonumber(raw_fd), path = path, stat = vim.deepcopy(inspected) }
	if not directory_bound(directory) then
		close_directory(directory)
		return nil, "directory-changed"
	end
	return directory
end

local function open_child_directory(parent, name)
	if not safe_directory_name(name) or not directory_bound(parent) then
		return nil, "directory-parent-or-name-changed"
	end
	local flags = PUBLISH_OPEN_FLAGS.directory
		+ PUBLISH_OPEN_FLAGS.nonblock
		+ PUBLISH_OPEN_FLAGS.no_follow
		+ PUBLISH_OPEN_FLAGS.close_exec
	local raw_fd = ffi.C.openat(parent.fd, name, flags)
	if raw_fd < 0 then
		return nil, "directory-child-open-failed:errno " .. tostring(ffi.errno())
	end
	local path = vim.fs.joinpath(parent.path, name)
	local stat = uv.fs_fstat(tonumber(raw_fd))
	local child = { fd = tonumber(raw_fd), path = path, stat = vim.deepcopy(stat) }
	if not stat or stat.type ~= "directory" or not directory_bound(child) then
		close_directory(child)
		return nil, "directory-child-changed"
	end
	return child
end

M._sync_directory = function(fd)
	return uv.fs_fsync(fd)
end

local function ensure_directory_component(path, private_parent, prefix)
	path = vim.fs.normalize(path)
	local parent_path = vim.fs.dirname(path)
	local name = vim.fs.basename(path)
	if not safe_directory_name(name) then
		return nil, prefix .. "-name-unsafe"
	end
	local parent_stat = uv.fs_lstat(parent_path)
	if not parent_stat or parent_stat.type ~= "directory" then
		return nil, prefix .. "-parent-unavailable"
	end
	local parent, parent_err = open_directory(parent_path, parent_stat, private_parent)
	if not parent then
		return nil, prefix .. "-parent-changed:" .. tostring(parent_err)
	end
	local created = false
	if not uv.fs_lstat(path) then
		local hook_ok, hook_err = pcall(M._interleave, "before-directory-create", {
			parent = parent_path,
			path = path,
		})
		if not hook_ok or not directory_bound(parent) then
			close_directory(parent)
			return nil, prefix .. "-parent-changed:" .. tostring(hook_err or "identity changed")
		end
		local made = ffi.C.mkdirat(parent.fd, name, PRIVATE_DIRECTORY_MODE)
		if made ~= 0 then
			local errno = ffi.errno()
			if errno ~= EEXIST then
				close_directory(parent)
				return nil, prefix .. "-create-failed:errno " .. tostring(errno)
			end
		else
			created = true
		end
	end
	local child, child_err = open_child_directory(parent, name)
	if not child then
		close_directory(parent)
		return nil, prefix .. "-changed:" .. tostring(child_err)
	end
	local secured, secure_err = uv.fs_fchmod(child.fd, PRIVATE_DIRECTORY_MODE)
	child.stat = secured and uv.fs_fstat(child.fd) or nil
	if
		not secured
		or not child.stat
		or child.stat.type ~= "directory"
		or child.stat.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or uv.getuid and child.stat.uid ~= uv.getuid()
		or not directory_bound(child)
	then
		close_directory(child)
		close_directory(parent)
		return nil, prefix .. "-chmod-failed:" .. tostring(secure_err or "identity changed")
	end
	local child_synced, child_sync_err = M._sync_directory(child.fd, child.path, child.stat, "child", created)
	if not child_synced or not directory_bound(child) or not directory_bound(parent) then
		close_directory(child)
		close_directory(parent)
		return nil, prefix .. "-sync-failed:" .. tostring(child_sync_err or "identity changed")
	end
	local parent_synced, parent_sync_err = M._sync_directory(parent.fd, parent.path, parent.stat, "parent", created)
	if not parent_synced or not directory_bound(child) or not directory_bound(parent) then
		close_directory(child)
		close_directory(parent)
		return nil, prefix .. "-parent-sync-failed:" .. tostring(parent_sync_err or "identity changed")
	end
	local child_closed, child_close_err = close_directory(child)
	local parent_closed, parent_close_err = close_directory(parent)
	if not child_closed or not parent_closed then
		return nil, prefix .. "-close-failed:" .. tostring(child_close_err or parent_close_err)
	end
	return path
end

local ensure_private_directory
ensure_private_directory = function(path)
	local parent = vim.fs.dirname(path)
	if parent ~= path and not uv.fs_lstat(parent) then
		local ready, ready_err = ensure_private_directory(parent)
		if not ready then
			return nil, ready_err
		end
	end
	return ensure_directory_component(path, true, "private-directory")
end

local function ensure_managed_root(path)
	local parent_path = vim.fs.dirname(path)
	if not uv.fs_realpath(parent_path) then
		return nil, "managed-root-parent-unavailable"
	end
	return ensure_directory_component(path, false, "managed-root")
end

local function safe_download(path, root, maximum)
	local stat = uv.fs_lstat(path)
	local canonical = stat and stat.type == "file" and stat.nlink == 1 and uv.fs_realpath(path) or nil
	if
		not canonical
		or not contained(canonical, root)
		or stat.size < 1
		or stat.size > maximum
		or uv.getuid and stat.uid ~= uv.getuid()
	then
		return nil, "download-unsafe-or-oversize"
	end
	if not uv.fs_chmod(path, PRIVATE_FILE_MODE) then
		return nil, "download-chmod-failed"
	end
	return true
end

local function read_private(path, maximum)
	local before = uv.fs_lstat(path)
	if
		not before
		or before.type ~= "file"
		or before.nlink ~= 1
		or before.size > maximum
		or before.mode % 512 ~= PRIVATE_FILE_MODE
		or uv.getuid and before.uid ~= uv.getuid()
	then
		return nil, "private-file-unsafe"
	end
	local data, read_err = fs.read_binary(path)
	local after = uv.fs_lstat(path)
	if
		type(data) ~= "string"
		or not after
		or after.type ~= "file"
		or after.nlink ~= 1
		or before.dev ~= after.dev
		or before.ino ~= after.ino
		or before.nlink ~= after.nlink
		or before.size ~= after.size
		or before.mtime.sec ~= after.mtime.sec
		or before.mtime.nsec ~= after.mtime.nsec
		or before.ctime.sec ~= after.ctime.sec
		or before.ctime.nsec ~= after.ctime.nsec
	then
		return nil, "private-file-changed:" .. tostring(read_err)
	end
	return data
end

local function same_entry_stat(current, expected)
	return current
		and expected
		and current.type == expected.type
		and current.dev == expected.dev
		and current.ino == expected.ino
		and current.mode == expected.mode
		and current.uid == expected.uid
		and current.gid == expected.gid
		and (current.type == "directory" or current.nlink == expected.nlink)
end

local function safe_publish_name(value)
	return type(value) == "string"
		and #value > 0
		and #value <= 255
		and value ~= "."
		and value ~= ".."
		and not value:find("/", 1, true)
		and not value:find("\0", 1, true)
end

local function publish_directory_bound(directory)
	local opened = directory and uv.fs_fstat(directory.fd) or nil
	local visible = directory and uv.fs_lstat(directory.path) or nil
	return same_entry_stat(opened, directory and directory.stat)
		and same_entry_stat(visible, directory.stat)
		and uv.fs_realpath(directory.path) == directory.path
end

local function close_publish_directory(directory)
	if not directory or not directory.fd then
		return true
	end
	local closed, close_err = uv.fs_close(directory.fd)
	directory.fd = nil
	return closed, close_err
end

local function open_publish_directory(path, expected)
	if not ffi_ok or (SYSTEM ~= "Darwin" and SYSTEM ~= "Linux") then
		return nil, "descriptor-relative-publish-unavailable"
	end
	path = vim.fs.normalize(path)
	local inspected = uv.fs_lstat(path)
	if
		not same_entry_stat(inspected, expected)
		or inspected.type ~= "directory"
		or inspected.mode % 512 ~= PRIVATE_DIRECTORY_MODE
		or uv.fs_realpath(path) ~= path
	then
		return nil, "publish-parent-changed"
	end
	local flags = PUBLISH_OPEN_FLAGS.directory
		+ PUBLISH_OPEN_FLAGS.nonblock
		+ PUBLISH_OPEN_FLAGS.no_follow
		+ PUBLISH_OPEN_FLAGS.close_exec
	local raw_fd = ffi.C.openat(AT_FDCWD, path, flags)
	if raw_fd < 0 then
		return nil, "publish-parent-open-failed:errno " .. tostring(ffi.errno())
	end
	local directory = { fd = tonumber(raw_fd), path = path, stat = vim.deepcopy(inspected) }
	if not publish_directory_bound(directory) then
		close_publish_directory(directory)
		return nil, "publish-parent-changed"
	end
	return directory
end

local function open_publish_entry(directory, name, expected)
	if not safe_publish_name(name) or not publish_directory_bound(directory) then
		return nil, "publish-entry-parent-or-name-changed"
	end
	local flags = PUBLISH_OPEN_FLAGS.nonblock + PUBLISH_OPEN_FLAGS.no_follow + PUBLISH_OPEN_FLAGS.close_exec
	if expected.type == "directory" then
		flags = flags + PUBLISH_OPEN_FLAGS.directory
	end
	local raw_fd = ffi.C.openat(directory.fd, name, flags)
	if raw_fd < 0 then
		return nil, "publish-entry-open-failed:errno " .. tostring(ffi.errno())
	end
	local fd = tonumber(raw_fd)
	local opened = uv.fs_fstat(fd)
	if not same_entry_stat(opened, expected) then
		uv.fs_close(fd)
		return nil, "publish-entry-changed"
	end
	return fd
end

local function no_clobber_rename(source, target, expected, source_parent_expected, target_parent_expected)
	if not ffi_ok or (SYSTEM ~= "Darwin" and SYSTEM ~= "Linux") then
		return nil, "no-clobber-publish-unavailable"
	end
	local source_parent_path = vim.fs.dirname(source)
	local target_parent_path = vim.fs.dirname(target)
	local source_name = vim.fs.basename(source)
	local target_name = vim.fs.basename(target)
	if not safe_publish_name(source_name) or not safe_publish_name(target_name) then
		return nil, "no-clobber-publish-name-unsafe"
	end
	local source_parent, source_parent_err = open_publish_directory(source_parent_path, source_parent_expected)
	if not source_parent then
		return nil, "no-clobber-source-parent:" .. tostring(source_parent_err)
	end
	local target_parent, target_parent_err = open_publish_directory(target_parent_path, target_parent_expected)
	if not target_parent then
		close_publish_directory(source_parent)
		return nil, "no-clobber-target-parent:" .. tostring(target_parent_err)
	end
	local source_fd, source_err = open_publish_entry(source_parent, source_name, expected)
	if not source_fd then
		close_publish_directory(target_parent)
		close_publish_directory(source_parent)
		return nil, "no-clobber-source-changed:" .. tostring(source_err)
	end
	local function finish(value, err, errno)
		local source_closed, source_close_err = uv.fs_close(source_fd)
		local target_closed, target_close_err = close_publish_directory(target_parent)
		local parent_closed, parent_close_err = close_publish_directory(source_parent)
		if value and (not source_closed or not target_closed or not parent_closed) then
			return nil,
				"no-clobber-publish-close-failed:" .. tostring(source_close_err or target_close_err or parent_close_err),
				errno
		end
		return value, err, errno
	end
	local hook_ok, hook_err = pcall(M._interleave, "before-publish-rename", {
		source = source,
		target = target,
		source_parent = source_parent_path,
		target_parent = target_parent_path,
	})
	if not hook_ok or not publish_directory_bound(source_parent) or not publish_directory_bound(target_parent) then
		return finish(nil, "no-clobber-publish-parent-changed:" .. tostring(hook_err or "identity changed"))
	end
	local ok, result = pcall(function()
		if SYSTEM == "Darwin" then
			return ffi.C.renameatx_np(source_parent.fd, source_name, target_parent.fd, target_name, 4)
		end
		return ffi.C.renameat2(source_parent.fd, source_name, target_parent.fd, target_name, 1)
	end)
	if not ok or result ~= 0 then
		local errno = ok and ffi.errno() or nil
		return finish(nil, "no-clobber-publish-failed:" .. tostring(errno or result), errno)
	end
	local target_fd, target_err = open_publish_entry(target_parent, target_name, expected)
	if not target_fd then
		return finish(nil, "no-clobber-published-identity-changed:" .. tostring(target_err))
	end
	local target_fd_closed, target_fd_close_err = uv.fs_close(target_fd)
	if
		not publish_directory_bound(source_parent)
		or not publish_directory_bound(target_parent)
		or not target_fd_closed
	then
		return finish(
			nil,
			"no-clobber-published-parent-changed:" .. tostring(target_fd_close_err or "identity changed")
		)
	end
	local source_synced, source_sync_err = uv.fs_fsync(source_parent.fd)
	local target_synced, target_sync_err = uv.fs_fsync(target_parent.fd)
	if not source_synced or not target_synced then
		return finish(nil, "no-clobber-publish-sync-failed:" .. tostring(source_sync_err or target_sync_err))
	end
	return finish(true)
end

local function remove_empty_stage(path, expected)
	local current = uv.fs_lstat(path)
	if
		current
		and expected
		and current.type == "directory"
		and current.dev == expected.dev
		and current.ino == expected.ino
		and current.mode % 512 == PRIVATE_DIRECTORY_MODE
		and uv.fs_realpath(path) == vim.fs.normalize(path)
	then
		pcall(uv.fs_rmdir, path)
	end
end

local function publish_receipt(plan, stage, closure)
	if
		type(closure) ~= "table"
		or not exact_keys(closure, { bytes = true, entries = true, sha256 = true })
		or type(closure.entries) ~= "table"
		or type(closure.bytes) ~= "number"
		or not tostring(closure.sha256):match("^[0-9a-f]+$")
		or #closure.sha256 ~= 64
	then
		return nil, "bundle-closure-invalid"
	end
	local receipt = vim.tbl_extend("force", vim.deepcopy(plan.receipt), {
		bytes = closure.bytes,
		entries = closure.entries,
		closure_sha256 = closure.sha256,
	})
	local encoded = canonical_encode(receipt)
	if not encoded then
		return nil, "bundle-receipt-encode-failed"
	end
	local contents = encoded .. "\n"
	if #contents > MAX_METADATA_BYTES then
		return nil, "bundle-receipt-too-large"
	end
	local temporary = vim.fs.joinpath(stage, "receipt.json")
	local wrote, write_err = fs.write_binary_atomic(temporary, contents)
	if not wrote or not uv.fs_chmod(temporary, PRIVATE_FILE_MODE) then
		return nil, "bundle-receipt-write-failed:" .. tostring(write_err)
	end
	local receipt_parent, parent_err = ensure_private_directory(vim.fs.dirname(plan.receipt_path))
	if not receipt_parent then
		return nil, parent_err
	end
	local receipt_parent_stat = uv.fs_lstat(receipt_parent)
	if not receipt_parent_stat or receipt_parent_stat.type ~= "directory" then
		return nil, "bundle-receipt-parent-changed"
	end
	local temporary_stat = uv.fs_lstat(temporary)
	if not temporary_stat or temporary_stat.type ~= "file" or temporary_stat.nlink ~= 1 then
		return nil, "bundle-receipt-staging-changed"
	end
	return {
		temporary = temporary,
		contents = contents,
		stat = temporary_stat,
		parent = receipt_parent,
		parent_stat = receipt_parent_stat,
	}
end

function M.observe(value)
	local plan, plan_err = validate_plan(value)
	if not plan then
		return nil, plan_err
	end
	return {
		kind = "bundle-sha256",
		source_sha256 = plan.source_sha256,
		bundle_root = plan.install_root,
		receipt_path = plan.receipt_path,
		commands = { devcontainer = vim.fs.joinpath(plan.install_root, "bin", "devcontainer") },
	}
end

local function decode_closure(result)
	local output = type(result) == "table" and result.stdout or ""
	if type(result) ~= "table" or result.code ~= 0 or #output > MAX_METADATA_BYTES then
		return nil, helper_failure_reason("bundle-closure-failed", result)
	end
	local ok, value = pcall(vim.json.decode, output)
	if not ok or type(value) ~= "table" then
		return nil, helper_failure_reason("bundle-closure-failed", result)
	end
	return value
end

local function helper_command(commands, action, root, stat, arguments)
	local command = {
		commands.python3,
		"-I",
		"-B",
		commands.helper,
		action,
		"--root",
		root,
		"--root-dev",
		tostring(stat.dev),
		"--root-ino",
		tostring(stat.ino),
	}
	vim.list_extend(command, arguments or {})
	return command
end

-- Cancellation signals only the active child. Its callback remains the single
-- completion path responsible for cleanup and the exactly-once ACK.
function M.install(value, callback)
	callback = callback or function() end
	local plan, plan_err = validate_plan(value)
	if not plan then
		callback(false, plan_err)
		return false
	end
	local commands, commands_err = safe_prerequisites(plan)
	if not commands then
		callback(false, commands_err)
		return false
	end
	local managed_root, root_err = ensure_managed_root(paths.managed_root())
	if not managed_root then
		callback(false, root_err)
		return false
	end
	local staging, staging_err = ensure_private_directory(vim.fs.joinpath(managed_root, "staging", "npm-release"))
	if not staging then
		callback(false, staging_err)
		return false
	end
	local stage = vim.fs.joinpath(staging, ("job-%d-%d"):format(uv.os_getpid(), uv.hrtime()))
	local stage_ready, stage_err = ensure_private_directory(stage)
	if not stage_ready then
		callback(false, stage_err)
		return false
	end
	local stage_stat = uv.fs_lstat(stage)
	if not stage_stat or stage_stat.type ~= "directory" then
		callback(false, "stage-directory-changed")
		return false
	end
	local bundle = vim.fs.joinpath(stage, "bundle")
	local bundle_ready, bundle_err = ensure_private_directory(bundle)
	if not bundle_ready then
		remove_empty_stage(stage, stage_stat)
		callback(false, bundle_err)
		return false
	end
	local bundle_stat = uv.fs_lstat(bundle)
	if not bundle_stat or bundle_stat.type ~= "directory" then
		remove_empty_stage(stage, stage_stat)
		callback(false, "bundle-directory-changed")
		return false
	end
	local selected_metadata = canonical_encode({
		name = plan.metadata.name,
		version = plan.metadata.version,
		bin = plan.metadata.bin,
		engines = plan.metadata.engines,
	})
	if not selected_metadata then
		callback(false, "selected-metadata-encode-failed")
		return false
	end
	local controller = { completed = false, finishing = false, cancelled = false, process = nil, signal_sent = false }
	function controller.finish(ok, result)
		if controller.completed or controller.finishing then
			return
		end
		controller.finishing = true
		controller.process = nil
		local function complete(cleanup_result)
			if controller.completed then
				return
			end
			controller.completed = true
			controller.finishing = false
			remove_empty_stage(stage, stage_stat)
			if type(cleanup_result) ~= "table" or cleanup_result.code ~= 0 then
				vim.schedule(function()
					vim.notify(
						"npm-release retained private staging evidence after safe cleanup failed",
						vim.log.levels.WARN,
						{ title = "Tools" }
					)
				end)
			end
			schedule_on_main(callback, ok == true, result)
		end
		local cleanup = M._run({
			commands.python3,
			"-I",
			"-B",
			commands.helper,
			"clean-stage",
			"--root",
			stage,
			"--dev",
			tostring(stage_stat.dev),
			"--ino",
			tostring(stage_stat.ino),
		}, { text = true }, complete)
		if not cleanup then
			complete({ code = -1 })
		end
	end
	function controller.cancel()
		if controller.completed or controller.finishing or controller.cancelled then
			return
		end
		controller.cancelled = true
		if controller.process and type(controller.process.kill) == "function" and not controller.signal_sent then
			controller.signal_sent = true
			pcall(controller.process.kill, controller.process, 15)
		end
	end
	local function run(command, options, done)
		if controller.cancelled then
			controller.finish(false, "cancelled")
			return false
		end
		controller.process = M._run(command, options or { text = true }, function(result)
			controller.process = nil
			if controller.cancelled then
				controller.finish(false, "cancelled")
				return
			end
			done(type(result) == "table" and result or { code = -1, stderr = "invalid process result" })
		end)
		if not controller.process then
			controller.finish(false, "process-start-failed")
			return false
		end
		return true
	end
	local node_archive = vim.fs.joinpath(stage, plan.node_asset.archive)
	local package_archive = vim.fs.joinpath(stage, "package.tgz")
	local curl_base = {
		commands.curl,
		"--disable",
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--proto",
		"=https",
		"--proto-redir",
		"=https",
		"--tlsv1.2",
	}
	local function download(url, output, maximum, done)
		local command = vim.deepcopy(curl_base)
		vim.list_extend(command, { "--max-filesize", tostring(maximum), "--output", output, url })
		run(command, { text = true }, function(result)
			local safe, safe_err
			if result.code == 0 then
				safe, safe_err = safe_download(output, stage, maximum)
			end
			if not safe then
				controller.finish(false, result.code == 0 and safe_err or "download-failed")
				return
			end
			done()
		end)
	end
	download(plan.node_url, node_archive, MAX_NODE_ARCHIVE_BYTES, function()
		run(
			helper_command(commands, "extract-node", bundle, bundle_stat, {
				"--archive",
				node_archive,
				"--sha256",
				plan.node_asset.sha256,
				"--member",
				plan.node_member,
			}),
			{ text = true },
			function(node_result)
				if node_result.code ~= 0 then
					controller.finish(false, helper_failure_reason("node-extraction-failed", node_result))
					return
				end
				download(plan.metadata.tarball, package_archive, MAX_PACKAGE_ARCHIVE_BYTES, function()
					run(
						helper_command(commands, "extract-package", bundle, bundle_stat, {
							"--archive",
							package_archive,
							"--integrity",
							plan.metadata.integrity,
						}),
						{ text = true },
						function(package_result)
							if package_result.code ~= 0 then
								controller.finish(
									false,
									helper_failure_reason("package-extraction-failed", package_result)
								)
								return
							end
							run(
								helper_command(commands, "finalize-package", bundle, bundle_stat, {
									"--metadata",
									selected_metadata,
									"--install-root",
									plan.install_root,
								}),
								{ text = true },
								function(finalize_result)
									if finalize_result.code ~= 0 then
										controller.finish(
											false,
											helper_failure_reason("package-finalization-failed", finalize_result)
										)
										return
									end
									run(
										helper_command(commands, "closure", bundle, bundle_stat),
										{ text = true },
										function(closure_result)
											local closure, closure_err = decode_closure(closure_result)
											if not closure then
												controller.finish(false, closure_err)
												return
											end
											local receipt, receipt_err = publish_receipt(plan, stage, closure)
											if not receipt then
												controller.finish(false, receipt_err)
												return
											end
											local final_parent, final_parent_err =
												ensure_private_directory(vim.fs.dirname(plan.install_root))
											if not final_parent then
												controller.finish(false, final_parent_err)
												return
											end
											local final_parent_stat = uv.fs_lstat(final_parent)
											if not final_parent_stat or final_parent_stat.type ~= "directory" then
												controller.finish(false, "bundle-parent-changed")
												return
											end
											local function finish_publish()
												local receipt_published, receipt_publish_err, receipt_errno =
													no_clobber_rename(
														receipt.temporary,
														plan.receipt_path,
														receipt.stat,
														stage_stat,
														receipt.parent_stat
													)
												if not receipt_published and receipt_errno == 17 then
													local existing, existing_err =
														read_private(plan.receipt_path, MAX_METADATA_BYTES)
													if existing == receipt.contents then
														receipt_published = true
													else
														receipt_publish_err = "existing-receipt-mismatch:"
															.. tostring(existing_err)
													end
												end
												if not receipt_published then
													controller.finish(false, receipt_publish_err)
													return
												end
												controller.finish(true, {
													kind = "bundle-install-evidence",
													source_sha256 = plan.source_sha256,
													receipt_sha256 = vim.fn.sha256(receipt.contents),
													warnings = {},
												})
											end
											local published, publish_err, publish_errno = no_clobber_rename(
												bundle,
												plan.install_root,
												bundle_stat,
												stage_stat,
												final_parent_stat
											)
											if published then
												finish_publish()
												return
											end
											if publish_errno ~= 17 then
												controller.finish(false, publish_err)
												return
											end
											-- A crash may have published the immutable bundle before its
											-- receipt. Adopt only an exact closure match; a rival or partial
											-- directory remains untouched and the prior active slot survives.
											local existing_stat = uv.fs_lstat(plan.install_root)
											if not existing_stat or existing_stat.type ~= "directory" then
												controller.finish(false, "existing-bundle-unsafe")
												return
											end
											run(
												helper_command(commands, "closure", plan.install_root, existing_stat),
												{ text = true },
												function(existing_result)
													local existing, existing_err = decode_closure(existing_result)
													if not existing or not vim.deep_equal(existing, closure) then
														controller.finish(
															false,
															existing_err or "existing-bundle-mismatch"
														)
														return
													end
													finish_publish()
												end
											)
										end
									)
								end
							)
						end
					)
				end)
			end
		)
	end)
	return controller
end

return M
