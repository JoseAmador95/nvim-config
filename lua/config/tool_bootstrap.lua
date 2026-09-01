-- Host adapter for verified-tools.nvim. Commands, manifests, upstream probes,
-- and backend mechanics stay here; lifecycle/locks/proofs/shims stay in core.
local M = {}

local fs = require("config.fs")
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local release = require("config.release_installer")
local legacy_state = require("config.tool_state")
local engine = require("verified_tools")
local uv = vim.uv

local markdown_ok, markdown_bridge = pcall(require, "verified_tools.markdown_preview")
local lazy_config_ok, lazy_config = pcall(require, "lazy.core.config")
local setup_done = false
local command_done = false
local planning_done = false
local plans = {}

M._notify = function(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Tools" })
end
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
	local saw_any = false
	local incompatible = {}
	for _, command in ipairs(sorted_keys(spec.executables)) do
		local candidates = external_candidates(command)
		candidates_by_command[command] = candidates
		if #candidates == 0 then
			incompatible[#incompatible + 1] = command .. "=missing"
		end
		saw_any = saw_any or #candidates > 0
	end
	if not saw_any then
		return { outcome = "absent" }
	end
	local entry = spec.manifest and spec.manifest.entry or {}
	local probe_command = entry.version_probe or sorted_keys(spec.executables)[1]
	if not spec.executables[probe_command] then
		return { outcome = "error", detail = "manifest version probe is not a declared command" }
	end
	local compatible_path
	for index, path in ipairs(candidates_by_command[probe_command] or {}) do
		local matches, detail = probe_candidate(path, identity.version)
		if matches == nil then
			return { outcome = "error", detail = probe_command .. ":" .. detail }
		end
		-- PATH executes the first candidate. Keep inspecting every later
		-- candidate for probe errors, but never certify one hidden behind an
		-- incompatible executable that would actually win command lookup.
		if index == 1 and matches then
			compatible_path = path
		elseif not matches then
			incompatible[#incompatible + 1] = probe_command .. "@" .. path .. "=" .. detail
		end
	end
	if not compatible_path then
		incompatible[#incompatible + 1] = probe_command .. "=no-exact-version"
	end
	local probe_directory = compatible_path and vim.fs.dirname(compatible_path) or nil
	for command, candidates in pairs(candidates_by_command) do
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
	for command, candidates in pairs(candidates_by_command) do
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
	return ok and type(value) == "table" and value or nil, ok and nil or "json-invalid"
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
	return package_ok and pkg or nil, package_ok and nil or "mason-package-unavailable"
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
	local ready, prereq_err = check_mason_prerequisites(plan.manifest.entry)
	if not ready then
		done(false, prereq_err)
		return false
	end
	local available, registry = pcall(M._registry)
	if not available or type(registry) ~= "table" then
		done(false, "mason-registry-unavailable")
		return false
	end
	local refresh_ok = pcall(registry.refresh, function(success)
		if success ~= true then
			done(false, "mason-refresh-failed")
			return
		end
		local second_ready, second_err = check_mason_prerequisites(plan.manifest.entry)
		if not second_ready then
			done(false, second_err)
			return
		end
		local pkg, package_err = registry_package(plan.identity.name)
		if not pkg then
			done(false, package_err)
			return
		end
		local install_ok, handle = pcall(
			pkg.install,
			pkg,
			{ version = plan.identity.version, force = true },
			function(installed)
				if installed ~= true then
					done(false, "mason-install-failed")
					return
				end
				local observation, observation_err = mason_observation(plan, true)
				done(observation ~= nil, observation and nil or observation_err)
			end
		)
		if not install_ok then
			done(false, "mason-install-start-failed:" .. bounded(handle))
		elseif type(handle) == "table" then
			local cancel = handle.cancel or handle.terminate
			if type(cancel) == "function" then
				control.set_cancel(function()
					pcall(cancel, handle)
				end)
			end
		end
	end)
	if not refresh_ok then
		done(false, "mason-refresh-start-failed")
		return false
	end
	return nil
end

function mason_backend.attest(plan, done)
	local observation, err = mason_observation(plan, false)
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
		force_managed = options and options.force_managed == true or false,
	}
end

local function mason_spec(name, options)
	local entry = manifest.mason_entry(name)
	if not entry then
		return nil, "unknown"
	end
	local target = platform_target()
	local executables = manifest.executable_map(entry)
	local digest_parts = { "mason", name, entry.version, target }
	digest_parts[#digest_parts + 1] = "probe=" .. entry.version_probe
	for _, command in ipairs(sorted_keys(executables)) do
		digest_parts[#digest_parts + 1] = command .. "=" .. executables[command]
	end
	return {
		identity = {
			backend = "mason",
			name = name,
			version = entry.version,
			target = target,
			digest = "manifest:" .. vim.fn.sha256(table.concat(digest_parts, "\0")),
			install_root = paths.mason_root(),
		},
		manifest = { entry = vim.deepcopy(entry), integrity = manifest.mason_integrity(name, entry) },
		executables = executables,
		requires_network = true,
		force_managed = options and options.force_managed == true or false,
	}
end

function M.spec(name, options)
	if manifest.managed_tools[name] then
		return release_spec(name, options)
	end
	return mason_spec(name, options)
end

local function catalog_names()
	local names = vim.deepcopy(manifest.managed_order)
	vim.list_extend(names, manifest.mason_order)
	return names
end

function M.plan_all()
	plans = {}
	for _, name in ipairs(catalog_names()) do
		local spec = M.spec(name)
		if spec then
			local plan = engine.plan(spec)
			if plan then
				plans[name] = plan
			end
		end
	end
	return vim.deepcopy(plans)
end

function M.import_legacy()
	for _, name in ipairs(catalog_names()) do
		local spec = M.spec(name)
		if spec and engine.status(spec.identity) == nil then
			local record, reason = legacy_state.inspect(name, spec.identity.version)
			if record then
				-- Schema-1 never carried archive/install evidence or a normalized
				-- Mason receipt. Core therefore projects even old success as repair.
				engine.import_legacy(spec, { status = record.status, detail = record.detail })
			elseif reason ~= "absent" and reason ~= "locked" then
				engine.import_legacy(spec, { status = reason })
			end
		end
	end
end

local function report(prefix, name, ok, reason)
	M._notify((ok and prefix or "Failed to " .. prefix:lower()) .. name .. (reason and ": " .. reason or ""))
end

local function repair_markdown_preview(name, identity)
	if name ~= "markdown-preview" or not markdown_ok then
		return
	end
	local root = M._markdown_plugin_root()
	local record = root and engine.status(identity) or nil
	if record and record.status == "succeeded" then
		local ok, err = markdown_bridge.repair(root, record)
		if not ok then
			M._notify("markdown-preview bridge was not repaired: " .. tostring(err), vim.log.levels.WARN)
		end
	end
end

local function preflight(plan)
	if plan.identity.backend == "release" then
		return release.preflight(plan.manifest.release_plan)
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

local function start(name, force_managed)
	local spec, spec_err = M.spec(name, { force_managed = force_managed })
	if not spec then
		M._notify(name .. " cannot be planned (" .. tostring(spec_err) .. ")", vim.log.levels.WARN)
		return false
	end
	local plan, plan_err = engine.plan(spec)
	if not plan then
		M._notify(name .. " cannot be planned (" .. tostring(plan_err) .. ")", vim.log.levels.WARN)
		return false
	end
	if plan.strategy == "external" then
		M._notify(name .. " is supplied by compatible external executables")
		return true
	end
	local current = engine.status(plan.identity)
	if current and current.status == "succeeded" then
		return engine.attest(plan.identity, function(ok, reason)
			if ok then
				repair_markdown_preview(name, plan.identity)
			end
			report("Attested ", name, ok, reason)
		end) ~= nil
	end
	local mode = claim_mode(current)
	if not mode then
		M._notify(name .. " already has active state " .. tostring(current and current.status), vim.log.levels.WARN)
		return false
	end
	local ready, ready_err = preflight(plan)
	if not ready then
		M._notify(name .. " was not started (" .. tostring(ready_err) .. ")", vim.log.levels.WARN)
		return false
	end
	local claim, claim_err = engine.claim(plan, { mode = mode })
	if not claim then
		M._notify(name .. " was not started (" .. tostring(claim_err) .. ")", vim.log.levels.WARN)
		return false
	end
	return engine.run(claim, function(ok, reason)
		if ok then
			repair_markdown_preview(name, plan.identity)
		end
		report(mode == "repair" and "Repaired " or "Installed ", name, ok, reason)
	end) ~= nil
end

function M.install(target, force)
	local names = target == "all" and catalog_names() or { target }
	if target ~= "all" and not manifest.managed_tools[target] and not manifest.mason_entry(target) then
		M._notify("Unknown tool '" .. target .. "'", vim.log.levels.ERROR)
		return false
	end
	local ok = true
	for _, name in ipairs(names) do
		ok = start(name, force == true) and ok
	end
	return ok
end

local function attest_existing()
	for _, record in ipairs(engine.records() or {}) do
		if record.status == "succeeded" then
			engine.attest(record.identity, function(ok, reason)
				if ok then
					repair_markdown_preview(record.identity.name, record.identity)
				else
					M._notify(record.identity.name .. " attestation failed: " .. tostring(reason), vim.log.levels.WARN)
				end
			end)
		end
	end
end

local function register_command()
	if not command_done then
		vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(options)
			M.install(options.args == "" and "all" or options.args, options.bang)
		end, {
			nargs = "?",
			bang = true,
			complete = catalog_names,
			desc = "Install or repair exact verified tools",
		})
		command_done = true
	end
end

function M.setup()
	if not setup_done then
		engine.setup({
			state_root = vim.fs.joinpath(paths.primary_state_root(), "verified-tools"),
			backends = { release = release_backend, mason = mason_backend },
			probe_external = external_probe,
			network_authorized = M._network_authorized,
			notify = M._notify,
		})
		setup_done = true
	end
	register_command()
	if planning_done then
		return vim.deepcopy(plans)
	end
	local ok, result = pcall(M.plan_all)
	if not ok then
		M._notify("Initial tool planning failed: " .. bounded(result), vim.log.levels.ERROR)
		return nil, result
	end
	planning_done = true
	return result
end

function M.mason_ready()
	-- Local planning/import/attestation only. No registry refresh or install.
	-- Keep this entrypoint safe even when Lazy (or a manual reload) reaches the
	-- Mason config without having run the plugin init hook first.
	M.setup()
	M.plan_all()
	M.import_legacy()
	attest_existing()
end

function M.mason_busy()
	local _, active = engine._queue_size()
	return active > 0
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
	plans = {}
	setup_done = false
	command_done = false
	planning_done = false
	engine._reset_for_tests()
end

M._external_probe = external_probe
M._mason_observation = mason_observation
M._check_mason_prerequisites = check_mason_prerequisites

return M
