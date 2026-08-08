vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
local original_tools_root = vim.env.NVIM_CONFIG_TOOLS_ROOT
vim.env.NVIM_CONFIG_TOOLS_ROOT = vim.fs.joinpath(fixture, "managed")
package.loaded["config.tool_paths"] = nil
package.loaded["config.release_installer"] = nil
local paths = require("config.tool_paths")
local installer = require("config.release_installer")

local function fake_external(host_tools)
	host_tools = host_tools or {}
	installer._external = function(name)
		if host_tools[name] then
			return "/host/" .. name
		end
		if vim.tbl_contains({ "curl", "sha256sum", "shasum", "tar", "unzip", "gzip", "java" }, name) then
			return "/fake/" .. name
		end
		return nil
	end
end

local function fake_runner(expected_sha, options)
	options = options or {}
	installer._run = function(command, _, callback)
		local name = vim.fs.basename(command[1])
		if name == "curl" then
			local output
			for index, arg in ipairs(command) do
				if arg == "--output" then
					output = command[index + 1]
				end
			end
			assert(output, "curl output path missing")
			assert(vim.fn.writefile({ "archive" }, output, "b") == 0)
			callback({ code = options.download_failure and 22 or 0, stdout = "", stderr = "secret output" })
		elseif name == "sha256sum" or name == "shasum" then
			callback({
				code = 0,
				stdout = (options.bad_checksum and string.rep("0", 64) or expected_sha) .. "  archive\n",
				stderr = "",
			})
		elseif name == "tar" or name == "unzip" then
			local destination
			local marker = name == "tar" and "-C" or "-d"
			for index, arg in ipairs(command) do
				if arg == marker then
					destination = command[index + 1]
				end
			end
			local member = command[#command]
			local target = vim.fs.joinpath(destination, member)
			assert(vim.fn.mkdir(vim.fs.dirname(target), "p") >= 0)
			assert(vim.fn.writefile({ "new-binary" }, target, "b") == 0)
			callback({ code = 0, stdout = "", stderr = "" })
		else
			error("unexpected fake command: " .. vim.inspect(command))
		end
	end
end

test("eligibility is side-effect free and honors external tools and force", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external({ mmdflux = true })
	local plan, reason = installer.plan("mmdflux")
	assert(plan == nil and reason == "external")
	plan = assert(installer.plan("mmdflux", { force = true }))
	assert(plan.target == "darwin-arm64")
	assert(vim.uv.fs_stat(paths.managed_root()) == nil, "eligibility created the managed root")

	installer._platform = function()
		return "Linux", "arm64"
	end
	fake_external()
	plan, reason = installer.plan("mmdflux")
	assert(plan == nil and reason == "unsupported")
	assert(vim.uv.fs_stat(paths.managed_root()) == nil)
end)

test("checksum failure preserves the previous executable", function()
	installer._platform = function()
		return "Darwin", "arm64"
	end
	fake_external()
	local plan = assert(installer.plan("mmdflux"))
	assert(vim.fn.mkdir(paths.managed_bin(), "p") == 1)
	local target = vim.fs.joinpath(paths.managed_bin(), "mmdflux")
	assert(vim.fn.writefile({ "old-binary" }, target, "b") == 0)
	fake_runner(plan.asset.sha256, { bad_checksum = true })
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == false and reason == "checksum-mismatch")
	assert(vim.fn.readfile(target, "b")[1] == "old-binary")
	local staging = vim.fs.joinpath(paths.managed_root(), "staging")
	assert(#vim.fn.glob(staging .. "/*", false, true) == 0, "failed staging was not cleaned")
end)

test("verified native archive atomically promotes the exact member", function()
	installer._platform = function()
		return "Linux", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	assert(plan.asset.kind == "zip", "native PlantUML asset was replaced by the JAR path")
	fake_runner(plan.asset.sha256)
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == true)
	assert(reason == nil, "successful native promotion returned a failure reason")
	local target = vim.fs.joinpath(paths.managed_bin(), "plantuml")
	assert(vim.fn.readfile(target, "b")[1] == "new-binary")
	assert(assert(vim.uv.fs_stat(target)).mode % 512 == 493, "native executable is not 0755")
end)

test("verified JAR is versioned and exposed through an atomic wrapper", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	assert(plan.asset.kind == "jar")
	fake_runner(plan.asset.sha256)
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	assert(success == true)
	assert(reason == nil, "successful JAR promotion returned a failure reason")
	local artifact =
		vim.fs.joinpath(paths.managed_root(), "share", "plantuml", "1.2026.6", plan.asset.sha256, "plantuml.jar")
	assert(vim.fn.filereadable(artifact) == 1, "versioned JAR was not promoted")
	local wrapper_path = vim.fs.joinpath(paths.managed_bin(), "plantuml")
	local wrapper = table.concat(vim.fn.readfile(wrapper_path), "\n")
	assert(wrapper:find("exec java %-jar", 1) and wrapper:find(artifact, 1, true))
	assert(wrapper:find('"%$@"'), "wrapper does not forward argv")
	assert(assert(vim.uv.fs_stat(wrapper_path)).mode % 512 == 493)
end)

test("JAR wrapper promotion failure leaves the previous stable command intact", function()
	installer._platform = function()
		return "Darwin", "x86_64"
	end
	fake_external()
	local plan = assert(installer.plan("plantuml"))
	fake_runner(plan.asset.sha256)
	assert(vim.fn.mkdir(paths.managed_bin(), "p") >= 0)
	local wrapper_path = vim.fs.joinpath(paths.managed_bin(), "plantuml")
	local old_wrapper = "#!/bin/sh\nexec java -jar '/old/artifact.jar' \"$@\"\n"
	assert(vim.fn.writefile(vim.split(old_wrapper, "\n", { plain = true }), wrapper_path, "b") == 0)
	local replace = installer._replace_atomic
	installer._replace_atomic = function(source, target)
		if target == wrapper_path then
			pcall(vim.uv.fs_unlink, source)
			return nil, "injected wrapper failure"
		end
		return replace(source, target)
	end
	local success, reason
	assert(installer.install(plan, function(ok, err)
		success, reason = ok, err
	end))
	installer._replace_atomic = replace
	assert(success == false and reason == "wrapper-promote-failed")
	assert(table.concat(vim.fn.readfile(wrapper_path), "\n") == vim.trim(old_wrapper))
end)

vim.env.NVIM_CONFIG_TOOLS_ROOT = original_tools_root
package.loaded["config.tool_paths"] = nil
package.loaded["config.release_installer"] = nil
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("release_installer_spec: %d tests passed", count))
vim.cmd("quitall!")
