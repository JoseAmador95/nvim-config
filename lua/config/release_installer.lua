-- Installer for the small set of official, pinned release binaries in
-- config.toolchain. All subprocesses use argv arrays; archives are verified
-- before extraction and the stable executable is replaced atomically.
local M = {}

local fs = require("config.fs")
local manifest = require("config.toolchain")
local paths = require("config.tool_paths")
local uv = vim.uv

M._external = function(name)
	return paths.external_executable(name)
end

M._platform = function()
	local uname = uv.os_uname()
	return uname.sysname, uname.machine
end

local function required_commands(asset)
	local required = { "curl" }
	if M._external("sha256sum") then
		required[#required + 1] = "sha256sum"
	else
		required[#required + 1] = "shasum"
	end
	if asset.kind == "zip" then
		required[#required + 1] = "unzip"
	elseif asset.kind == "tar.gz" or asset.kind == "tar.xz" then
		required[#required + 1] = "tar"
	elseif asset.kind == "gzip" then
		required[#required + 1] = "gzip"
	end
	for _, name in ipairs(asset.requires_all or {}) do
		required[#required + 1] = name
	end
	return required
end

-- Eligibility is intentionally read-only. The bootstrap calls this before it
-- creates state or staging directories, so unsupported hosts remain silent.
function M.plan(name, options)
	options = options or {}
	local entry = manifest.managed_tools[name]
	if not entry then
		return nil, "unknown"
	end
	if not options.force and M._external(entry.executable) then
		return nil, "external"
	end
	local os_name, arch = M._platform()
	local asset, target = manifest.asset_for(entry, os_name, arch)
	if not asset then
		return nil, "unsupported"
	end
	local commands = {}
	for _, command in ipairs(required_commands(asset)) do
		local path = M._external(command)
		if not path then
			return nil, "missing-prerequisite"
		end
		commands[command] = path
	end
	return {
		name = name,
		entry = entry,
		asset = asset,
		target = target,
		commands = commands,
		url = manifest.release_url(entry, asset),
	}
end

local function mkdir(path, mode)
	local ok, result = pcall(vim.fn.mkdir, path, "p", mode)
	if not ok or (result ~= 0 and result ~= 1) then
		return nil, "mkdir-failed"
	end
	local changed = uv.fs_chmod(path, mode)
	return changed and true or nil, changed and nil or "chmod-failed"
end

local function cleanup(stage)
	if stage and stage:sub(1, #paths.managed_root() + 1) == paths.managed_root() .. "/" then
		pcall(vim.fn.delete, stage, "rf")
	end
end

-- Tests replace this runner with a deterministic fake. The production runner
-- always schedules completion back onto Neovim's main loop.
M._run = function(command, options, callback)
	local ok, process = pcall(vim.system, command, options, vim.schedule_wrap(callback))
	if not ok then
		vim.schedule(function()
			callback({ code = -1, stderr = tostring(process) })
		end)
		return nil
	end
	return process
end

M._replace_atomic = fs.replace_atomic

local function run(command, options, callback, controller)
	local function completed(result)
		if not controller or not controller.cancelled then
			callback(result)
		end
	end
	local process = M._run(command, options or { text = true }, completed)
	if controller then
		controller.process = process
	end
	return process
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function promote_native(plan, candidate, callback)
	local bin = paths.managed_bin()
	local ok, err = mkdir(bin, 493) -- 0755
	if not ok then
		callback(false, err)
		return
	end
	local changed = uv.fs_chmod(candidate, 493)
	if not changed then
		callback(false, "chmod-failed")
		return
	end
	local promoted, promote_err = M._replace_atomic(candidate, vim.fs.joinpath(bin, plan.entry.executable))
	if promoted then
		callback(true)
	else
		callback(false, "promote-failed:" .. tostring(promote_err))
	end
end

local function promote_jar(plan, archive, callback)
	local share =
		vim.fs.joinpath(paths.managed_root(), "share", plan.name, plan.entry.version, plan.asset.sha256:lower())
	local bin = paths.managed_bin()
	local ok, err = mkdir(share, 493)
	if not ok then
		callback(false, err)
		return
	end
	ok, err = mkdir(bin, 493)
	if not ok then
		callback(false, err)
		return
	end
	local artifact = vim.fs.joinpath(share, "plantuml.jar")
	uv.fs_chmod(archive, 420) -- 0644
	local promoted = M._replace_atomic(archive, artifact)
	if not promoted then
		callback(false, "artifact-promote-failed")
		return
	end

	local wrapper = table.concat({
		"#!/bin/sh",
		"exec java -jar " .. shell_quote(artifact) .. ' "$@"',
		"",
	}, "\n")
	local wrapper_path = vim.fs.joinpath(bin, plan.entry.executable)
	local temp = fs.temp_path(wrapper_path)
	local wrote = fs.write_binary_atomic(temp, wrapper)
	if not wrote or not uv.fs_chmod(temp, 493) then
		pcall(uv.fs_unlink, temp)
		callback(false, "wrapper-write-failed")
		return
	end
	local wrapper_ok = M._replace_atomic(temp, wrapper_path)
	if wrapper_ok then
		callback(true)
	else
		callback(false, "wrapper-promote-failed")
	end
end

local function extract(plan, archive, stage, callback, controller)
	local asset = plan.asset
	if asset.kind == "file" or asset.kind == "jar" then
		callback(true, archive)
		return
	end
	local extract_root = vim.fs.joinpath(stage, "extract")
	local ok = mkdir(extract_root, 448)
	if not ok then
		callback(false, "extract-dir-failed")
		return
	end
	if asset.kind == "gzip" then
		run({ plan.commands.gzip, "-dc", archive }, { text = false }, function(result)
			if result.code ~= 0 or type(result.stdout) ~= "string" then
				callback(false, "extract-failed")
				return
			end
			local candidate = vim.fs.joinpath(extract_root, plan.entry.executable)
			local wrote = fs.write_binary_atomic(candidate, result.stdout)
			callback(wrote == true, wrote and candidate or "extract-write-failed")
		end, controller)
		return
	end

	local command
	if asset.kind == "zip" then
		command = { plan.commands.unzip, "-qq", archive, "-d", extract_root, asset.member }
	else
		command = { plan.commands.tar, "-xf", archive, "-C", extract_root, asset.member }
	end
	run(command, { text = true }, function(result)
		if result.code ~= 0 then
			callback(false, "extract-failed")
			return
		end
		local candidate = vim.fs.joinpath(extract_root, asset.member)
		local stat = uv.fs_stat(candidate)
		callback(stat and stat.type == "file", stat and candidate or "archive-member-missing")
	end, controller)
end

local function verify(plan, archive, callback, controller)
	local command
	if plan.commands.sha256sum then
		command = { plan.commands.sha256sum, archive }
	else
		command = { plan.commands.shasum, "-a", "256", archive }
	end
	run(command, { text = true }, function(result)
		local actual = type(result.stdout) == "string" and result.stdout:match("^([0-9a-fA-F]+)") or nil
		if result.code ~= 0 or not actual or actual:lower() ~= plan.asset.sha256:lower() then
			callback(false, "checksum-mismatch")
			return
		end
		callback(true)
	end, controller)
end

-- Install a previously checked plan. The callback receives only stable reason
-- categories; raw process output is never returned to persistent state.
function M.install(plan, callback)
	assert(type(plan) == "table" and plan.entry and plan.asset, "release install requires an eligible plan")
	callback = callback or function() end
	local managed = paths.managed_root()
	local staging_root = vim.fs.joinpath(managed, "staging")
	local ok, err = mkdir(staging_root, 448)
	if not ok then
		callback(false, err)
		return false
	end
	local stage = vim.fs.joinpath(
		staging_root,
		("%s-%s-%d-%s"):format(plan.name, plan.entry.version, uv.os_getpid(), tostring(uv.hrtime()))
	)
	ok, err = mkdir(stage, 448)
	if not ok then
		callback(false, err)
		return false
	end
	local archive = vim.fs.joinpath(stage, plan.asset.archive)
	local controller = { cancelled = false }
	function controller.cancel()
		if controller.cancelled then
			return
		end
		controller.cancelled = true
		if controller.process and type(controller.process.kill) == "function" then
			pcall(controller.process.kill, controller.process, 15)
		end
		cleanup(stage)
	end
	local function finish(success, reason)
		cleanup(stage)
		callback(success, reason)
	end

	run({
		plan.commands.curl,
		"--fail",
		"--location",
		"--silent",
		"--show-error",
		"--retry",
		"3",
		"--retry-all-errors",
		"--output",
		archive,
		plan.url,
	}, { text = true }, function(result)
		if result.code ~= 0 then
			finish(false, "download-failed")
			return
		end
		verify(plan, archive, function(verified, verify_err)
			if not verified then
				finish(false, verify_err)
				return
			end
			extract(plan, archive, stage, function(extracted, candidate)
				if not extracted then
					finish(false, candidate)
					return
				end
				local promote = plan.asset.kind == "jar" and promote_jar or promote_native
				promote(plan, candidate, finish)
			end, controller)
		end, controller)
	end, controller)
	return controller
end

return M
