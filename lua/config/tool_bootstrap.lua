-- Host adapter for verified-tools.nvim. Commands, manifests, upstream probes,
-- and backend mechanics stay here; lifecycle/locks/proofs/shims stay in core.
local M = {}

local fs = require("config.fs")
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local release = require("config.release_installer")
local npm_release = require("config.npm_release_installer")
local legacy_state = require("config.tool_state")
local engine = require("verified_tools")
local uv = vim.uv

local markdown_ok, markdown_bridge = pcall(require, "verified_tools.markdown_preview")
local lazy_config_ok, lazy_config = pcall(require, "lazy.core.config")
local setup_done = false
local command_done = false
local install_queue = {}
local install_active = 0
local install_draining = false
local install_active_groups = {}
local install_generation = 0
local install_requests = {}
local install_request_sequence = 0

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local PROGRESS_INTERVAL_MS = 500
local FAILED_NAMES_LIMIT = 5

M._notify = function(message, level, options)
	local notify_options = { title = "Tools" }
	for key, value in pairs(type(options) == "table" and options or {}) do
		notify_options[key] = value
	end
	vim.notify(message, level or vim.log.levels.INFO, notify_options)
end
M._visual_notify = function(message, level, options)
	local snacks = rawget(_G, "Snacks")
	local notifier = type(snacks) == "table" and snacks.notifier or nil
	if type(notifier) ~= "table" or type(notifier.notify) ~= "function" then
		return false
	end
	local ok = pcall(notifier.notify, message, level, options)
	return ok
end
M._visual_hide = function(id)
	local snacks = rawget(_G, "Snacks")
	local notifier = type(snacks) == "table" and snacks.notifier or nil
	if type(notifier) ~= "table" or type(notifier.hide) ~= "function" then
		return false
	end
	local ok = pcall(notifier.hide, id)
	return ok
end
M._new_timer = function()
	return uv.new_timer()
end
M._schedule = vim.schedule
M._registry = function()
	-- Loading mason-registry activates mason.nvim through Lazy. Resolve it only
	-- after this adapter has finished publishing its own setup state so that a
	-- Mason init cannot re-enter a half-loaded config.tool_bootstrap module.
	local ok, registry = pcall(require, "mason-registry")
	return ok and registry or nil
