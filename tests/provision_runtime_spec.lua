vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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
assert(vim.fn.mkdir(fixture, "p", tonumber("700", 8)) == 1)
fixture = assert(vim.uv.fs_realpath(fixture))
local report_path = fixture .. "/report.json"
local old_home = vim.env.HOME
local old_root = vim.env.NVIM_CONFIG_ROOT
local old_report = vim.env.NVIM_CONFIG_PROVISION_REPORT
vim.env.HOME = fixture
vim.env.NVIM_CONFIG_ROOT = repo
vim.env.NVIM_CONFIG_PROVISION_REPORT = report_path

package.loaded["config.provision_report"] = nil
package.loaded["config.provision_plugins"] = nil
package.loaded["config.provision_runtime"] = nil
local report_store = require("config.provision_report")
local provision = require("config.provision_runtime")

local function report()
	return vim.json.decode(assert(require("config.fs").read_binary(report_path)))
end

test("contract version and canonical JSON are stable", function()
	assert(provision.contract_version == 1)
	assert(provision._json_encode({ z = 1, a = { true, "x" } }) == '{"a":[true,"x"],"z":1}')
	local result = vim.system({ repo .. "/scripts/provision-runtime", "--contract-version" }, { text = true })
		:wait(5000)
	assert(result.code == 0 and result.stdout == "1\n" and (result.stderr or "") == "")
end)

test("CLI rejects incomplete duplicate unknown and relative arguments", function()
	for _, arguments in ipairs({
		{},
		{ "--non-interactive" },
		{ "--report", report_path },
		{ "--non-interactive", "--report", "relative.json" },
		{ "--non-interactive", "--non-interactive", "--report", report_path },
		{ "--non-interactive", "--report", report_path, "--report", fixture .. "/two.json" },
		{ "--non-interactive", "--report", report_path, "--allow-network", "--allow-network" },
		{ "--non-interactive", "--report", report_path, "--unknown" },
		{ "--contract-version", "--non-interactive" },
	}) do
		local command = { repo .. "/scripts/provision-runtime" }
		vim.list_extend(command, arguments)
		local result = vim.system(command, { text = true, env = { HOME = fixture } }):wait(5000)
		assert(result.code == 2, "invalid CLI did not exit 2: " .. vim.inspect(arguments))
	end
end)

test("CLI rejects outside-HOME paths before creating them", function()
	local outside_xdg = fixture .. "-outside-xdg"
	local outside_report = fixture .. "-outside-report/report.json"
	vim.fn.delete(outside_xdg, "rf")
	vim.fn.delete(vim.fs.dirname(outside_report), "rf")

	local xdg_result = vim.system(
		{ repo .. "/scripts/provision-runtime", "--non-interactive", "--report", report_path },
		{
			text = true,
			env = {
				HOME = fixture,
				XDG_CONFIG_HOME = outside_xdg,
				XDG_DATA_HOME = fixture .. "/.local/share",
				XDG_STATE_HOME = fixture .. "/.local/state",
				XDG_CACHE_HOME = fixture .. "/.cache",
			},
		}
	)
		:wait(5000)
	assert(xdg_result.code == 1)
	assert(vim.uv.fs_lstat(outside_xdg) == nil, "rejected XDG root was created")

	local report_result = vim.system({
		repo .. "/scripts/provision-runtime",
		"--non-interactive",
		"--report",
		outside_report,
	}, { text = true, env = { HOME = fixture } }):wait(5000)
	assert(report_result.code == 2)
	assert(vim.uv.fs_lstat(vim.fs.dirname(outside_report)) == nil, "rejected report parent was created")
end)

test("CLI is offline by default and propagates explicit authorization", function()
	local source = table.concat(vim.fn.readfile(repo .. "/scripts/provision-runtime"), "\n")
	assert(source:find("allow_network=0", 1, true))
	assert(source:find("NVIM_CONFIG_ALLOW_NETWORK=$allow_network", 1, true))
	assert(source:find("export NVIM_CONFIG_OFFLINE=1", 1, true))
	assert(source:find("export NVIM_CONFIG_OFFLINE=0", 1, true))
	assert(select(2, source:gsub('NVIM_CONFIG_ALLOW_NETWORK == "1"', "")) >= 3)
	assert(source:find("/localdata", 1, true))
	assert(source:find('chmod 700 "$root_physical"', 1, true))

	local fake_nvim = fixture .. "/fake-nvim"
	local probe = fixture .. "/network-probe"
	assert(vim.fn.writefile({
		"#!/bin/sh",
		'printf \'%s:%s\\n\' "${NVIM_CONFIG_OFFLINE-unset}" "${NVIM_CONFIG_ALLOW_NETWORK-unset}" >"$PROBE_LOG"',
		"exit 1",
	}, fake_nvim) == 0)
	assert(vim.uv.fs_chmod(fake_nvim, tonumber("755", 8)))
	for _, case in ipairs({
		{ arguments = {}, expected = "1:0" },
		{ arguments = { "--allow-network" }, expected = "0:1" },
	}) do
		local command = { repo .. "/scripts/provision-runtime", "--non-interactive", "--report", report_path }
		vim.list_extend(command, case.arguments)
		local result = vim.system(command, {
			text = true,
			env = {
				HOME = fixture,
				NVIM_BIN = fake_nvim,
				PROBE_LOG = probe,
				XDG_CONFIG_HOME = fixture .. "/.config",
				XDG_DATA_HOME = fixture .. "/.local/share",
				XDG_STATE_HOME = fixture .. "/.local/state",
				XDG_CACHE_HOME = fixture .. "/.cache",
			},
		}):wait(5000)
		assert(result.code == 1)
		assert(vim.fn.readfile(probe)[1] == case.expected)
		for _, root in ipairs({ ".config", ".local/share", ".local/state", ".cache" }) do
			local stat = assert(vim.uv.fs_lstat(vim.fs.joinpath(fixture, root)))
			assert(stat.mode % 512 == tonumber("700", 8), root .. " was not secured")
		end
	end
end)

