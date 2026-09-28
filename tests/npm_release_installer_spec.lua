vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
local verified_plugin = repo .. "/local-plugins/verified-tools.nvim"
vim.opt.runtimepath:prepend(verified_plugin)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	repo .. "/local-plugins/_shared/lua/?.lua",
	verified_plugin .. "/lua/?.lua",
	verified_plugin .. "/lua/?/init.lua",
	package.path,
}, ";")

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
fixture = assert(vim.uv.fs_realpath(fixture))
local original_xdg_config_home = vim.env.XDG_CONFIG_HOME
vim.env.XDG_CONFIG_HOME = fixture .. "/isolated-xdg-config"
local managed = fixture .. "/managed"
assert(vim.fn.mkdir(managed, "p") == 1)

local fake_paths = {
	managed_root = function()
		return managed
	end,
	external_executable = function(name)
		return ({ curl = "/usr/bin/curl", python3 = "/usr/bin/python3" })[name]
	end,
	is_managed_path = function(path)
		return path:sub(1, #managed + 1) == managed .. "/"
	end,
	is_mason_path = function()
		return false
	end,
}
package.loaded["config.tool_paths"] = fake_paths
package.loaded["config.npm_release_installer"] = nil
local installer = require("config.npm_release_installer")
local toolchain = require("config.toolchain")
local entry = assert(toolchain.dynamic_entry("devcontainers-cli"))
assert(vim.fn.stdpath("config") ~= repo, "fixture did not isolate stdpath(config)")
assert(installer._config_root() == repo, "installer root followed isolated XDG_CONFIG_HOME")
assert(installer._helper() == repo .. "/scripts/verified-npm-bundle.py", "helper did not follow module source")
installer._platform = function()
	return "Darwin", "arm64"
end
installer._helper = function()
	return repo .. "/scripts/verified-npm-bundle.py"
end

local function metadata(version)
	version = version or "1.2.3"
	return {
		name = "@devcontainers/cli",
		version = version,
		bin = { devcontainer = "devcontainer.js" },
		engines = { node = ">=18.0.0 <25" },
		dist = {
			tarball = "https://registry.npmjs.org/@devcontainers/cli/-/cli-" .. version .. ".tgz",
			integrity = "sha512-" .. vim.base64.encode(string.rep("a", 64)),
		},
	}
end

local function selected(version)
	return assert(installer.validate_metadata(entry, metadata(version)))
end

local function write(path, contents, mode)
	assert(vim.fn.mkdir(vim.fs.dirname(path), "p") >= 0)
	local fd = assert(vim.uv.fs_open(path, "w", mode or tonumber("600", 8)))
	assert(vim.uv.fs_write(fd, contents, 0) == #contents)
	assert(vim.uv.fs_close(fd))
	assert(vim.uv.fs_chmod(path, mode or tonumber("600", 8)))
	return path
end

local function output_path(command)
	for index, value in ipairs(command) do
		if value == "--output" then
			return command[index + 1]
		end
	end
end

local function option_value(command, option)
	for index, value in ipairs(command) do
		if value == option then
			return command[index + 1]
		end
	end
end

local function helper_action(command)
	for _, value in ipairs(command) do
		if
			value == "extract-node"
			or value == "extract-package"
			or value == "finalize-package"
			or value == "closure"
			or value == "clean-stage"
		then
			return value
		end
	end
end

local function helper_root(command)
	for index, value in ipairs(command) do
		if value == "--root" then
			return command[index + 1]
		end
	end
end

local function successful_runner(options)
	options = options or {}
	return function(command, _, callback)
		local output = output_path(command)
		if output then
			write(output, "archive\n")
			callback({ code = 0, stdout = "", stderr = "" })
			return { kill = function() end }
		end
		local action = helper_action(command)
		local root = helper_root(command)
		if action == "clean-stage" then
			options.cleanup_count = (options.cleanup_count or 0) + 1
			callback({ code = 0, stdout = "", stderr = "" })
			return { kill = function() end }
		elseif action and action == options.failure_action then
			callback({ code = 1, stdout = "", stderr = options.failure_stderr })
			return { kill = function() end }
		elseif action == "extract-node" then
			write(root .. "/node/bin/node", "node\n", tonumber("700", 8))
		elseif action == "extract-package" then
			if options.package_failure then
				callback({ code = 1, stdout = "", stderr = "injected" })
				return { kill = function() end }
			end
			if not options.omit_cli then
				write(root .. "/package/devcontainer.js", "process.exit(0);\n")
			end
			write(root .. "/package/package.json", vim.json.encode(metadata(options.version)) .. "\n")
		elseif action == "finalize-package" then
			if options.omit_cli then
				callback({ code = 1, stdout = "", stderr = "missing cli" })
				return { kill = function() end }
			end
			local install_root = assert(option_value(command, "--install-root"))
			write(
				root .. "/bin/devcontainer",
				("#!/bin/sh\nexec '%s/node/bin/node' '%s/package/devcontainer.js' \"$@\"\n"):format(
					install_root,
					install_root
				),
				tonumber("700", 8)
			)
		elseif action == "closure" then
			if options.swap_bundle and not options.swapped_bundle then
				local displaced = root .. "-displaced"
				assert(vim.uv.fs_rename(root, displaced))
				assert(vim.uv.fs_mkdir(root, tonumber("700", 8)))
				write(root .. "/rival", "rival\n")
				options.swapped_bundle = displaced
			end
			if options.closure then
				callback({ code = 0, stdout = vim.json.encode(options.closure), stderr = "" })
				return { kill = function() end }
			end
			local closure_sha256 = string.rep("c", 64)
			local wrapper = root .. "/bin/devcontainer"
			local contents = vim.uv.fs_lstat(wrapper) and require("config.fs").read_binary(wrapper) or nil
			if contents == "rival\n" then
				closure_sha256 = string.rep("d", 64)
			end
			callback({
				code = 0,
				stdout = vim.json.encode({ bytes = 1, entries = {}, sha256 = closure_sha256 }),
				stderr = "",
			})
			return { kill = function() end }
		end
		callback({ code = 0, stdout = "", stderr = "" })
		return { kill = function() end }
	end
end

test("metadata is exact stable dependency-free and compatible with private Node", function()
	local accepted = assert(installer.validate_metadata(entry, metadata()))
	assert(accepted.version == "1.2.3" and accepted.integrity:sub(1, 7) == "sha512-")
	local invalid = {
		function(value)
			value.version = "1.2.3-beta.1"
		end,
		function(value)
			value.bin.extra = "extra.js"
		end,
		function(value)
			value.dist.tarball = value.dist.tarball:gsub("https", "http")
		end,
		function(value)
			value.dist.integrity = value.dist.integrity .. " sha512-extra"
		end,
		function(value)
			value.engines.node = ">=25"
		end,
		function(value)
			value.dependencies = { lodash = "1.0.0" }
		end,
		function(value)
			value.optionalDependencies = { optional = "1.0.0" }
		end,
		function(value)
			value.peerDependencies = { peer = "1.0.0" }
		end,
		function(value)
			value.peerDependenciesMeta = { peer = { optional = true } }
		end,
		function(value)
			value.bundledDependencies = { "bundled" }
		end,
	}
	for _, mutate in ipairs(invalid) do
		local value = metadata()
		mutate(value)
		assert(installer.validate_metadata(entry, value) == nil)
	end
	for _, engine_range in ipairs({
		">=24 | >=99",
		"|| >=24",
		">=24 ||",
		">=24 ||| >=99",
		">24",
		"<24.x",
		">24.x",
		"<=24.x",
		"<=24.19",
		"024.x",
	}) do
		local value = metadata()
		value.engines.node = engine_range
		assert(
			installer.validate_metadata(entry, value) == nil,
			"accepted incompatible or unsafe engine range " .. engine_range
		)
	end
	for _, engine_range in ipairs({ ">=18.0.0 <25", ">=24 <25", "24.x", "24.20", "~24.20", "^24.0.0", "<=24", ">24.19" }) do
		local value = metadata()
		value.engines.node = engine_range
		assert(installer.validate_metadata(entry, value), "rejected compatible engine range " .. engine_range)
	end
	local compatible_or = metadata()
	compatible_or.engines.node = ">=99 || >=24 <25"
	assert(installer.validate_metadata(entry, compatible_or), "rejected a valid compatible OR range")
	local package = metadata()
	package.dist = nil
	assert(installer.validate_package(entry, accepted, package))
	package.version = "1.2.4"
	assert(installer.validate_package(entry, accepted, package) == nil)
end)

test("discovery is offline-blocked before any process starts", function()
	local runs = 0
	installer._network_authorized = function()
		return false
	end
	installer._run = function()
		runs = runs + 1
	end
	local started, reason = installer.discover(entry, function()
		error("offline discovery callback ran")
	end)
	assert(started == nil and reason == "network-disabled" and runs == 0)
	installer._network_authorized = function()
		return true
	end
end)

test("discovery accepts only bounded canonical latest metadata", function()
	installer._run = function(command, options, callback)
		assert(command[#command] == entry.metadata_url and options.text == true)
		assert(command[2] == "--disable", "discovery allowed ambient curl configuration")
		assert(vim.list_contains(command, "--max-filesize"))
		assert(option_value(command, "--proto") == "=https")
		assert(option_value(command, "--proto-redir") == "=https")
		callback({ code = 0, stdout = vim.json.encode(metadata()), stderr = "" })
		return { kill = function() end }
	end
	local observed
	assert(installer.discover(entry, function(ok, value)
		assert(ok)
		observed = value
	end))
	assert(observed and observed.version == "1.2.3")
	installer._run = function(_, _, callback)
		callback({ code = 0, stdout = string.rep("x", 256 * 1024 + 1), stderr = "" })
		return { kill = function() end }
	end
	local failure
	assert(installer.discover(entry, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(failure == "npm-metadata-size-invalid")
end)

test("discovery skips unsafe PATH candidates and executes only the first safe canonical curl", function()
	local original_candidates = fake_paths.external_candidates
	local original_validate = installer._validate_prerequisite
	local original_run = installer._run
	local runs = 0
	local unsafe = fixture .. "/unsafe-curl"
	local lexical = fixture .. "/lexical-curl"
	fake_paths.external_candidates = function(name)
		assert(name == "curl")
		return { unsafe }
	end
	installer._validate_prerequisite = function(path)
		assert(path == unsafe)
		return nil, "unsafe\nancestor " .. string.rep("x", 1024)
	end
	installer._run = function()
		runs = runs + 1
	end
	local started, failure = installer.discover(entry, function()
		error("unsafe discovery callback ran")
	end)
	assert(started == nil and failure:find(unsafe, 1, true) and runs == 0)
	assert(not failure:find("\n", 1, true) and #failure <= 600, "unsafe candidate diagnostic was not bounded")

	fake_paths.external_candidates = function(name)
		assert(name == "curl")
		return { unsafe, lexical }
	end
	installer._validate_prerequisite = function(path)
		if path == unsafe then
			return nil, "unsafe ancestor"
		end
		assert(path == lexical)
		return "/usr/bin/curl"
	end
	installer._run = function(command, _, callback)
		runs = runs + 1
		assert(command[1] == "/usr/bin/curl", "discovery executed the lexical candidate")
		assert(command[2] == "--disable", "discovery allowed ambient curl configuration")
		callback({ code = 0, stdout = vim.json.encode(metadata()), stderr = "" })
		return { kill = function() end }
	end
	assert(installer.discover(entry, function(ok)
		assert(ok)
	end))
	assert(runs == 1)
	fake_paths.external_candidates = original_candidates
	installer._validate_prerequisite = original_validate
	installer._run = original_run
end)

test("plan is immutable per version target source and pinned Node", function()
	local plan = assert(installer.plan("devcontainers-cli", selected()))
	local repeated = assert(installer.plan("devcontainers-cli", selected()))
	assert(vim.deep_equal(plan, repeated))
	assert(plan.target == "darwin-arm64")
	assert(plan.node_asset.sha256 == "40e5607e5ecb3db9192723776da2d75d966260fc74a7a9e731c1bd67dda96bc8")
	assert(plan.node_url == "https://nodejs.org/dist/v24.20.0/node-v24.20.0-darwin-arm64.tar.gz")
	assert(plan.install_root:find("/bundles/devcontainers%-cli/1%.2%.3/darwin%-arm64/"))
	assert(plan.receipt_path:sub(-69) == plan.source_sha256 .. ".json")
	local changed = assert(installer.plan("devcontainers-cli", selected("1.2.4")))
	assert(changed.source_sha256 ~= plan.source_sha256 and changed.install_root ~= plan.install_root)
end)

test("node helper failure is bounded cleaned once and never published", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.41")))
	local options = {
		version = "1.2.41",
		failure_action = "extract-node",
		failure_stderr = "verified-npm-bundle: checksum mismatch\n\t" .. string.rep("x", 256) .. "\0ignored",
	}
	installer._run = successful_runner(options)
	local completions = 0
	local failure
	assert(installer.install(plan, function(ok, value)
		completions = completions + 1
		assert(not ok)
		failure = value
	end))
	assert(completions == 1, "node helper failure completed more than once")
	assert(options.cleanup_count == 1, "node helper failure did not run cleanup exactly once")
	assert(failure:sub(1, #"node-extraction-failed: ") == "node-extraction-failed: ")
	assert(failure:find("checksum mismatch", 1, true), failure)
	assert(#failure == 160 and not failure:find("[%c]"), "node helper diagnostic was not cleaned and bounded")
	assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)

	local generic_plan = assert(installer.plan("devcontainers-cli", selected("1.2.42")))
	local generic_options = { version = "1.2.42", failure_action = "extract-node", failure_stderr = "" }
	installer._run = successful_runner(generic_options)
	local generic
	assert(installer.install(generic_plan, function(ok, value)
		assert(not ok)
		generic = value
	end))
	assert(generic == "node-extraction-failed")
	assert(generic_options.cleanup_count == 1)
	assert(vim.uv.fs_lstat(generic_plan.install_root) == nil and vim.uv.fs_lstat(generic_plan.receipt_path) == nil)
end)

test("all helper phases preserve their category and sanitized stderr", function()
	local cases = {
		{ action = "extract-package", category = "package-extraction-failed" },
		{ action = "finalize-package", category = "package-finalization-failed" },
		{ action = "closure", category = "bundle-closure-failed" },
	}
	for index, case in ipairs(cases) do
		local version = "1.3." .. tostring(index)
		local plan = assert(installer.plan("devcontainers-cli", selected(version)))
		local options = {
			version = version,
			failure_action = case.action,
			failure_stderr = "helper\n\tdetail",
		}
		installer._run = successful_runner(options)
		local failure
		assert(installer.install(plan, function(ok, value)
			assert(not ok)
			failure = value
		end))
		assert(failure == case.category .. ": helper detail", failure)
		assert(options.cleanup_count == 1, case.action .. " did not run cleanup")
		assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)
	end
end)

test("managed root publication waits for a durable receiver barrier and retries safely", function()
	local original_managed = managed
	local original_sync = installer._sync_directory
	local original_run = installer._run
	local durable_root = fixture .. "/durable-managed-root"
	local ok, err = xpcall(function()
		managed = durable_root
		local plan = assert(installer.plan("devcontainers-cli", selected("1.2.30")))
		local barriers = {}
		installer._sync_directory = function(fd, path, stat, role, created)
			barriers[#barriers + 1] = { path = path, role = role, created = created }
			if path == fixture and role == "parent" and created then
				return nil, "EIO: injected receiver barrier failure"
			end
			return original_sync(fd, path, stat, role, created)
		end
		local runs = 0
		installer._run = function()
			runs = runs + 1
		end
		local failure
		assert(installer.install(plan, function(installed, value)
			assert(not installed)
			failure = value
		end) == false)
		assert(failure:find("managed-root-parent-sync-failed", 1, true), tostring(failure))
		assert(runs == 0, "started a child before the managed root receiver was durable")
		assert(barriers[1].path == durable_root and barriers[1].role == "child" and barriers[1].created)
		assert(barriers[2].path == fixture and barriers[2].role == "parent" and barriers[2].created)
		assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)

		installer._sync_directory = original_sync
		installer._run = successful_runner({ version = "1.2.30" })
		assert(installer.install(plan, function(installed, value)
			assert(installed, value)
		end))
		assert(vim.uv.fs_lstat(plan.install_root) and vim.uv.fs_lstat(plan.receipt_path))
	end, debug.traceback)
	managed = original_managed
	installer._sync_directory = original_sync
	installer._run = original_run
	assert(ok, err)
end)

test("managed root creation remains bound to its opened parent descriptor", function()
	local original_managed = managed
	local original_interleave = installer._interleave
	local original_run = installer._run
	local parent = fixture .. "/managed-root-parent"
	local displaced = parent .. "-displaced"
	assert(vim.uv.fs_mkdir(parent, tonumber("700", 8)))
	local ok, err = xpcall(function()
		managed = parent .. "/managed"
		local plan = assert(installer.plan("devcontainers-cli", selected("1.2.32")))
		local fired = false
		installer._interleave = function(kind, context)
			if not fired and kind == "before-directory-create" and context.path == managed then
				fired = true
				assert(vim.uv.fs_rename(parent, displaced))
				assert(vim.uv.fs_mkdir(parent, tonumber("700", 8)))
			end
		end
		local runs = 0
		installer._run = function()
			runs = runs + 1
		end
		local failure
		assert(installer.install(plan, function(installed, value)
			assert(not installed)
			failure = value
		end) == false)
		assert(fired and tostring(failure):find("managed-root-parent-changed", 1, true), tostring(failure))
		assert(runs == 0, "started a child after the managed-root parent changed")
		assert(vim.uv.fs_lstat(parent .. "/managed") == nil)
		assert(vim.uv.fs_lstat(displaced .. "/managed") == nil)
	end, debug.traceback)
	managed = original_managed
	installer._interleave = original_interleave
	installer._run = original_run
	assert(ok, err)
end)

test("a cooperative concurrent shared-directory winner is safely adopted", function()
	local original_managed = managed
	local original_interleave = installer._interleave
	local original_run = installer._run
	local concurrent_root = fixture .. "/concurrent-managed-root"
	assert(vim.uv.fs_mkdir(concurrent_root, tonumber("700", 8)))
	local ok, err = xpcall(function()
		managed = concurrent_root
		local plan = assert(installer.plan("devcontainers-cli", selected("1.2.33")))
		local shared = concurrent_root .. "/staging"
		local fired = false
		installer._interleave = function(kind, context)
			if not fired and kind == "before-directory-create" and context.path == shared then
				fired = true
				assert(vim.uv.fs_mkdir(shared, tonumber("700", 8)))
			end
		end
		installer._run = successful_runner({ version = "1.2.33" })
		assert(installer.install(plan, function(installed, value)
			assert(installed, value)
		end))
		assert(fired, "fixture did not win the shared directory creation race")
		assert(vim.uv.fs_lstat(plan.install_root) and vim.uv.fs_lstat(plan.receipt_path))
	end, debug.traceback)
	managed = original_managed
	installer._interleave = original_interleave
	installer._run = original_run
	assert(ok, err)
end)

test("bundle publication stops before rename when a directory receiver barrier fails", function()
	local original_sync = installer._sync_directory
	local original_run = installer._run
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.31")))
	local final_parent = vim.fs.dirname(plan.install_root)
	local receiver = vim.fs.dirname(final_parent)
	local child_barrier_seen = false
	local ok, err = xpcall(function()
		installer._sync_directory = function(fd, path, stat, role, created)
			if path == final_parent and role == "child" and created then
				child_barrier_seen = true
			elseif child_barrier_seen and path == receiver and role == "parent" and created then
				return nil, "EIO: injected receiver barrier failure"
			end
			return original_sync(fd, path, stat, role, created)
		end
		installer._run = successful_runner({ version = "1.2.31" })
		local failure
		assert(installer.install(plan, function(installed, value)
			assert(not installed)
			failure = value
		end))
		assert(child_barrier_seen, "final immutable parent was not created")
		assert(failure:find("private-directory-parent-sync-failed", 1, true), tostring(failure))
		assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)

		installer._sync_directory = original_sync
		installer._run = successful_runner({ version = "1.2.31" })
		assert(installer.install(plan, function(installed, value)
			assert(installed, value)
		end))
		assert(vim.uv.fs_lstat(plan.install_root) and vim.uv.fs_lstat(plan.receipt_path))
	end, debug.traceback)
	installer._sync_directory = original_sync
	installer._run = original_run
	assert(ok, err)
end)

test("install publishes private bundle and receipt without host node or npm", function()
	local plan = assert(installer.plan("devcontainers-cli", selected()))
	local commands = {}
	local runner = successful_runner({ version = "1.2.3" })
	installer._run = function(command, options, callback)
		commands[#commands + 1] = vim.deepcopy(command)
		return runner(command, options, callback)
	end
	local result
	assert(installer.install(plan, function(ok, value)
		assert(ok, value)
		result = value
	end))
	assert(result.kind == "bundle-install-evidence" and result.source_sha256 == plan.source_sha256)
	assert(vim.uv.fs_lstat(plan.install_root).mode % 512 == tonumber("700", 8))
	assert(vim.uv.fs_lstat(plan.install_root .. "/bin/devcontainer").mode % 512 == tonumber("700", 8))
	assert(vim.uv.fs_lstat(plan.install_root .. "/node/bin/node").mode % 512 == tonumber("700", 8))
	assert(vim.uv.fs_lstat(plan.receipt_path).mode % 512 == tonumber("600", 8))
	local wrapper = assert(require("config.fs").read_binary(plan.install_root .. "/bin/devcontainer"))
	assert(wrapper:find(plan.install_root .. "/node/bin/node", 1, true), wrapper)
	assert(wrapper:find(plan.install_root .. "/package/devcontainer.js", 1, true), wrapper)
	assert(not wrapper:find("${0", 1, true), "wrapper depends on its lexical invocation path")
	for _, command in ipairs(commands) do
		assert(command[1] ~= "node" and command[1] ~= "npm" and command[1] ~= "brew")
		if vim.list_contains(command, "--location") then
			assert(command[2] == "--disable", "download allowed ambient curl configuration")
			assert(option_value(command, "--proto") == "=https")
			assert(option_value(command, "--proto-redir") == "=https")
		elseif helper_action(command) then
			assert(command[2] == "-I" and command[3] == "-B" and command[4] == installer._helper())
			if helper_action(command) ~= "clean-stage" then
				assert(option_value(command, "--root-dev") and option_value(command, "--root-ino"))
			end
		end
	end
end)

test("install executes the canonical Python prerequisite instead of its lexical candidate", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.4")))
	local original_candidates = fake_paths.external_candidates
	local original_validate = installer._validate_prerequisite
	fake_paths.external_candidates = function(name)
		return { fixture .. "/unsafe-" .. name, fixture .. "/lexical-" .. name }
	end
	installer._validate_prerequisite = function(path)
		if path:find(fixture .. "/unsafe-", 1, true) == 1 then
			return nil, "unsafe ancestor"
		end
		if path == fixture .. "/lexical-curl" then
			return "/usr/bin/curl"
		end
		assert(path == fixture .. "/lexical-python3")
		return "/usr/bin/python3"
	end
	local runner = successful_runner({ version = "1.2.4" })
	installer._run = function(command, options, callback)
		if helper_action(command) then
			assert(command[1] == "/usr/bin/python3", "helper executed the lexical Python candidate")
		else
			assert(command[1] == "/usr/bin/curl", "download executed the lexical curl candidate")
		end
		return runner(command, options, callback)
	end
	assert(installer.install(plan, function(ok, value)
		assert(ok, value)
	end))
	fake_paths.external_candidates = original_candidates
	installer._validate_prerequisite = original_validate
end)

test("install rejects unsafe and config-owned prerequisite candidates before starting a process", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.40")))
	local original_candidates = fake_paths.external_candidates
	local original_mason_path = fake_paths.is_mason_path
	local original_shim_path = fake_paths.is_verified_shim_path
	local original_validate = installer._validate_prerequisite
	local original_run = installer._run
	local mason = fixture .. "/mason"
	local shim = fixture .. "/verified-shims"
	local checked = {}
	local runs = 0

	fake_paths.is_mason_path = function(path)
		return path == mason or path:sub(1, #mason + 1) == mason .. "/"
	end
	fake_paths.is_verified_shim_path = function(path)
		return path == shim or path:sub(1, #shim + 1) == shim .. "/"
	end
	fake_paths.external_candidates = function(name)
		if name == "curl" then
			return { fixture .. "/lexical-curl" }
		end
		assert(name == "python3")
		return {
			managed .. "/bin/lexical-python3",
			mason .. "/bin/lexical-python3",
			shim .. "/lexical-python3",
			fixture .. "/redirect-managed-python3",
			fixture .. "/redirect-mason-python3",
			fixture .. "/redirect-shim-python3",
			fixture .. "/unsafe-python3",
		}
	end
	installer._validate_prerequisite = function(path)
		checked[#checked + 1] = path
		if path == fixture .. "/lexical-curl" then
			return "/usr/bin/curl"
		elseif path == fixture .. "/redirect-managed-python3" then
			return managed .. "/bin/canonical-python3"
		elseif path == fixture .. "/redirect-mason-python3" then
			return mason .. "/bin/canonical-python3"
		elseif path == fixture .. "/redirect-shim-python3" then
			return shim .. "/canonical-python3"
		end
		assert(path == fixture .. "/unsafe-python3")
		return nil, "unsafe ancestor"
	end
	installer._run = function()
		runs = runs + 1
	end

	local failure
	assert(not installer.install(plan, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(runs == 0, "unsafe prerequisite selection started a process")
	assert(failure:find("missing-or-unsafe-prerequisite:python3:", 1, true), failure)
	assert(
		vim.deep_equal(checked, {
			fixture .. "/lexical-curl",
			fixture .. "/redirect-managed-python3",
			fixture .. "/redirect-mason-python3",
			fixture .. "/redirect-shim-python3",
			fixture .. "/unsafe-python3",
		}),
		"lexical config-owned candidates reached authority validation"
	)

	fake_paths.external_candidates = original_candidates
	fake_paths.is_mason_path = original_mason_path
	fake_paths.is_verified_shim_path = original_shim_path
	installer._validate_prerequisite = original_validate
	installer._run = original_run
end)

test("install rejects metadata whose declared CLI file is absent", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.5")))
	installer._run = successful_runner({ version = "1.2.5", omit_cli = true })
	local failure
	assert(installer.install(plan, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(failure == "package-finalization-failed: missing cli")
	assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)
end)

test("receipt size is rejected before publishing an otherwise adoptable bundle", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("1.2.6")))
	local closure = {
		bytes = 0,
		entries = {
			{ kind = "directory", mode = tonumber("700", 8), path = "" },
		},
		sha256 = string.rep("c", 64),
	}
	local encoded = vim.json.encode(closure)
	closure.entries[1].path = string.rep("a", 256 * 1024 - #encoded - 64)
	assert(#vim.json.encode(closure) < 256 * 1024)
	installer._run = successful_runner({ version = "1.2.6", closure = closure })
	local failure
	assert(installer.install(plan, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(failure == "bundle-receipt-too-large", tostring(failure))
	assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)
end)

test("a failed upgrade preserves the prior immutable bundle bytes", function()
	local prior = assert(installer.plan("devcontainers-cli", selected("2.0.0")))
	installer._run = successful_runner({ version = "2.0.0" })
	assert(installer.install(prior, function(ok)
		assert(ok)
	end))
	local wrapper = prior.install_root .. "/bin/devcontainer"
	local before = assert(require("config.fs").read_binary(wrapper))
	local upgrade = assert(installer.plan("devcontainers-cli", selected("2.0.1")))
	installer._run = successful_runner({ version = "2.0.1", package_failure = true })
	local failure
	assert(installer.install(upgrade, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(failure == "package-extraction-failed: injected")
	assert(require("config.fs").read_binary(wrapper) == before)
	assert(vim.uv.fs_lstat(upgrade.install_root) == nil)
end)

test("a bundle swapped between helper phases cannot be published or redirected", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("2.0.2")))
	local options = { version = "2.0.2", swap_bundle = true }
	installer._run = successful_runner(options)
	local failure
	assert(installer.install(plan, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(tostring(failure):find("no-clobber-source-changed", 1, true), tostring(failure))
	assert(type(options.swapped_bundle) == "string")
	assert(require("config.fs").read_binary(options.swapped_bundle .. "/bin/devcontainer"))
	assert(require("config.fs").read_binary(vim.fs.dirname(options.swapped_bundle) .. "/bundle/rival") == "rival\n")
	assert(vim.uv.fs_lstat(plan.install_root) == nil and vim.uv.fs_lstat(plan.receipt_path) == nil)
end)

test("descriptor-relative publication rejects source and target parent substitution", function()
	local original_interleave = installer._interleave
	local ok, err = xpcall(function()
		for index, side in ipairs({ "source", "target" }) do
			local version = "2.1." .. tostring(index)
			local plan = assert(installer.plan("devcontainers-cli", selected(version)))
			local displaced
			local replacement
			installer._interleave = function(kind, context)
				if kind ~= "before-publish-rename" or context.target ~= plan.install_root or displaced then
					return
				end
				replacement = side == "source" and context.source_parent or context.target_parent
				displaced = replacement .. "-displaced"
				assert(vim.uv.fs_rename(replacement, displaced))
				assert(vim.uv.fs_mkdir(replacement, tonumber("700", 8)))
			end
			installer._run = successful_runner({ version = version })
			local failure
			assert(installer.install(plan, function(installed, value)
				assert(not installed)
				failure = value
			end))
			assert(type(displaced) == "string", side .. " parent race hook did not run")
			assert(tostring(failure):find("no-clobber-publish-parent-changed", 1, true), tostring(failure))
			assert(vim.uv.fs_lstat(plan.install_root) == nil)
			assert(vim.uv.fs_lstat(plan.receipt_path) == nil)
			assert(vim.tbl_isempty(vim.fn.readdir(replacement)), side .. " replacement received published content")
			if side == "target" then
				assert(vim.tbl_isempty(vim.fn.readdir(displaced)), "displaced target parent received the bundle")
			else
				assert(vim.uv.fs_lstat(displaced .. "/bundle/bin/devcontainer"))
			end
		end
	end, debug.traceback)
	installer._interleave = original_interleave
	assert(ok, err)
end)

test("an exact orphaned bundle is recoverable but a mismatch is untouched", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("3.0.0")))
	local runner = successful_runner({ version = "3.0.0" })
	installer._run = runner
	assert(installer.install(plan, function(ok)
		assert(ok)
	end))
	local receipt = assert(require("config.fs").read_binary(plan.receipt_path))
	assert(vim.uv.fs_unlink(plan.receipt_path))
	installer._run = runner
	assert(installer.install(plan, function(ok, value)
		assert(ok, value)
	end))
	assert(require("config.fs").read_binary(plan.receipt_path) == receipt)
	local before = assert(require("config.fs").read_binary(plan.install_root .. "/bin/devcontainer"))
	assert(vim.uv.fs_unlink(plan.receipt_path))
	write(plan.install_root .. "/bin/devcontainer", "rival\n", tonumber("700", 8))
	local failure
	assert(installer.install(plan, function(ok, value)
		assert(not ok)
		failure = value
	end))
	assert(failure == "existing-bundle-mismatch")
	assert(require("config.fs").read_binary(plan.install_root .. "/bin/devcontainer") ~= before)
	assert(vim.uv.fs_lstat(plan.receipt_path) == nil)
end)

test("cancellation signals one child and completes exactly once", function()
	local plan = assert(installer.plan("devcontainers-cli", selected("4.0.0")))
	local pending
	local kills = 0
	installer._run = function(command, _, callback)
		if helper_action(command) == "clean-stage" then
			callback({ code = 0, stdout = "", stderr = "" })
			return { kill = function() end }
		end
		pending = callback
		return {
			kill = function(_, signal)
				assert(signal == 15)
				kills = kills + 1
			end,
		}
	end
	local completions = 0
	local controller = assert(installer.install(plan, function(ok, value)
		completions = completions + 1
		assert(not ok and value == "cancelled")
	end))
	controller.cancel()
	controller.cancel()
	assert(kills == 1 and completions == 0)
	pending({ code = 143, stdout = "", stderr = "terminated" })
	assert(completions == 1)
	pending({ code = 143, stdout = "", stderr = "late" })
	assert(completions == 1)
end)

vim.fn.delete(fixture, "rf")
vim.env.XDG_CONFIG_HOME = original_xdg_config_home
package.loaded["config.npm_release_installer"] = nil
package.loaded["config.tool_paths"] = nil

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(string.format("npm_release_installer_spec: %d tests passed", count))
vim.cmd("quitall!")
