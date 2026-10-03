-- Explicit, pinned Maven/JRE installation. No Java, Maven, Gradle, compiler, or
-- registry discovery is used on the host, during planning, or during resolution.
local M = {}
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local bundle = require("config.gumtree_bundle")
local archive = require("config.gumtree_archive")
local engine = require("verified_tools")
local uv = vim.uv

local MAX_DOWNLOAD = 96 * 1024 * 1024
local MAX_RECEIPT = 256 * 1024

M._platform = function()
	local uname = uv.os_uname()
	return uname.sysname, uname.machine
end
M._run = function(command, options, callback)
	return vim.system(command, options, function(result)
		vim.schedule(function()
			callback(result)
		end)
	end)
end
M._network_authorized = function()
	return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
end
M._prerequisite = function(name)
	local path = paths.external_executable(name)
	if not path then
		return nil, "missing " .. name
	end
	return engine.validate_prerequisite_candidate(path)
end

local function quote(value)
	return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.plan(name)
	local entry = manifest.managed_tools[name]
	if not entry or entry.backend ~= "maven-release" then
		return nil, "unknown"
	end
	local os_name, arch = M._platform()
	local target = manifest.target_key(os_name, arch)
	local jre_asset = target and entry.jre.assets[target] or nil
	if not jre_asset then
		return nil, "unsupported"
	end
	local source = {
		schema = 1,
		backend = "maven-release",
		name = name,
		version = entry.version,
		target = target,
		jars = vim.deepcopy(entry.jars),
		main_class = entry.main_class,
		launcher_version = entry.launcher_version,
		jre = {
			version = entry.jre.version,
			url = manifest.release_url(entry.jre, jre_asset),
			sha256 = jre_asset.sha256,
			java = jre_asset.java,
			archive_root = entry.jre.archive_root,
		},
	}
	local digest = vim.fn.sha256(bundle.canonical(source))
	local managed = vim.fs.normalize(vim.fn.fnamemodify(paths.managed_root(), ":p"))
	-- Colons cannot appear in a Java classpath component on supported Unix hosts.
	if managed:find("[:%z\r\n]") then
		return nil, "managed root cannot be represented in the fixed Java classpath"
	end
	return {
		name = name,
		entry = vim.deepcopy(entry),
		target = target,
		source_sha256 = digest,
		source = source,
		managed_root = managed,
		install_root = vim.fs.joinpath(managed, "bundles", name, entry.version, target, digest),
		receipt_path = vim.fs.joinpath(managed, "bundle-receipts", digest .. ".json"),
		commands = { gumtree = "payload/bin/gumtree" },
		receipt = {
			schema = 1,
			kind = "verified-maven-bundle-receipt",
			name = name,
			version = entry.version,
			target = target,
			source_sha256 = digest,
			source = vim.deepcopy(source),
		},
	}
end

local function validate(plan)
	if type(plan) ~= "table" then
		return nil, "plan-invalid"
	end
	local expected, err = M.plan(plan.name)
	if not expected or not vim.deep_equal(plan, expected) then
		return nil, err or "plan-invalid"
	end
	return expected
end

local function prerequisites()
	local commands = {}
	for _, name in ipairs({ "curl", "gzip" }) do
		local command, err = M._prerequisite(name)
		if not command then
			return nil, "missing-or-unsafe-prerequisite:" .. name .. ":" .. tostring(err)
		end
		commands[name] = command
	end
	return commands
end

function M.preflight(value)
	local plan, err = validate(value)
	if not plan then
		return nil, err
	end
	local commands, commands_err = prerequisites()
	return commands and true or nil, commands_err
end

function M.observe(value)
	local plan, err = validate(value)
	if not plan then
		return nil, err
	end
	return {
		kind = "bundle-sha256",
		source_sha256 = plan.source_sha256,
		bundle_root = plan.install_root,
		receipt_path = plan.receipt_path,
		commands = { gumtree = vim.fs.joinpath(plan.install_root, plan.commands.gumtree) },
	}
end

