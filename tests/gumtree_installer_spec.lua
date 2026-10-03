vim.o.shadafile = "NONE"
vim.o.swapfile = false
local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(repo .. "/local-plugins/_shared")
vim.opt.runtimepath:prepend(repo .. "/local-plugins/verified-tools.nvim")

local uv = vim.uv
local fs = require("config.fs")
local manifest = require("config.toolchain")
local installer = require("config.gumtree_installer")
local archive = require("config.gumtree_archive")
local bundle = require("config.gumtree_bundle")
local bootstrap = require("config.tool_bootstrap")
local engine = require("verified_tools")
local original_entry = vim.deepcopy(manifest.managed_tools.gumtree)
local original_env = {}
for _, name in ipairs({
	"NVIM_CONFIG_TOOLS_ROOT",
	"NVIM_CONFIG_PRIMARY_STATE_ROOT",
	"NVIM_CONFIG_PRIMARY_DATA_ROOT",
	"NVIM_CONFIG_MASON_ROOT",
	"NVIM_CONFIG_OFFLINE",
}) do
	original_env[name] = vim.env[name] or false
end
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p", 448) == 1)
fixture = assert(uv.fs_realpath(fixture))
local failures, count, serial = {}, 0, 0
local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function padded(value, size)
	assert(#value <= size)
	return value .. string.rep("\0", size - #value)
end

local function tar_entry(name, data, kind, target, mode)
	data, kind = data or "", kind or "0"
	local header = padded(name, 100)
		.. string.format("%07o\0", mode or (kind == "5" and 493 or 420))
		.. string.rep("0000000\0", 2)
		.. string.format("%011o\0", #data)
		.. "00000000000\0"
		.. "        "
		.. kind
		.. padded(target or "", 100)
		.. "ustar\0"
		.. "00"
		.. string.rep("\0", 247)
	assert(#header == 512)
	local sum = 0
	for index = 1, #header do
		sum = sum + header:byte(index)
	end
	header = header:sub(1, 148) .. string.format("%06o\0 ", sum) .. header:sub(157)
	return header .. data .. string.rep("\0", (512 - #data % 512) % 512)
end

local function tar(entries)
	return table.concat(entries) .. string.rep("\0", 1024)
end

local tar_root = original_entry.jre.archive_root
local java_source = table.concat({
	"#!/bin/sh",
	'printf "%s\\n" "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS-unset}" "TMP=${GUMTREE_JAVA_TMPDIR-unset}"',
	'printf "%s\\n" "$@"',
	"",
}, "\n")
local jre_tar = tar({
	tar_entry(tar_root .. "/", "", "5"),
	tar_entry(tar_root .. "/bin/java", java_source, "0", nil, 493),
	tar_entry(tar_root .. "/lib/runtime.dat", "private-runtime\0bytes"),
	tar_entry(tar_root .. "/lib/runtime-copy.dat", "", "2", "runtime.dat"),
})
local compressed = "pinned compressed fixture\0"
local jar_data = { "first jar\0binary", "second jar\0binary" }
local downloads, probes, commands_run = 0, 0, {}

local function runtime()
	bootstrap._reset_for_tests()
	serial = serial + 1
	local root = fixture .. "/runtime-" .. serial
	assert(vim.fn.mkdir(root .. "/state", "p", 448) == 1)
	vim.env.NVIM_CONFIG_TOOLS_ROOT = root .. "/managed"
	vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT = root .. "/state"
	vim.env.NVIM_CONFIG_PRIMARY_DATA_ROOT = root .. "/data"
	vim.env.NVIM_CONFIG_MASON_ROOT = root .. "/mason"
	vim.env.NVIM_CONFIG_OFFLINE = nil
	manifest.managed_tools.gumtree = vim.deepcopy(original_entry)
	local entry = manifest.managed_tools.gumtree
	entry.jars = { vim.deepcopy(entry.jars[1]), vim.deepcopy(entry.jars[2]) }
	for index, jar in ipairs(entry.jars) do
		jar.sha256 = vim.fn.sha256(jar_data[index])
	end
	entry.jre.assets["linux-x86_64"].sha256 = vim.fn.sha256(compressed)
	installer._platform = function()
		return "Linux", "x86_64"
	end
	installer._prerequisite = function(name)
		probes = probes + 1
		return "/usr/bin/" .. name
	end
	installer._network_authorized = function()
		return vim.env.NVIM_CONFIG_OFFLINE ~= "1"
	end
	downloads, probes, commands_run = 0, 0, {}
	installer._run = function(argv, options, callback)
		commands_run[#commands_run + 1] = vim.deepcopy(argv)
		if argv[1] == "/usr/bin/gzip" then
			assert(options.stdin == compressed)
			callback({ code = 0, stdout = jre_tar })
		else
			assert(argv[1] == "/usr/bin/curl")
			downloads = downloads + 1
			local body = compressed
			for index, jar in ipairs(entry.jars) do
				if argv[#argv] == jar.url then
					body = jar_data[index]
				end
			end
			callback({ code = 0, stdout = body })
		end
		return { kill = function() end }
	end
	bootstrap._notify = function() end
	bootstrap._system = function()
		error("unexpected version probe or host execution")
	end
	bundle._interleave = function() end
	return root
end

local function install()
	assert(bootstrap.install("gumtree", true))
	assert(
		vim.wait(5000, function()
			return not bootstrap.busy()
		end, 10),
		"installation did not settle"
	)
	local spec = assert(bootstrap.spec("gumtree"))
	local record = assert(engine.status(spec.identity))
	assert(record.status == "succeeded", vim.inspect(record))
	return assert(bootstrap.resolve("gumtree", "gumtree")), spec, record
end

test("manifest pins the entire Maven runtime closure and four private JRE targets", function()
	assert(original_entry.backend == "maven-release" and original_entry.version == "4.0.0")
	assert(#original_entry.jars == 34)
	local seen = {}
	for _, jar in ipairs(original_entry.jars) do
		assert(not seen[jar.coordinate] and not seen[jar.file])
		seen[jar.coordinate], seen[jar.file] = true, true
		assert(#jar.sha256 == 64 and jar.sha256:match("^[0-9a-f]+$"))
		local group, name, version = jar.coordinate:match("^([^:]+):([^:]+):([^:]+)$")
		assert(jar.file == name .. "-" .. version .. ".jar")
		assert(
			jar.url
				== ("https://repo.maven.apache.org/maven2/%s/%s/%s/%s"):format(
					group:gsub("%.", "/"),
					name,
					version,
					jar.file
				)
		)
		assert(not jar.coordinate:find("gen.", 1, true))
	end
	assert(seen["org.slf4j:slf4j-api:2.0.18"] and not seen["org.slf4j:slf4j-api:1.7.25"])
	assert(seen["org.eclipse.jetty.websocket:websocket-client:9.4.48.v20220622"])
	for _, target in ipairs({ "darwin-arm64", "darwin-x86_64", "linux-arm64", "linux-x86_64" }) do
		assert(#original_entry.jre.assets[target].sha256 == 64)
	end
	assert(original_entry.jre.version == "17.0.20.1+1")
end)

test("planning and unresolved runtime are deterministic, managed-only, and process-free", function()
	runtime()
	local first = assert(installer.plan("gumtree"))
	assert(vim.deep_equal(first, installer.plan("gumtree")))
	local spec = assert(bootstrap.spec("gumtree"))
	assert(spec.force_managed and spec.identity.backend == "maven-release")
	assert(not bootstrap.resolve("gumtree", "gumtree"))
	assert(downloads == 0 and probes == 0 and #commands_run == 0)
	manifest.managed_tools.gumtree.jars[1].sha256 = string.rep("a", 64)
	assert(installer.plan("gumtree").source_sha256 ~= first.source_sha256)
	installer._platform = function()
		return "Plan9", "x86_64"
	end
	assert(not installer.plan("gumtree"))
end)

test("archive internal file links become exact data copies", function()
	local entries = assert(archive.parse(jre_tar, tar_root))
	local copy = entries[#entries]
	assert(copy.kind == "file" and copy.path == "lib/runtime-copy.dat")
	assert(jre_tar:sub(copy.start, copy.start + copy.size - 1) == "private-runtime\0bytes")
end)

test("archive traversal, duplicate entries, special types, dangling and cyclic links fail before writes", function()
	local base = tar_entry(tar_root .. "/", "", "5")
	local invalid = {
		tar_entry(tar_root .. "/../escape", "x"),
		tar_entry("/absolute", "x"),
		tar_entry(tar_root .. "/fifo", "", "6"),
		tar_entry(tar_root .. "/link", "", "2", "../../escape"),
		tar_entry(tar_root .. "/link", "", "1", "/absolute"),
		tar_entry(tar_root .. "/missing", "", "2", "absent"),
		tar_entry(tar_root .. "/one", "", "2", "two") .. tar_entry(tar_root .. "/two", "", "2", "one"),
		tar_entry(tar_root .. "/file", "a") .. tar_entry(tar_root .. "/file", "b"),
		tar_entry(tar_root .. "/file", "a") .. tar_entry(tar_root .. "/file/child", "b"),
	}
	for _, entry in ipairs(invalid) do
		assert(not archive.parse(tar({ base, entry }), tar_root))
	end
	assert(not archive.parse(jre_tar:sub(1, #jre_tar - 600), tar_root))
	assert(not archive.parse("X" .. jre_tar:sub(2), tar_root))
end)

test("offline denial performs no download and consumes no attempt", function()
	runtime()
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	local spec = assert(bootstrap.spec("gumtree"))
	bootstrap.install("gumtree", true)
	assert(vim.wait(2000, function()
		return not bootstrap.busy()
	end, 10))
	assert(engine.status(spec.identity) == nil and downloads == 0)
	local called
	assert(installer.install(spec.manifest.gumtree_plan, function(ok, err)
		called = { ok, err }
	end) == false)
	assert(called[1] == false and called[2] == "network-disabled")
end)

test("explicit installation publishes exact private closure and source-bound proof", function()
	local root = runtime()
	local path, spec, record = install()
	assert(downloads == 3 and #commands_run == 4)
	assert(
		record.proof.kind == "bundle-sha256" and record.proof.source_sha256 == spec.manifest.gumtree_plan.source_sha256
	)
	assert(record.proof.receipt.path == spec.manifest.gumtree_plan.receipt_path)
	assert(uv.fs_stat(record.proof.receipt.path).mode % 512 == 384)
	assert(uv.fs_stat(path).mode % 512 == 448)
	assert(
		fs.read_binary(spec.identity.install_root .. "/payload/jre/lib/runtime-copy.dat") == "private-runtime\0bytes"
	)
	local before = downloads
	installer._run = function()
		error("runtime resolution ran a process")
	end
	installer._prerequisite = function()
		error("runtime resolution inspected prerequisites")
	end
	assert(bootstrap.resolve("gumtree", "gumtree") == path and downloads == before)
	assert(not uv.fs_lstat(root .. "/managed/bin/gumtree"), "private package leaked a shared release launcher")
end)

test("launcher uses private Java, fixed classpath, bounded heap, and quoted private temp root", function()
	runtime()
	local path, spec = install()
	local temporary = fixture .. "/java temp;$(false)"
	local result = vim.system({ path, "textdiff", "argument with spaces" }, {
		text = true,
		clear_env = true,
		env = {
			PATH = "/nonexistent",
			GUMTREE_JAVA_TMPDIR = temporary,
			JAVA_TOOL_OPTIONS = "rogue",
			JDK_JAVA_OPTIONS = "rogue",
			_JAVA_OPTIONS = "rogue",
			CLASSPATH = "/rogue",
		},
	}):wait()
	assert(result.code == 0, result.stderr)
	assert(result.stdout:find("JAVA_TOOL_OPTIONS=unset", 1, true))
	assert(result.stdout:find("-Djava.io.tmpdir=" .. temporary .. "\n", 1, true))
	assert(result.stdout:find("-Xmx256m\n", 1, true) and result.stdout:find("argument with spaces\n", 1, true))
	assert(result.stdout:find(spec.identity.install_root .. "/payload/lib/", 1, true))
	local version = vim.system({ path, "--version" }, { text = true, clear_env = true }):wait()
	assert(version.code == 0 and version.stdout:find("gumtree 4.0.0", 1, true))
end)

test("every JAR, private runtime, and launcher mutation fails closed and explicit repair recovers", function()
	for _, target in ipairs({ "jar", "jre", "launcher" }) do
		local root = runtime()
		local path, spec = install()
		local sentinel = root .. "/managed/unrelated"
		assert(fs.write_binary_atomic(sentinel, "keep me"))
		local changed = target == "jar"
				and spec.identity.install_root .. "/payload/lib/" .. spec.manifest.gumtree_plan.source.jars[1].file
			or target == "jre" and spec.identity.install_root .. "/payload/jre/lib/runtime.dat"
			or path
		local previous_mode = uv.fs_stat(changed).mode % 512
		assert(fs.write_binary_atomic(changed, "tampered"))
		assert(uv.fs_chmod(changed, previous_mode))
		local result, err = bootstrap.resolve("gumtree", "gumtree")
		assert(not result and err, target .. " tamper was accepted")
		local repaired, _, record = install()
		assert(repaired == path and record.attempt == 2, vim.inspect(record))
		assert(fs.read_binary(sentinel) == "keep me")
	end
end)

test("extra runtime files, unsafe links, and changed receipt source cannot acquire authority", function()
	for _, target in ipairs({ "extra", "link", "receipt" }) do
		runtime()
		local _, spec, record = install()
		if target == "extra" then
			assert(fs.write_binary_atomic(spec.identity.install_root .. "/payload/extra", "unexpected"))
		elseif target == "link" then
			local file = spec.identity.install_root .. "/payload/jre/lib/runtime.dat"
			assert(uv.fs_unlink(file))
			assert(uv.fs_symlink("/etc/passwd", file))
		else
			local receipt = vim.json.decode(assert(fs.read_binary(record.proof.receipt.path)))
			receipt.source.jre.sha256 = string.rep("a", 64)
			assert(fs.write_binary_atomic(record.proof.receipt.path, vim.json.encode(receipt)))
		end
		assert(not bootstrap.resolve("gumtree", "gumtree"), target .. " drift was accepted")
	end
end)

test("a mismatched download fails before publication and preserves unrelated files", function()
	local root = runtime()
	local original_run = installer._run
	installer._run = function(argv, options, callback)
		if argv[1] == "/usr/bin/curl" then
			callback({ code = 0, stdout = "altered" })
			return { kill = function() end }
		end
		return original_run(argv, options, callback)
	end
	local plan = assert(installer.plan("gumtree"))
	local result
	installer.install(plan, function(ok, reason)
		result = { ok, reason }
	end)
	assert(result[1] == false and result[2]:find("checksum-mismatch", 1, true))
	assert(not uv.fs_lstat(plan.install_root) and not uv.fs_lstat(plan.receipt_path))
	assert(vim.fn.isdirectory(root .. "/managed/staging/gumtree") == 1)
end)

test("cancellation waits for the active download acknowledgement and never publishes", function()
	runtime()
	local pending, killed, completed
	installer._run = function(_, _, callback)
		pending = callback
		return {
			kill = function()
				killed = (killed or 0) + 1
			end,
		}
	end
	local plan = assert(installer.plan("gumtree"))
	local controller = installer.install(plan, function(ok, err)
		completed = { ok, err }
	end)
	controller.cancel()
	controller.cancel()
	assert(killed == 1 and completed == nil)
	pending({ code = 0, stdout = compressed })
	assert(completed[1] == false and completed[2] == "cancelled")
	assert(not uv.fs_lstat(plan.install_root))
end)

test("publication refuses a swapped destination parent and leaves the outside tree untouched", function()
	local root = runtime()
	local outside = root .. "/outside"
	assert(vim.fn.mkdir(outside, "p", 448) == 1)
	assert(fs.write_binary_atomic(outside .. "/sentinel", "untouched"))
	local swapped = false
	bundle._interleave = function(_, info)
		if not swapped and info.target:match("/payload$") then
			swapped = true
			local parent = vim.fs.dirname(info.target)
			assert(uv.fs_rename(parent, parent .. "-old"))
			assert(uv.fs_symlink(outside, parent))
		end
	end
	local result
	installer.install(assert(installer.plan("gumtree")), function(ok, err)
		result = { ok, err }
	end)
	assert(swapped and result[1] == false and result[2]:find("identity changed", 1, true))
	assert(fs.read_binary(outside .. "/sentinel") == "untouched" and not uv.fs_lstat(outside .. "/payload"))
end)

bootstrap._reset_for_tests()
manifest.managed_tools.gumtree = original_entry
for name, value in pairs(original_env) do
	vim.env[name] = value or nil
end
vim.fn.delete(fixture, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("gumtree_installer_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