test("initial report is deterministic complete and mode 0600", function()
	assert(report_store.initialize())
	local first = assert(require("config.fs").read_binary(report_path))
	assert(report_store.initialize())
	local second = assert(require("config.fs").read_binary(report_path))
	assert(first == second)
	local value = report()
	assert(value.schema_version == 1 and value.status == "running" and value.changed == false)
	assert(value.nvim.minimum == "0.12.0" and value.nvim.supported == true)
	assert(#value.lock.sha256 == 64 and value.lock.unchanged == true)
	assert(value.profiles.editor.plugins.problems[1] == "not-run")
	assert(value.profiles.nvimpager.parsers.problems[1] == "not-run")
	assert(value.managed_tools.mmdflux and value.managed_tools.plantuml)
	assert(value.managed_tools["markdown-preview"], "managed manifest entry was omitted")
	assert(vim.uv.fs_lstat(report_path).mode % 512 == tonumber("600", 8))
end)

test("failure report uses bounded sorted codes", function()
	assert(report_store.initialize())
	assert(report_store.fail("mason") == false)
	assert(report_store.fail("lock-changed") == false)
	assert(report_store.fail("mason") == false)
	assert(vim.deep_equal(report().error_codes, { "lock-changed", "mason" }))
	local ok = pcall(report_store.fail, "arbitrary-detail")
	assert(not ok, "unbounded error detail entered the report")
end)

test("report rejects paths outside HOME and hostile targets", function()
	local original = vim.env.NVIM_CONFIG_PROVISION_REPORT
	vim.env.NVIM_CONFIG_PROVISION_REPORT = "/tmp/nvim-provision-report.json"
	assert(not pcall(report_store.initialize), "report escaped HOME")
	vim.env.NVIM_CONFIG_PROVISION_REPORT = fixture .. "/hostile.json"
	assert(vim.uv.fs_symlink(fixture .. "/outside.json", vim.env.NVIM_CONFIG_PROVISION_REPORT))
	assert(not pcall(report_store.initialize), "report followed a symlink target")
	assert(vim.uv.fs_unlink(vim.env.NVIM_CONFIG_PROVISION_REPORT))
	vim.env.NVIM_CONFIG_PROVISION_REPORT = original
end)

test("plugin checkout permits only generated help tags", function()
	local checkout_root = fixture .. "/checkout"
	assert(vim.fn.mkdir(checkout_root, "p") == 1)
	local environment = {
		GIT_AUTHOR_EMAIL = "provision-runtime@example.invalid",
		GIT_AUTHOR_NAME = "Provision Runtime",
		GIT_COMMITTER_EMAIL = "provision-runtime@example.invalid",
		GIT_COMMITTER_NAME = "Provision Runtime",
	}
	local function git(arguments)
		local command = { "git", "-C", checkout_root }
		vim.list_extend(command, arguments)
		local result = vim.system(command, { text = true, env = environment }):wait(5000)
		assert(result.code == 0, result.stderr)
		return vim.trim(result.stdout or "")
	end
	git({ "init", "--quiet" })
	assert(vim.fn.writefile({ "return true" }, checkout_root .. "/plugin.lua") == 0)
	git({ "add", "plugin.lua" })
	git({ "commit", "--quiet", "-m", "fixture" })
	local head = git({ "rev-parse", "HEAD" })
	assert(provision._checkout("fixture", checkout_root, head).exact == true)
	assert(vim.fn.mkdir(checkout_root .. "/doc", "p") == 1)
	assert(vim.fn.writefile({ "fixture\tplugin.lua" }, checkout_root .. "/doc/tags") == 0)
	assert(provision._checkout("fixture", checkout_root, head).exact == true)
	assert(vim.fn.writefile({ "unexpected" }, checkout_root .. "/unexpected.lua") == 0)
	local dirty = provision._checkout("fixture", checkout_root, head)
	assert(dirty.exact == false and dirty.problem == "dirty")
end)

vim.env.HOME = old_home
vim.env.NVIM_CONFIG_ROOT = old_root
vim.env.NVIM_CONFIG_PROVISION_REPORT = old_report
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("provision_runtime_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