end
M._network_authorized = function()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end
M._system = vim.system
M._markdown_plugin_root = function()
	if not lazy_config_ok or type(lazy_config.plugins) ~= "table" then
		return nil
	end
	local plugin = lazy_config.plugins["markdown-preview.nvim"]
	return plugin and plugin.dir or nil
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
	local pieces = {}
	if length > 0 then
		for key in pairs(value) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
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
			pieces[#pieces + 1] = encoded
		end
		seen[value] = nil
		return "[" .. table.concat(pieces, ",") .. "]"
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
		pieces[#pieces + 1] = encoded_key .. ":" .. encoded_value
	end
	seen[value] = nil
	return "{" .. table.concat(pieces, ",") .. "}"
end

local MANAGED_ONLY = { ["markdown-preview"] = true, ["devcontainers-cli"] = true, difftastic = true }

local function external_recovery(name, detail)
	detail = tostring(detail)
	if detail:find("managed authority", 1, true) then
		return ("use :NvimConfigToolsInstall! %s to repair managed authority; external fallback is disabled"):format(
			name
		)
	end
	if
		detail:find("unsafe", 1, true)
		or detail:find("identity changed", 1, true)
		or detail:find("permissions", 1, true)
		or detail:find("could not be opened", 1, true)
	then
		return ("the unsafe private external receipt will not be overwritten; inspect and remove its exact entry under verified-tools/external-records before rerunning :NvimConfigToolsInstall %s, or use :NvimConfigToolsInstall! %s to select managed authority"):format(
			name,
			name
		)
	end
	return ("rerun :NvimConfigToolsInstall %s to recertify, or use ! to select managed authority"):format(name)
end

local function platform_target()
	local uname = uv.os_uname()
	return manifest.target_key(uname.sysname, uname.machine) or (uname.sysname .. "-" .. uname.machine):lower()
end

local function bounded(value)
	return tostring(value or ""):gsub("[%c]", " "):sub(1, 160)
end

local function version_tokens(output)
	local result = {}
	for token in tostring(output):gmatch("[%w][%w._+-]*") do
		result[token] = true
	end
	return result
end

local function exact_version(output, expected)
	local tokens = version_tokens(output)
	if tokens[expected] then
		return true
	end
	if expected:sub(1, 1) == "v" and tokens[expected:sub(2)] then
		return true
	end
	return false
end

local function external_candidates(command)
	if type(paths.external_candidates) == "function" then
		return paths.external_candidates(command)
	end
	local candidate = paths.external_executable(command)
	return candidate and { candidate } or {}
end

local function probe_candidate(path, version)
	local started, process = pcall(M._system, { path, "--version" }, { text = true })
	if not started or type(process) ~= "table" or type(process.wait) ~= "function" then
		return nil, "spawn-failed"
	end
	local waited, result = pcall(process.wait, process, 2000)
	if not waited or type(result) ~= "table" then
		return nil, "wait-failed"
	end
	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	if result.code ~= 0 then
		return nil, result.code == 124 and "timeout" or "exit-" .. tostring(result.code)
	end
	return exact_version(output, version), bounded(output)
end

-- Every candidate for the manifest-selected version probe is executed. Other
-- declared commands must resolve from that probe's installation directory; a
-- timeout, error, or split installation blocks planning.
local function external_probe(identity, spec)
	local candidates_by_command = {}
	local safe_candidates_by_command = {}
	local saw_any = false
	local incompatible = {}
	local unsafe = {}
	for _, command in ipairs(sorted_keys(spec.executables)) do
		local candidates = external_candidates(command)
		candidates_by_command[command] = candidates
		safe_candidates_by_command[command] = {}
		if #candidates == 0 then
			incompatible[#incompatible + 1] = command .. "=missing"
		end
		saw_any = saw_any or #candidates > 0
		for _, path in ipairs(candidates) do
			local safe, authority_err = engine.validate_external_candidate(path)
			if not safe then
				unsafe[#unsafe + 1] = command .. "@" .. path .. "=unsafe:" .. bounded(authority_err)
			else
				safe_candidates_by_command[command][#safe_candidates_by_command[command] + 1] = safe
			end
		end
	end
	if not saw_any then
		return { outcome = "absent" }
	end
	if #unsafe > 0 then
		return { outcome = "incompatible", detail = bounded(table.concat(unsafe, ";")) }
	end
	local entry = spec.manifest and spec.manifest.entry or {}
	local probe_command = entry.version_probe or sorted_keys(spec.executables)[1]
	if not spec.executables[probe_command] then
		return { outcome = "error", detail = "manifest version probe is not a declared command" }
	end
	local compatible_path
	for index, path in ipairs(candidates_by_command[probe_command] or {}) do
		local safe_path, authority_err = engine.validate_external_candidate(path)
		if not safe_path then
			incompatible[#incompatible + 1] = probe_command .. "@" .. path .. "=unsafe:" .. bounded(authority_err)
		else
			local matches, detail = probe_candidate(safe_path, identity.version)
			if matches == nil then
				return { outcome = "error", detail = probe_command .. ":" .. detail }
			end
			-- PATH executes the first candidate. Keep inspecting every later
			-- candidate for probe errors, but never certify one hidden behind an
			-- incompatible executable that would actually win command lookup.
			if index == 1 and matches then
				compatible_path = safe_path
			elseif not matches then
				incompatible[#incompatible + 1] = probe_command .. "@" .. path .. "=" .. detail
			end
		end
	end
	if not compatible_path then
		incompatible[#incompatible + 1] = probe_command .. "=no-exact-version"
	end
	local probe_directory = compatible_path and vim.fs.dirname(compatible_path) or nil
	for command, candidates in pairs(safe_candidates_by_command) do
		if #candidates == 0 or (compatible_path and vim.fs.dirname(candidates[1]) ~= probe_directory) then
			compatible_path = nil
			if #candidates > 0 then
				incompatible[#incompatible + 1] = command .. "=different-install-root"
			end
			break
		end
	end
	if not compatible_path then
		return { outcome = "incompatible", detail = bounded(table.concat(incompatible, ";")) }
	end
	local selected = {}
	for command, candidates in pairs(safe_candidates_by_command) do
		selected[command] = command == probe_command and compatible_path or candidates[1]
	end
	return { outcome = "compatible", version = identity.version, paths = selected }
end

local function release_observation(plan)
	local integrity = plan.manifest.integrity
	local commands = {}
	for command, relative in pairs(integrity.commands) do
		commands[command] = vim.fs.normalize(vim.fs.joinpath(plan.identity.install_root, relative))
	end
	local artifacts = {}
	for _, relative in ipairs(integrity.artifacts) do
		artifacts[relative] = vim.fs.normalize(vim.fs.joinpath(plan.identity.install_root, relative))
	end
	return {
		kind = "release-sha256",
		archive_sha256 = integrity.archive_sha256,
		commands = commands,
		artifacts = artifacts,
	}
end

local release_backend = {}
function release_backend.run(plan, done, control)
	local ready, reason = release.preflight(plan.manifest.release_plan)
	if not ready then
		done(false, reason)
		return false
	end
	local controller = release.install(plan.manifest.release_plan, done)
	if type(controller) == "table" and type(controller.cancel) == "function" then
		control.set_cancel(controller.cancel)
	end
	return nil
end
function release_backend.attest(plan, done)
	done(true, release_observation(plan))
end

local npm_release_backend = {}
function npm_release_backend.run(plan, done, control)
	local ready, reason = npm_release.preflight(plan.manifest.npm_release_plan)
	if not ready then
		done(false, reason)
		return false
	end
	local controller = npm_release.install(plan.manifest.npm_release_plan, done)
	if type(controller) == "table" and type(controller.cancel) == "function" then
		control.set_cancel(controller.cancel)
	end
	return nil
end
function npm_release_backend.attest(plan, done)
	local observed, observe_err = npm_release.observe(plan.manifest.npm_release_plan)
	done(observed ~= nil, observed or observe_err)
end

local function same_timestamp(left, right)
	return left and right and left.sec == right.sec and left.nsec == right.nsec
end

local function private_metadata(info)
	return not info or (info.mode % 512 == tonumber("600", 8) and (not uv.getuid or info.uid == uv.getuid()))
end

local function same_stable_file(left, right, private)
	return left
		and right
		and left.type == "file"
		and right.type == "file"
		and left.nlink == 1
		and right.nlink == 1
		and left.dev == right.dev
		and left.ino == right.ino
		and left.size == right.size
		and left.mode == right.mode
		and left.uid == right.uid
		and same_timestamp(left.mtime, right.mtime)
		and same_timestamp(left.ctime, right.ctime)
		and (not private or (private_metadata(left) and private_metadata(right)))
end

local function read_stable(path, private)
	local before = uv.fs_lstat(path)
	if not before or before.type ~= "file" or before.nlink ~= 1 or (private and not private_metadata(before)) then
		return nil, "unsafe-file"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "open-failed:" .. tostring(open_err)
	end
	local first = uv.fs_fstat(fd)
	if not same_stable_file(before, first, private) or first.size > 262144 then
		uv.fs_close(fd)
		return nil, "file-changed"
	end
	local data, read_err = uv.fs_read(fd, first.size, 0)
	local last = uv.fs_fstat(fd)
	local closed, close_err = uv.fs_close(fd)
	local after = uv.fs_lstat(path)
	if
		type(data) ~= "string"
		or #data ~= first.size
		or not closed
		or not same_stable_file(first, last, private)
		or not same_stable_file(first, after, private)
	then
		return nil, "read-failed:" .. tostring(read_err or close_err or "file changed")
	end
	return data
end

local function safe_relative(value)
	if type(value) ~= "string" or value == "" or value:sub(1, 1) == "/" or value:find("%z") then
		return nil
	end
	for segment in value:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil
		end
	end
	return vim.fs.normalize(value) == value and not value:find("\\", 1, true) and value or nil
end

local function contained(path, root)
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function ensure_private_directory(path, root)
	local stat = uv.fs_lstat(path)
	if not stat then
		local made, err = uv.fs_mkdir(path, 448)
		if not made then
			return nil, "private-mkdir-failed:" .. tostring(err)
		end
		stat = uv.fs_lstat(path)
	end
	local canonical = stat and stat.type == "directory" and uv.fs_realpath(path) or nil
	if not canonical or not contained(canonical, root) then
		return nil, "private-directory-unsafe"
	end
	if not uv.fs_chmod(path, 448) then
		return nil, "private-directory-chmod-failed"
	end
	return canonical
end

local function private_receipt_path(plan)
	return vim.fs.normalize(vim.fs.joinpath(plan.identity.install_root, plan.manifest.integrity.receipt_path))
end

local function write_private_receipt(plan)
	local root = plan.identity.install_root
	local private_root, root_err = ensure_private_directory(vim.fs.joinpath(root, ".verified-tools"), root)
	if not private_root then
		return nil, root_err
	end
	local receipts, receipts_err = ensure_private_directory(vim.fs.joinpath(private_root, "receipts"), root)
	if not receipts then
		return nil, receipts_err
	end
	local target = private_receipt_path(plan)
	if vim.fs.dirname(target) ~= receipts then
		return nil, "private-receipt-path-invalid"
	end
	local current = uv.fs_lstat(target)
	if current and (current.type ~= "file" or current.nlink ~= 1) then
		return nil, "private-receipt-unsafe"
	end
	local data = vim.json.encode(plan.manifest.integrity.receipt) .. "\n"
	local wrote, write_err = fs.write_binary_atomic(target, data)
	if not wrote or not uv.fs_chmod(target, 384) then
		return nil, "private-receipt-write-failed:" .. tostring(write_err)
	end
	return true
end

local function decode_json_file(path, private)
	local data, read_err = read_stable(path, private)
	if not data then
		return nil, read_err
	end
	local ok, value = pcall(vim.json.decode, data)
	if not ok or type(value) ~= "table" then
		return nil, "json-invalid"
	end
	return value
end

local function registry_package(name)
	local called, registry = pcall(M._registry)
	if not called or type(registry) ~= "table" then
		return nil, "mason-registry-unavailable"
	end
	local has_ok, has = pcall(registry.has_package, name)
	if not has_ok or not has then
		return nil, "mason-package-unavailable"
	end
	local package_ok, pkg = pcall(registry.get_package, name)
	if not package_ok then
		return nil, "mason-package-unavailable"
	end
	return pkg
end

local function validate_raw_mason(plan)
	local pkg, package_err = registry_package(plan.identity.name)
	if not pkg then
		return nil, package_err
	end
	local installed_ok, installed = pcall(pkg.is_installed, pkg)
	local version_ok, version = pcall(pkg.get_installed_version, pkg)
	if not installed_ok or installed ~= true or not version_ok or version ~= plan.identity.version then
		return nil, "mason-version-mismatch"
	end
	local package_root = vim.fs.joinpath(plan.identity.install_root, "packages", plan.identity.name)
	local canonical_package = uv.fs_realpath(package_root)
	if not canonical_package or not contained(canonical_package, plan.identity.install_root) then
		return nil, "mason-package-root-unsafe"
	end
	local raw_path = vim.fs.joinpath(canonical_package, "mason-receipt.json")
	local raw_data, raw_err = read_stable(raw_path, false)
	local raw
	if raw_data then
		local decoded_ok, decoded = pcall(vim.json.decode, raw_data)
		raw = decoded_ok and type(decoded) == "table" and decoded or nil
	end
	if not raw then
		return nil, "mason-raw-receipt-" .. tostring(raw_err or "json-invalid")
	end
	if
		raw.name ~= plan.identity.name or not ({ ["1.0"] = true, ["1.1"] = true, ["2.0"] = true })[raw.schema_version]
	then
		return nil, "mason-raw-receipt-identity-mismatch"
	end
	local source = raw.schema_version == "2.0" and raw.source or raw.primary_source
	local source_version = type(source) == "table" and type(source.id) == "string" and source.id:match("@([^@]+)$")
	if source_version ~= plan.manifest.integrity.receipt.source_version then
		return nil, "mason-source-version-mismatch"
	end
	local links = type(raw.links) == "table" and raw.links.bin or nil
	if type(links) ~= "table" then
		return nil, "mason-bin-links-invalid"
	end
	local commands = {}
	local command_fingerprints = {}
	local expected_commands = sorted_keys(plan.executables)
	if #sorted_keys(links) ~= #expected_commands then
		return nil, "mason-bin-links-not-exact"
	end
	for _, command in ipairs(expected_commands) do
		local relative = links[command]
		if not safe_relative(relative) then
			return nil, "mason-bin-link-invalid:" .. command
		end
		local source_path = vim.fs.joinpath(canonical_package, relative)
		local source_real = uv.fs_realpath(source_path)
		local command_path = vim.fs.normalize(vim.fs.joinpath(plan.identity.install_root, "bin", command))
		local command_stat = uv.fs_lstat(command_path)
		local command_real = command_stat and uv.fs_realpath(command_path) or nil
		local target_stat = source_real and uv.fs_stat(source_real) or nil
		if
			not source_real
			or not contained(source_real, canonical_package)
			or not command_stat
			or (command_stat.type ~= "link" and command_stat.type ~= "file")
			or command_real ~= source_real
			or not target_stat
			or target_stat.type ~= "file"
			or vim.fn.executable(command_path) ~= 1
		then
			return nil, "mason-command-link-invalid:" .. command
		end
		commands[command] = command_path
		command_fingerprints[command] = {
			command_path = command_path,
			command_type = command_stat.type,
			command_dev = command_stat.dev,
			command_ino = command_stat.ino,
			source_path = source_real,
			source_dev = target_stat.dev,
			source_ino = target_stat.ino,
			source_size = target_stat.size,
			source_mtime = target_stat.mtime,
		}
	end
	for command in pairs(links) do
		if not plan.executables[command] then
			return nil, "mason-bin-links-not-exact"
		end
	end
	return {
		pkg = pkg,
		commands = commands,
		fingerprint = { raw_sha256 = vim.fn.sha256(raw_data), commands = command_fingerprints },
	}
end

local function mason_observation(plan, create_receipt)
	local validated, validation_err = validate_raw_mason(plan)
	if not validated then
		return nil, validation_err
	end
	if create_receipt then
		local wrote, write_err = write_private_receipt(plan)
		if not wrote then
			return nil, write_err
		end
	end
	local private = private_receipt_path(plan)
	local decoded, decode_err = decode_json_file(private, true)
	if not decoded or not vim.deep_equal(decoded, plan.manifest.integrity.receipt) then
		return nil, "mason-private-receipt-invalid:" .. tostring(decode_err)
	end
	-- Writing/reading the private receipt is deliberately between two full raw
	-- validations. A concurrent Mason mutation must not be certified against a
	-- stale receipt/link snapshot.
	local revalidated, revalidation_err = validate_raw_mason(plan)
	if not revalidated then
		return nil, revalidation_err
	end
	if not vim.deep_equal(validated.fingerprint, revalidated.fingerprint) then
		return nil, "mason-state-changed"
	end
	return { kind = "mason-local-integrity", receipt_path = private, commands = revalidated.commands }
end

local function check_mason_prerequisites(entry)
	for _, command in ipairs(entry.requires_all or {}) do
		if not paths.external_executable(command) then
			return nil, "missing-prerequisite:" .. command
		end
	end
	local selected
	for _, command in ipairs(entry.requires_any or {}) do
		selected = selected or paths.external_executable(command)
	end
	if entry.requires_any and not selected then
		return nil, "missing-prerequisite:" .. table.concat(entry.requires_any, "|")
	end
	if entry.requires_python_venv then
		local started, process = pcall(M._system, { selected, "-c", "import venv" }, { text = true })
		if not started or type(process) ~= "table" or type(process.wait) ~= "function" then
			return nil, "python-venv-probe-error"
		end
		local waited, result = pcall(process.wait, process, 5000)
		if not waited or type(result) ~= "table" or result.code ~= 0 then
			return nil, "python-venv-unavailable"
		end
	end
	return true
end

local mason_backend = {}
function mason_backend.run(plan, done, control)
	local completed = false
	local function complete(ok, reason)
		if completed then
			return false
		end
		completed = true
		done(ok, reason)
		return true
	end
	local function defer_stage(stage, callback, ...)
		local arguments = { n = select("#", ...), ... }
		local scheduled, schedule_err = pcall(vim.schedule, function()
			if completed then
				return
			end
			local ok, err = xpcall(function()
				callback(unpack(arguments, 1, arguments.n))
			end, debug.traceback)
			if not ok then
				complete(false, stage .. "-crashed:" .. bounded(err))
			end
		end)
		if not scheduled then
			complete(false, stage .. "-schedule-failed:" .. bounded(schedule_err))
			return nil
		end
		return true
	end
	local ready, prereq_err = check_mason_prerequisites(plan.manifest.entry)
	if not ready then
		complete(false, prereq_err)
		return nil
	end
	local available, registry = pcall(M._registry)
	if not available or type(registry) ~= "table" then
		complete(false, "mason-registry-unavailable")
		return nil
	end
	local function after_refresh(success)
		if success ~= true then
			complete(false, "mason-refresh-failed")
			return
		end
		local second_ready, second_err = check_mason_prerequisites(plan.manifest.entry)
		if not second_ready then
			complete(false, second_err)
			return
		end
		local pkg, package_err = registry_package(plan.identity.name)
		if not pkg then
			complete(false, package_err)
			return
		end
		local install_ok, handle = pcall(
			pkg.install,
			pkg,
			{ version = plan.identity.version, force = true },
			function(installed)
				defer_stage("mason-post-install", function()
					if installed ~= true then
						complete(false, "mason-install-failed")
						return
					end
					local observe = M._mason_observation or mason_observation
					local observation, observation_err = observe(plan, true)
					if not observation then
						complete(false, observation_err)
						return
					end
					complete(true)
				end)
			end
		)
		if not install_ok then
			complete(false, "mason-install-start-failed:" .. bounded(handle))
		elseif type(handle) == "table" then
			local cancel = handle.cancel or handle.terminate
			if type(cancel) == "function" then
				local cancel_sent = false
				control.set_cancel(function()
					if cancel_sent or completed then
						return
					end
					if type(handle.is_closed) == "function" then
						local inspected, closed = pcall(handle.is_closed, handle)
						if not inspected or closed then
							return
						end
					end
					cancel_sent = true
					pcall(cancel, handle)
				end)
			end
		end
	end
	local refresh_ok, refresh_err = pcall(registry.refresh, function(success)
		defer_stage("mason-refresh-continuation", after_refresh, success)
	end)
	if not refresh_ok then
		complete(false, "mason-refresh-start-failed:" .. bounded(refresh_err))
		return nil
	end
	return nil
end

function mason_backend.attest(plan, done, _, context)
	local observation, err = mason_observation(plan, context and context.local_mason_adoption == true)
	done(observation ~= nil, observation or err)
end

local function release_spec(name, options)
	local plan, reason = release.plan(name, { force = true })
	if not plan then
		return nil, reason
	end
	local layout = plan.layout
	return {
		identity = {
			backend = "release",
			name = name,
			version = plan.entry.version,
			target = plan.target,
			digest = "sha256:" .. plan.asset.sha256:lower(),
			install_root = plan.install_root,
		},
		manifest = {
			entry = plan.entry,
			release_plan = plan,
			integrity = {
				kind = "release-sha256",
				archive_sha256 = plan.asset.sha256:lower(),
				commands = layout.commands,
				artifacts = layout.artifacts,
			},
		},
		executables = manifest.executable_map(plan.entry),
		requires_network = true,
		force_managed = MANAGED_ONLY[name] == true or options and options.force_managed == true or false,
	}
end

local function runtime_release_spec(name)
	local entry = manifest.managed_tools[name]
	if not entry then
		return nil, "unknown"
	end
	local uname = uv.os_uname()
	local asset, target = manifest.asset_for(entry, uname.sysname, uname.machine)
	if not asset then
		return nil, "unsupported"
	end
	local layout = manifest.release_layout(entry, asset)
	return {
		identity = {
			backend = "release",
			name = name,
			version = entry.version,
			target = target,
			digest = "sha256:" .. asset.sha256:lower(),
			install_root = paths.managed_root(),
		},
		manifest = {
			entry = vim.deepcopy(entry),
			integrity = {
				kind = "release-sha256",
				archive_sha256 = asset.sha256:lower(),
				commands = layout.commands,
				artifacts = layout.artifacts,
			},
		},
		executables = manifest.executable_map(entry),
		requires_network = true,
		force_managed = MANAGED_ONLY[name] == true,
	}
end

local function mason_spec(name, options)
	local entry = manifest.mason_entry(name)
	if not entry then
		return nil, "unknown"
	end
	local target = platform_target()
	local executables = manifest.executable_map(entry)
	local integrity = manifest.mason_integrity(name, entry)
	local encoded = canonical_encode({
		schema = 1,
		backend = "mason",
		name = name,
		version = entry.version,
		target = target,
		entry = entry,
		integrity = integrity,
		executables = executables,
	})
	if not encoded then
		return nil, "Mason manifest contract is not canonically encodable"
	end
	return {
		identity = {
			backend = "mason",
			name = name,
			version = entry.version,
			target = target,
			digest = "manifest:" .. vim.fn.sha256(encoded),
			install_root = paths.mason_root(),
		},
		manifest = { entry = vim.deepcopy(entry), integrity = integrity },
		executables = executables,
		requires_network = true,
		force_managed = options and options.force_managed == true or false,
	}
end

local function npm_release_spec(name, selected)
	local plan, plan_err = npm_release.plan(name, selected)
	if not plan then
		return nil, plan_err
	end
	return {
		identity = {
			backend = "npm-release",
			name = name,
			version = plan.metadata.version,
			target = plan.target,
			digest = "sha256:" .. plan.source_sha256,
			install_root = plan.install_root,
		},
		manifest = {
			entry = vim.deepcopy(plan.entry),
			npm_release_plan = plan,
			integrity = {
				kind = "bundle-sha256",
				source_sha256 = plan.source_sha256,
				receipt_path = plan.receipt_path,
				receipt = vim.deepcopy(plan.receipt),
				commands = vim.deepcopy(plan.commands),
			},
		},
		executables = { devcontainer = "devcontainer" },
		requires_network = true,
		force_managed = true,
	}
end

function M.spec(name, options)
	if manifest.managed_tools[name] then
		return release_spec(name, options)
	end
	if manifest.dynamic_entry(name) then
		if type(options) ~= "table" or type(options.selected) ~= "table" then
			return nil, "dynamic-version-requires-explicit-install"
		end
		return npm_release_spec(name, options.selected)
	end
	return mason_spec(name, options)
end

local function runtime_spec(name)
	if manifest.managed_tools[name] then
		return runtime_release_spec(name)
	end
	if manifest.dynamic_entry(name) then
		return nil, "dynamic-runtime-uses-active-slot"
	end
	return mason_spec(name)
end

function M.plan(name, options)
	if not setup_done then
		M.setup()
	end
	local spec, spec_err = M.spec(name, options)
	if not spec then
		return nil, spec_err
	end
	return engine.plan(spec)
end

---Resolve one manifest command through durable managed authority or an explicit
---external certification. This never plans, probes, installs, retries, repairs,
---searches PATH, or writes state. Non-bundle tools use their durable metadata;
---an active npm bundle rehashes its exact closure before returning its command.
---@param name string
---@param command string
---@return string? path
---@return string? error_message
function M.resolve(name, command)
	if type(name) ~= "string" or name == "" or type(command) ~= "string" or command == "" then
		return nil, "tool and command must be non-empty strings"
	end
	if manifest.dynamic_entry(name) then
		if command ~= manifest.dynamic_entry(name).command then
			return nil, ("tool %s does not provide %s"):format(name, command)
		end
		if not setup_done then
			M.setup()
		end
		local active, active_err = engine.resolve_active(name)
		if not active then
			return nil,
				("managed-only tool %s has no valid active bundle (%s); run :NvimConfigToolsInstall %s"):format(
					name,
					tostring(active_err),
					name
				)
		end
		local path = active.commands[command]
		if type(path) ~= "string" or path == "" then
			return nil, ("active tool resolution omitted %s"):format(command)
		end
		return path
	end
	local spec, spec_err = runtime_spec(name)
	if not spec then
		return nil, spec_err
	end
	if type(spec.executables) ~= "table" or spec.executables[command] == nil then
		return nil, ("tool %s does not provide %s"):format(name, command)
	end
	if not setup_done then
		M.setup()
	end
	local resolved, resolve_err = engine.resolve(spec)
	if not resolved and resolve_err == "absent" then
		if MANAGED_ONLY[name] then
			return nil, ("managed-only tool %s is not installed; run :NvimConfigToolsInstall! %s"):format(name, name)
		end
		return nil,
			("tool %s has no durable authority; run :NvimConfigToolsInstall %s to certify or install it, or use ! to force managed installation"):format(
				name,
				name
			)
	end
	if not resolved then
		if tostring(resolve_err):find("external certification:", 1, true) == 1 then
			return nil, tostring(resolve_err) .. "; " .. external_recovery(name, resolve_err)
		end
		return nil,
			("%s; run :NvimConfigToolsInstall! %s to repair managed authority"):format(tostring(resolve_err), name)
	end
	local path = resolved[command]
	if type(path) ~= "string" or path == "" then
		return nil, ("verified tool resolution omitted %s"):format(command)
	end
	return path
end

local function catalog_names()
	local names = vim.deepcopy(manifest.managed_order)
	vim.list_extend(names, manifest.dynamic_order or {})
	vim.list_extend(names, manifest.mason_order)
	return names
end

local function static_catalog_names()
	local names = vim.deepcopy(manifest.managed_order)
	vim.list_extend(names, manifest.mason_order)
	return names
end

function M.plan_all(options)
	local plans = {}
	for _, name in ipairs(static_catalog_names()) do
		local plan = M.plan(name, options)
		if plan then
			plans[name] = plan
		end
	end
	return vim.deepcopy(plans)
end

function M.import_legacy(name, callback)
	if callback ~= nil and type(callback) ~= "function" then
		return nil, "legacy import callback must be a function"
	end
	if not setup_done then
		M.setup()
	end
	local names
	if name == nil then
		names = static_catalog_names()
	elseif type(name) == "string" and (manifest.managed_tools[name] or manifest.mason_entry(name)) then
		names = { name }
	else
		return nil, "unknown tool"
	end
	local started = false
	for _, candidate in ipairs(names) do
		local spec = M.spec(candidate)
		if spec and engine.status(spec.identity) == nil then
			local record, reason = legacy_state.inspect(candidate, spec.identity.version)
			local imported, import_err
			if record then
				-- Schema-1 never carried archive/install evidence or a normalized
				-- Mason receipt. Core therefore projects even old success as repair.
				imported, import_err =
					engine.import_legacy(spec, { status = record.status, detail = record.detail }, callback)
			elseif reason ~= "absent" and reason ~= "locked" then
				imported, import_err = engine.import_legacy(spec, { status = reason }, callback)
			end
			started = started or imported == true
			if import_err and import_err ~= "consumed" then
				return nil, import_err
			end
		end
	end
	return true, nil, started
end

local function notify_safely(message, level, options)
	return pcall(M._notify, message, level, options)
end

local function close_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local closing = false
	if type(timer.is_closing) == "function" then
		local ok, value = pcall(timer.is_closing, timer)
		closing = ok and value == true
	end
	if not closing then
		pcall(timer.close, timer)
	end
end

local function progress_frame(request)
	if request.finished or install_requests[request.id] ~= request then
		return false
	end
	request.frame = request.frame + 1
	local message = string.format(
		"%s Installing tools · %d/%d settled",
		SPINNER[((request.frame - 1) % #SPINNER) + 1],
		request.settled,
		request.total
	)
	local called, shown = pcall(M._visual_notify, message, vim.log.levels.INFO, {
		id = request.id,
		title = "Tools",
		timeout = false,
		history = false,
	})
	request.displayed = request.displayed or (called and shown == true)
	return request.displayed
end

local function schedule_progress_frame(request)
	if request.finished or install_requests[request.id] ~= request or request.scheduled then
		return
	end
	request.scheduled = true
	local scheduled = pcall(M._schedule, function()
		request.scheduled = false
		if not request.finished and install_requests[request.id] == request then
			progress_frame(request)
		end
	end)
	if not scheduled then
		request.scheduled = false
	end
end

local function begin_install_request(names)
	install_request_sequence = install_request_sequence + 1
	local request = {
		id = "nvim-config:tools-install:" .. install_request_sequence,
		names = vim.deepcopy(names),
		total = #names,
		settled = 0,
		outcomes = {},
		frame = 0,
		displayed = false,
		finished = false,
		scheduled = false,
	}
	install_requests[request.id] = request
	progress_frame(request)
	pcall(vim.cmd, "redraw")
	if not request.displayed then
		return request
	end
	local created, timer = pcall(M._new_timer)
	if not created or not timer then
		return request
	end
	request.timer = timer
	local started, result = pcall(timer.start, timer, PROGRESS_INTERVAL_MS, PROGRESS_INTERVAL_MS, function()
		if not request.finished and install_requests[request.id] == request then
			schedule_progress_frame(request)
		end
	end)
	if not started or result == nil or result == false then
		request.timer = nil
		close_timer(timer)
	end
	return request
end

local function request_summary(request)
	local failed = {}
	for index, name in ipairs(request.names) do
		if request.outcomes[index] == false then
			failed[#failed + 1] = tostring(name)
		end
	end
	table.sort(failed)
	local message = string.format(
		"Tool install request complete: %d succeeded, %d failed (%d total)",
		request.total - #failed,
		#failed,
		request.total
	)
	if #failed > 0 then
		local visible = {}
		for index = 1, math.min(#failed, FAILED_NAMES_LIMIT) do
			visible[#visible + 1] = failed[index]:sub(1, 64)
		end
		message = message .. "\nFailed tools: " .. table.concat(visible, ", ")
		if #failed > #visible then
			message = message .. string.format(" (+%d more)", #failed - #visible)
		end
	end
	return message, #failed
end

local function finish_install_request(request)
	if request.finished or install_requests[request.id] ~= request then
		return false
	end
	request.finished = true
	install_requests[request.id] = nil
	local timer = request.timer
	request.timer = nil
	close_timer(timer)
	local message, failed = request_summary(request)
	local level = failed == 0 and vim.log.levels.INFO or vim.log.levels.WARN
	local timeout = failed == 0 and 3000 or false
	local visual_updated = false
	if request.displayed then
		local called, shown = pcall(M._visual_notify, message, level, {
			id = request.id,
			title = "Tools",
			timeout = timeout,
			history = false,
		})
		visual_updated = called and shown == true
		if not visual_updated then
			pcall(M._visual_hide, request.id)
		end
	end
	local notified = notify_safely(message, level, {
		id = request.id,
		title = "Tools",
		timeout = timeout,
	})
	if not notified and request.displayed and not visual_updated then
		pcall(M._visual_hide, request.id)
	end
	return true
end

local function settle_install_request(request, index, ok)
	if request.finished or request.outcomes[index] ~= nil then
		return false
	end
	request.outcomes[index] = ok == true
	request.settled = request.settled + 1
	if request.settled == request.total then
		return finish_install_request(request)
	end
	if request.displayed then
		schedule_progress_frame(request)
	end
	return true
end

local function reset_install_requests()
	local requests = install_requests
	install_requests = {}
	for _, request in pairs(requests) do
		request.finished = true
		close_timer(request.timer)
		request.timer = nil
		if request.displayed then
			pcall(M._visual_hide, request.id)
		end
	end
end

local REPORT_WORDING = {
	install = { success = "Installed ", failure = "Failed to install " },
	repair = { success = "Repaired ", failure = "Failed to repair " },
	attest = { success = "Attested ", failure = "Failed to attest " },
}

local function report(action, name, ok, reason)
	local wording = assert(REPORT_WORDING[action], "unknown report action")
	local message = (ok and wording.success or wording.failure) .. name
	if reason ~= nil and tostring(reason) ~= "" then
		message = message .. ": " .. tostring(reason)
	end
	notify_safely(message)
end

local function repair_markdown_preview(name, identity)
	if name ~= "markdown-preview" or not markdown_ok then
		return
	end
	local root = M._markdown_plugin_root()
	local record = root and engine.status(identity) or nil
	if record and record.status == "succeeded" then
		local called, ok, err = pcall(markdown_bridge.repair, root, record)
		if not called then
			notify_safely("markdown-preview bridge repair raised an error: " .. bounded(ok), vim.log.levels.WARN)
			return
		end
		if not ok then
			notify_safely("markdown-preview bridge was not repaired: " .. tostring(err), vim.log.levels.WARN)
		elseif err then
			notify_safely("markdown-preview bridge was repaired with a warning: " .. tostring(err), vim.log.levels.WARN)
		end
	end
end

local function preflight(plan)
	if plan.identity.backend == "release" then
		return release.preflight(plan.manifest.release_plan)
	end
	if plan.identity.backend == "npm-release" then
		return npm_release.preflight(plan.manifest.npm_release_plan)
	end
	return check_mason_prerequisites(plan.manifest.entry)
end

local function claim_mode(record)
	if not record then
		return "auto"
	end
	if record.status == "failed" then
		return "retry"
	end
	if record.status == "drift" or record.status == "repair-required" or record.status == "cancelled" then
		return "repair"
	end
	return nil
end

local function import_raw_mason(name, plan, callback)
	local current = engine.status(plan.identity)
	if plan.identity.backend ~= "mason" or current and current.status ~= "repair-required" then
		return true, nil, false
	end
	local validated = validate_raw_mason(plan)
	if not validated then
		return true, nil, false
	end
	local spec, spec_err = M.spec(name, { force_managed = true })
	if not spec then
		return nil, spec_err, false
	end
	local imported, import_err = engine.import_legacy(spec, {
		status = "present",
		origin = "observed-raw-mason-state-v1",
	}, callback)
	if not imported then
		if import_err == "consumed" then
			return true, nil, false
		end
		return nil, import_err, false
	end
	return true, nil, imported == true
end

local function start_planned(name, force_managed, completion, supplied_plan)
	local completed = false
	local function finish(ok)
		if completed then
			return ok
		end
		completed = true
		if type(completion) == "function" then
			pcall(completion, ok == true)
		end
		return ok
	end
	local function finish_after(ok, callback)
		if completed then
			return ok
		end
		local callback_ok, callback_err = xpcall(callback, debug.traceback)
		local result = finish(ok)
		if not callback_ok then
			notify_safely(name .. " completion reporting failed: " .. bounded(callback_err), vim.log.levels.WARN)
		end
		return result
	end
	local plan, plan_err = supplied_plan, nil
	if not plan then
		plan, plan_err = M.plan(name, { force_managed = force_managed })
	end
	if not plan then
		return finish_after(false, function()
			M._notify(name .. " cannot be planned (" .. tostring(plan_err) .. ")", vim.log.levels.WARN)
		end)
	end
	if plan.strategy == "external" then
		local certified, certify_err = engine.certify_external(plan)
		if not certified then
			return finish_after(false, function()
				M._notify(
					name
						.. " external executables were not certified ("
						.. tostring(certify_err)
						.. "); "
						.. external_recovery(name, certify_err),
					vim.log.levels.WARN
				)
			end)
		end
		return finish_after(true, function()
			M._notify(name .. " external executables were certified for runtime use")
		end)
	end
	local function activate_if_dynamic(ok, reason)
		if ok ~= true or plan.identity.backend ~= "npm-release" then
			return ok, reason
		end
		local activation_ok, activated, activation_err = xpcall(function()
			return engine.activate(name, plan.identity)
		end, debug.traceback)
		if not activation_ok then
			return false, "activation raised an error: " .. bounded(activated)
		end
		if not activated then
			return false, activation_err or "activation-failed"
		end
		return true
	end

	local function continue_managed()
		local current = engine.status(plan.identity)
		if current and current.status == "succeeded" then
			local current_spec, current_spec_err = runtime_spec(name)
			local resolved, resolve_err
			if plan.identity.backend == "npm-release" then
				resolved, resolve_err = engine.resolve(plan.identity)
			elseif current_spec then
				resolved, resolve_err = engine.resolve(current_spec)
			else
				resolve_err = current_spec_err
			end
			if resolved then
				local attestation, attestation_err = engine.attest(plan.identity, function(ok, reason)
					ok, reason = activate_if_dynamic(ok, reason)
					finish_after(ok, function()
						if ok then
							repair_markdown_preview(name, plan.identity)
							report("attest", name, true)
						else
							report("attest", name, false, reason)
						end
					end)
				end)
				if not attestation then
					return finish_after(false, function()
						M._notify(
							name .. " attestation was not started (" .. tostring(attestation_err) .. ")",
							vim.log.levels.WARN
						)
					end)
				end
				return true
			end
			notify_safely(
				name .. " managed authority requires repair before attestation (" .. tostring(resolve_err) .. ")",
				vim.log.levels.WARN
			)
		end
		local mode = claim_mode(current)
		if current and current.status == "succeeded" then
			mode = "repair"
		end
		if not mode then
			return finish_after(false, function()
				M._notify(
					name .. " already has active state " .. tostring(current and current.status),
					vim.log.levels.WARN
				)
			end)
		end
		local ready, ready_err = preflight(plan)
		if not ready then
			return finish_after(false, function()
				M._notify(name .. " was not started (" .. tostring(ready_err) .. ")", vim.log.levels.WARN)
			end)
		end
		local claim, claim_err = engine.claim(plan, { mode = mode })
		if not claim then
			return finish_after(false, function()
				M._notify(name .. " was not started (" .. tostring(claim_err) .. ")", vim.log.levels.WARN)
			end)
		end
		local running, run_err = engine.run(claim, function(ok, reason)
			ok, reason = activate_if_dynamic(ok, reason)
			finish_after(ok, function()
				if ok then
					repair_markdown_preview(name, plan.identity)
				end
				report(mode == "repair" and "repair" or "install", name, ok, reason)
			end)
		end)
		if not running then
			return finish_after(false, function()
				M._notify(name .. " was not started (" .. tostring(run_err) .. ")", vim.log.levels.WARN)
			end)
		end
		return true
	end

	local function import_succeeded()
		return finish_after(true, function()
			repair_markdown_preview(name, plan.identity)
			report("attest", name, true)
		end)
	end

	local function import_raw_then_continue()
		local callback_called = false
		local callback_result
		local imported, import_err, import_started = import_raw_mason(name, plan, function(ok)
			callback_called = true
			callback_result = ok and import_succeeded() or continue_managed()
		end)
		if not imported then
			return finish_after(false, function()
				M._notify(
					name .. " existing Mason state could not be imported (" .. tostring(import_err) .. ")",
					vim.log.levels.WARN
				)
			end)
		end
		if import_started then
			return callback_called and callback_result or true
		end
		return continue_managed()
	end

	local callback_called = false
	local callback_result
	if plan.identity.backend == "npm-release" then
		return import_raw_then_continue()
	end
	local imported, import_err, import_started = M.import_legacy(name, function(ok)
		callback_called = true
		callback_result = ok and import_succeeded() or import_raw_then_continue()
	end)
	if not imported then
		return finish_after(false, function()
			M._notify(
				name .. " legacy state could not be imported (" .. tostring(import_err) .. ")",
				vim.log.levels.WARN
			)
		end)
	end
	if import_started or callback_called then
		return callback_called and callback_result or true
	end
	return import_raw_then_continue()
end

local function start(name, force_managed, completion)
	local entry = manifest.dynamic_entry(name)
	if not entry then
		return start_planned(name, force_managed, completion)
	end
	local completed = false
	local function finish(ok)
		if completed then
			return ok
		end
		completed = true
		if type(completion) == "function" then
			pcall(completion, ok == true)
		end
		return ok
	end
	if not M._network_authorized() then
		notify_safely(
			name .. " was not started (network-disabled; latest discovery requires an explicit online install)",
			vim.log.levels.WARN
		)
		return finish(false)
	end
	local function continue_discovery(ok, selected)
		if ok ~= true then
			notify_safely(name .. " latest discovery failed (" .. tostring(selected) .. ")", vim.log.levels.WARN)
			finish(false)
			return
		end
		local plan, plan_err = M.plan(name, { force_managed = true, selected = selected })
		if not plan then
			notify_safely(name .. " cannot be planned (" .. tostring(plan_err) .. ")", vim.log.levels.WARN)
			finish(false)
			return
		end
		local started = start_planned(name, true, finish, plan)
		if not started then
			finish(false)
		end
	end
	local controller, discover_err = npm_release.discover(entry, function(...)
		local arguments = { n = select("#", ...), ... }
		local callback_ok, callback_err = xpcall(function()
			continue_discovery(unpack(arguments, 1, arguments.n))
		end, debug.traceback)
		if not callback_ok then
			notify_safely(
				name .. " latest discovery continuation failed: " .. bounded(callback_err),
				vim.log.levels.WARN
			)
			finish(false)
		end
	end)
	if not controller then
		notify_safely(
			name .. " latest discovery was not started (" .. tostring(discover_err) .. ")",
			vim.log.levels.WARN
		)
		return finish(false)
	end
	return true
end

local function drain_install_queue()
	if install_draining then
		return
	end
	install_draining = true
	while install_active < 2 and #install_queue > 0 do
		local selected
		for index, candidate in ipairs(install_queue) do
			if not install_active_groups[candidate.group] then
				selected = index
				break
			end
		end
		if not selected then
			break
		end
		local item = table.remove(install_queue, selected)
		local generation = install_generation
		install_active = install_active + 1
		install_active_groups[item.group] = true
		local settled = false
		local function settle(ok)
			if settled or generation ~= install_generation then
				return
			end
			settled = true
			install_active = math.max(0, install_active - 1)
			install_active_groups[item.group] = nil
			if type(item.completion) == "function" then
				pcall(item.completion, ok)
			end
			drain_install_queue()
		end
		local started_ok, started = xpcall(function()
			return start(item.name, item.force_managed, settle)
		end, debug.traceback)
		if not started_ok then
			notify_safely(item.name .. " install chain raised an error: " .. bounded(started), vim.log.levels.WARN)
			settle(false)
		elseif started ~= true then
			settle(false)
		end
	end
	install_draining = false
end

local function contained(path, root)
	path = path and vim.fs.normalize(path) or nil
	root = root and vim.fs.normalize(root):gsub("/+$", "") or nil
	return path and root and (path == root or path:sub(1, #root + 1) == root .. "/") or false
end

local function await_operation(starter, identity, timeout)
	local completed = false
	local succeeded = false
	local reason
	local started, start_err = starter(function(ok, value)
		succeeded = ok == true
		if not succeeded then
			reason = tostring(value)
		end
		completed = true
	end)
	if not started then
		return false, tostring(start_err)
	end
	if not completed then
		local waited = vim.wait(timeout or 300000, function()
			return completed
		end, 10)
		if not waited then
			pcall(engine.cancel, identity)
			return false, "timeout"
		end
	end
	return succeeded, reason
end

local function reconcile_tool(name, opts)
	local spec, spec_err = M.spec(name, { force_managed = true })
	if not spec then
		return false, false, tostring(spec_err), spec_err == "unsupported" and "unsupported-platform" or nil
	end
	local plan, plan_err = engine.plan(spec)
	if not plan then
		return false,
			false,
			tostring(plan_err),
			tostring(plan_err):find("unsupported", 1, true) and "unsupported-platform" or nil
	end
	local imported, import_err = M.import_legacy(name)
	if not imported then
		return false, false, tostring(import_err)
	end
	local current = engine.status(plan.identity)
	if current and current.status == "succeeded" then
		local current_spec, current_spec_err = runtime_spec(name)
		local resolved, resolve_err
		if current_spec then
			resolved, resolve_err = engine.resolve(current_spec)
		else
			resolve_err = current_spec_err
		end
		if resolved then
			local attested, attest_err = await_operation(function(done)
				return engine.attest(plan.identity, done)
			end, plan.identity, opts.timeout)
			if attested then
				repair_markdown_preview(name, plan.identity)
				return true, false
			end
			resolve_err = attest_err
			current = engine.status(plan.identity)
		end
		if opts.allow_network ~= true then
			return false, false, resolve_err or "drift"
		end
	end
	if opts.allow_network ~= true then
		return false, false, current and current.status or "missing"
	end
	local mode = claim_mode(current)
	if current and current.status == "succeeded" then
		mode = "repair"
	end
	if not mode then
		return false, false, "active-state:" .. tostring(current and current.status)
	end
	local ready, ready_err = preflight(plan)
	if not ready then
		return false, false, tostring(ready_err)
	end
	local claim, claim_err = engine.claim(plan, { mode = mode })
	if not claim then
		return false, false, tostring(claim_err)
	end
	local installed, install_err = await_operation(function(done)
		return engine.run(claim, done)
	end, plan.identity, opts.timeout)
	if not installed then
		return false, true, install_err
	end
	repair_markdown_preview(name, plan.identity)
	return true, true
end

local function package_extras(required)
	local extras = {}
	local root = vim.fs.joinpath(paths.mason_root(), "packages")
	local stat = uv.fs_lstat(root)
	if stat and stat.type == "directory" then
		for name, kind in vim.fs.dir(root) do
			if kind == "directory" and not required[name] then
				extras[#extras + 1] = name
			end
		end
	end
	table.sort(extras)
	return extras
end

local function report_item(name, ok, problem)
	local spec = M.spec(name, { force_managed = true })
	local identity = spec and spec.identity or nil
	local record = identity and engine.status(identity) or nil
	local command = spec and sorted_keys(spec.executables)[1] or name
	local effective = vim.fn.exepath(command)
	local effective_real = effective ~= "" and uv.fs_realpath(effective) or nil
	local verified_shim = effective ~= "" and paths.is_verified_shim_path(effective) or false
	local direct
	if spec then
		local relative = spec.manifest.integrity.commands[command]
		direct = relative and vim.fs.joinpath(identity.install_root, relative) or nil
	end
	return {
		name = name,
		version = identity and identity.version or (manifest.mason_entry(name) or manifest.managed_tools[name]).version,
		status = record and record.status or "missing",
		direct = direct or vim.NIL,
		effective = effective ~= "" and effective or vim.NIL,
		shadowed = not (
				identity
				and (
					effective_real and contained(effective_real, identity.install_root)
					or verified_shim and record ~= nil
				)
			),
		exact = ok == true and record and record.status == "succeeded" or false,
		problem = ok and vim.NIL or tostring(problem or (record and record.status) or "missing"),
	}
end

---Reconcile the exact release and Mason manifest through verified-tools only.
---No claim, registry refresh, installer, or retry occurs without allow_network.
function M.provision_exact(opts)
	opts = opts or {}
	if not setup_done then
		M.setup()
	end
	local mason_required = {}
	for _, name in ipairs(manifest.mason_order) do
		mason_required[name] = true
	end
	local inventory = {
		mason = { required = {}, exact = true, problems = {}, extras = package_extras(mason_required) },
		managed_tools = {},
	}
	local changed = false
	local overall = true
	local first_reason
	local first_code
	for _, name in ipairs(static_catalog_names()) do
		local ok, item_changed, reason, code = reconcile_tool(name, opts)
		changed = changed or item_changed == true
		overall = overall and ok
		first_reason = first_reason or (not ok and reason or nil)
		first_code = first_code
			or (not ok and (code or (manifest.managed_tools[name] and "managed-tools" or "mason")) or nil)
		local item = report_item(name, ok, reason)
		if manifest.managed_tools[name] then
			item.name = nil
			item.status = nil
			item.problem = nil
			inventory.managed_tools[name] = item
		else
			inventory.mason.required[#inventory.mason.required + 1] = item
			if not item.exact then
				inventory.mason.exact = false
				inventory.mason.problems[#inventory.mason.problems + 1] = name .. ":" .. tostring(item.problem)
			end
		end
	end
	for _, name in ipairs(manifest.dynamic_order or {}) do
		local active, active_err = engine.resolve_active(name)
		local command = manifest.dynamic_entry(name).command
		local direct = active and active.commands[command] or nil
		local effective = vim.fn.exepath(command)
		local effective_real = effective ~= "" and uv.fs_realpath(effective) or nil
		inventory.managed_tools[name] = {
			version = active and active.identity.version or vim.NIL,
			direct = direct or vim.NIL,
			effective = effective ~= "" and effective or vim.NIL,
			shadowed = not (direct and effective_real and effective_real == uv.fs_realpath(direct)),
			exact = active ~= nil,
			problem = active and vim.NIL or tostring(active_err or "missing"),
		}
		if not active then
			overall = false
			first_reason = first_reason or tostring(active_err or "missing")
			first_code = first_code or "managed-tools"
		end
	end
	table.sort(inventory.mason.required, function(left, right)
		return left.name < right.name
	end)
	table.sort(inventory.mason.problems)
	local final_extras = package_extras(mason_required)
	if not vim.deep_equal(inventory.mason.extras, final_extras) then
		inventory.mason.extras = final_extras
		inventory.mason.exact = false
		inventory.mason.problems[#inventory.mason.problems + 1] = "extras-not-preserved"
		overall = false
		first_reason = first_reason or "Mason extras changed during provisioning"
		first_code = first_code or "mason"
	end
	return overall, inventory, changed, first_reason, first_code
end

function M.install(target, force)
	if type(target) ~= "string" or target == "" then
		M._notify("An explicit tool name or 'all' is required", vim.log.levels.ERROR)
		return false
	end
	local names = target == "all" and catalog_names() or { target }
	if
		target ~= "all"
		and not manifest.managed_tools[target]
		and not manifest.dynamic_entry(target)
		and not manifest.mason_entry(target)
	then
		M._notify("Unknown tool '" .. target .. "'", vim.log.levels.ERROR)
		return false
	end
	local request = begin_install_request(names)
	local accepted = true
	for index, name in ipairs(names) do
		install_queue[#install_queue + 1] = {
			name = name,
			force_managed = force == true,
			group = (manifest.managed_tools[name] or manifest.dynamic_entry(name)) and "release" or "mason",
			completion = function(ok)
				if not ok then
					accepted = false
				end
				settle_install_request(request, index, ok)
			end,
		}
	end
	drain_install_queue()
	return accepted
end

local function register_command()
	if not command_done then
		if vim.fn.exists(":NvimConfigToolsInstall") == 2 then
			command_done = true
			return
		end
		vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(options)
			M.install(options.args == "" and "all" or options.args, options.bang)
		end, {
			nargs = "?",
			bang = true,
			complete = catalog_names,
			desc = "Certify external or install/repair exact managed tools",
		})
		command_done = true
	end
end

function M.setup()
	if not setup_done then
		engine.setup({
			state_root = vim.fs.joinpath(paths.primary_state_root(), "verified-tools"),
			backends = { release = release_backend, ["npm-release"] = npm_release_backend, mason = mason_backend },
			probe_external = external_probe,
			network_authorized = M._network_authorized,
			notify = M._notify,
		})
		setup_done = true
	end
	register_command()
	return M
end

function M.mason_ready()
	-- Keep this entrypoint safe when Lazy reaches Mason config without having
	-- run the plugin init hook first. Planning and attestation remain explicit.
	return M.setup()
end

function M.busy()
	local queued, active = engine._queue_size()
	return install_active > 0 or #install_queue > 0 or queued > 0 or active > 0
end

function M.mason_busy()
	return M.busy()
end

function M.mason_condition()
	return function()
		return false
	end
end

function M.engine()
	if not setup_done then
		M.setup()
	end
	return engine
end

function M._reset_for_tests()
	if command_done or vim.fn.exists(":NvimConfigToolsInstall") == 2 then
		pcall(vim.api.nvim_del_user_command, "NvimConfigToolsInstall")
	end
	setup_done = false
	command_done = false
	install_generation = install_generation + 1
	reset_install_requests()
	install_queue = {}
	install_active = 0
	install_draining = false
	install_active_groups = {}
	engine._reset_for_tests()
end

M._external_probe = external_probe
M._mason_observation = mason_observation
M._check_mason_prerequisites = check_mason_prerequisites
M._report = report

return M