function M.launcher(plan)
	local payload = plan.install_root .. "/payload"
	local classpath = {}
	for _, jar in ipairs(plan.source.jars) do
		classpath[#classpath + 1] = payload .. "/lib/" .. jar.file
	end
	return table.concat({
		"#!/bin/sh",
		"unset JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS CLASSPATH JAVA_HOME JRE_HOME",
		'if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then',
		"  printf '%s\\n' "
			.. quote("gumtree " .. plan.entry.version .. " (managed; Temurin " .. plan.source.jre.version .. ")"),
		"  exit 0",
		"fi",
		"exec "
			.. quote(payload .. "/jre/" .. plan.source.jre.java)
			.. ' -Xmx256m "-Djava.io.tmpdir=${GUMTREE_JAVA_TMPDIR:-/tmp}" -cp '
			.. quote(table.concat(classpath, ":"))
			.. " "
			.. quote(plan.source.main_class)
			.. ' "$@"',
		"",
	}, "\n")
end

local function materialize_jre(payload, data, source)
	local entries, err = archive.parse(data, source.archive_root)
	if not entries then
		return nil, err
	end
	local java_found = false
	for _, entry in ipairs(entries) do
		if entry.path ~= "" then
			if entry.kind == "file" then
				local ok, write_err = bundle.write_path(
					payload,
					"jre/" .. entry.path,
					data:sub(entry.start, entry.start + entry.size - 1),
					entry.mode
				)
				if not ok then
					return nil, write_err
				end
				if entry.path == source.java then
					java_found = entry.mode == 448
				end
			else
				local directory, directory_err = bundle.ensure(payload.path .. "/jre/" .. entry.path, payload.path)
				if not directory then
					return nil, directory_err
				end
				bundle.close(directory)
			end
		end
	end
	return java_found and true or nil, java_found and nil or "private Java executable is absent"
end

function M.install(value, callback)
	callback = callback or function() end
	local plan, err = validate(value)
	if not plan then
		callback(false, err)
		return false
	end
	if not M._network_authorized() then
		callback(false, "network-disabled")
		return false
	end
	local commands, command_err = prerequisites()
	if not commands then
		callback(false, command_err)
		return false
	end
	local staging, staging_err = bundle.ensure(plan.managed_root .. "/staging/gumtree", plan.managed_root)
	if not staging then
		callback(false, staging_err)
		return false
	end
	local stage_name = ("job-%d-%s"):format(uv.os_getpid(), tostring(uv.hrtime()))
	local stage, stage_err = bundle.child(staging, stage_name, true)
	if not stage then
		bundle.close(staging)
		callback(false, stage_err)
		return false
	end
	local candidate, candidate_err = bundle.child(stage, "candidate", true)
	local payload, payload_err
	if candidate then
		payload, payload_err = bundle.child(candidate, "payload", true)
	end
	if not payload then
		bundle.close(candidate)
		bundle.close(stage)
		bundle.close(staging)
		callback(false, candidate_err or payload_err)
		return false
	end
	local controller = { finished = false, cancelled = false, process = nil }
	function controller.finish(ok, result)
		if controller.finished then
			return
		end
		controller.finished, controller.process = true, nil
		bundle.close(payload)
		bundle.close(candidate)
		local cleaned, clean_err = bundle.clean(stage)
		bundle.close(stage)
		if cleaned and bundle.bound(staging) then
			uv.fs_rmdir(staging.path .. "/" .. stage_name)
		end
		bundle.close(staging)
		if not cleaned and ok and type(result) == "table" then
			result.warnings = { "private staging retained: " .. tostring(clean_err) }
		end
		callback(ok, result)
	end
	function controller.cancel()
		if controller.finished or controller.cancelled then
			return
		end
		controller.cancelled = true
		if controller.process then
			pcall(controller.process.kill, controller.process, 15)
		end
	end
	local function run(command, options, done)
		if controller.cancelled then
			controller.finish(false, "cancelled")
			return
		end
		local completed = false
		local called, process = pcall(M._run, command, options, function(result)
			completed, controller.process = true, nil
			if controller.finished then
				return
			end
			if controller.cancelled then
				controller.finish(false, "cancelled")
				return
			end
			local handled, handle_err = xpcall(function()
				done(result)
			end, debug.traceback)
			if not handled then
				controller.finish(false, "installer-failed:" .. tostring(handle_err))
			end
		end)
		if not called or not process then
			controller.finish(false, "process-start-failed:" .. tostring(process))
		elseif not completed then
			controller.process = process
		end
	end
	local function download(url, expected, done)
		run({
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
			"--max-time",
			"120",
			"--max-filesize",
			tostring(MAX_DOWNLOAD),
			url,
		}, { text = false, timeout = 125000 }, function(result)
			local data = result.stdout
			if result.code ~= 0 or type(data) ~= "string" or #data == 0 or #data > MAX_DOWNLOAD then
				controller.finish(false, "download-failed:" .. url)
				return
			end
			if vim.fn.sha256(data) ~= expected then
				controller.finish(false, "checksum-mismatch:" .. url)
				return
			end
			done(data)
		end)
	end
	local function publish()
		local written, write_err = bundle.write_path(payload, "bin/gumtree", M.launcher(plan), 448)
		if not written then
			controller.finish(false, write_err)
			return
		end
		local closure, closure_err = engine.fingerprint_bundle(candidate.path)
		if not closure then
			controller.finish(false, closure_err)
			return
		end
		local receipt = vim.tbl_extend("force", vim.deepcopy(plan.receipt), {
			bytes = closure.bytes,
			entries = closure.entries,
			closure_sha256 = closure.sha256,
		})
		local contents = bundle.canonical(receipt) .. "\n"
		if #contents > MAX_RECEIPT then
			controller.finish(false, "receipt-too-large")
			return
		end
		local receipt_written, receipt_err = bundle.write(stage, "receipt.json", contents, 384)
		if not receipt_written then
			controller.finish(false, receipt_err)
			return
		end
		local destination, destination_err = bundle.ensure(plan.install_root, plan.managed_root)
		local receipts, receipts_err = bundle.ensure(vim.fs.dirname(plan.receipt_path), plan.managed_root)
		if not destination or not receipts then
			bundle.close(destination)
			bundle.close(receipts)
			controller.finish(false, destination_err or receipts_err)
			return
		end
		bundle.close(payload)
		local published, publish_err = bundle.publish(candidate, "payload", destination, "payload")
		if published then
			local actual, actual_err = engine.fingerprint_bundle(plan.install_root)
			if not actual or not vim.deep_equal(actual, closure) then
				published, publish_err = nil, actual_err or "published closure changed"
			end
		end
		if published then
			published, publish_err = bundle.publish(stage, "receipt.json", receipts, vim.fs.basename(plan.receipt_path))
		end
		bundle.close(destination)
		bundle.close(receipts)
		if not published then
			controller.finish(false, publish_err)
			return
		end
		controller.finish(true, {
			kind = "bundle-install-evidence",
			source_sha256 = plan.source_sha256,
			receipt_sha256 = vim.fn.sha256(contents),
			warnings = {},
		})
	end
	local function jars(index)
		local jar = plan.source.jars[index]
		if not jar then
			publish()
			return
		end
		download(jar.url, jar.sha256, function(data)
			local ok, write_err = bundle.write_path(payload, "lib/" .. jar.file, data, 384)
			if not ok then
				controller.finish(false, write_err)
				return
			end
			jars(index + 1)
		end)
	end
	download(plan.source.jre.url, plan.source.jre.sha256, function(data)
		run({ commands.gzip, "-dc" }, { text = false, stdin = data, timeout = 30000 }, function(result)
			if result.code ~= 0 then
				controller.finish(false, "jre-decompression-failed")
				return
			end
			local ok, extract_err = materialize_jre(payload, result.stdout, plan.source.jre)
			if not ok then
				controller.finish(false, "jre-extraction-failed:" .. tostring(extract_err))
				return
			end
			jars(1)
		end)
	end)
	return controller
end

return M
