vim.o.shadafile = "NONE"
vim.o.swapfile = false

local checkout = vim.fn.getcwd()
vim.opt.runtimepath:prepend(checkout)
package.path = table.concat({ checkout .. "/lua/?.lua", checkout .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local project_settings = require("config.project_settings")
local lsp_neoconf = require("config.lsp_neoconf")
local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p", tonumber("700", 8)) == 1)
	return vim.uv.fs_realpath(path) or path
end

local function write(path, data)
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	local offset = 0
	while offset < #data do
		offset = offset + assert(vim.uv.fs_write(fd, data:sub(offset + 1), offset))
	end
	assert(vim.uv.fs_close(fd))
end

local function harness(root, globals)
	local current_source
	local approvals = {}
	local notifications = {}
	local counts = { approve = 0, approval = 0, register = 0, root = 0 }
	local authority = {}
	function authority.register_source(source)
		counts.register = counts.register + 1
		current_source = vim.deepcopy(source)
		current_source.repo = current_source.workspace.repo_identity
		return true
	end
	function authority.has_approval(spec)
		counts.approval = counts.approval + 1
		assert(current_source.id == spec.source and vim.deep_equal(current_source.workspace, spec.workspace))
		assert(current_source.fingerprint == spec.fingerprint and current_source.enabled)
		return approvals[spec.workspace.repo_identity] == spec.fingerprint
	end
	function authority.approve(spec)
		counts.approve = counts.approve + 1
		assert(current_source.id == spec.source and vim.deep_equal(current_source.workspace, spec.workspace))
		assert(current_source.fingerprint == spec.fingerprint and current_source.enabled)
		approvals[spec.workspace.repo_identity] = spec.fingerprint
		return true
	end
	local repo = {
		root = function(start)
			counts.root = counts.root + 1
			if start == "outside" then
				return nil, "not inside a Git repository: fixture"
			end
			return root
		end,
	}
	local neoconf = {
		get = function(key, default, options)
			assert(options["local"] == false and options.global == true, "Neoconf local authority was enabled")
			local value = globals[key]
			return vim.deepcopy(value == nil and default or value)
		end,
	}
	project_settings.setup({
		active = true,
		command = false,
		authority = authority,
		repo = repo,
		neoconf = neoconf,
		notify = function(message)
			notifications[#notifications + 1] = tostring(message)
		end,
	})
	return {
		authority = authority,
		approvals = approvals,
		counts = counts,
		notifications = notifications,
		source = function()
			return vim.deepcopy(current_source)
		end,
	}
end

test("approval gates JSONC and any lexical change revokes current use", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(
		vim.fs.joinpath(root, ".vscode/settings.json"),
		[[{
  // comments and trailing commas are accepted
  "ty.configuration.rules.unresolved-reference": "warn",
  "ty.disableLanguageServices": false,
  "ty.configurationFile": "https://example.invalid/a//b",
}]]
	)
	write(vim.fs.joinpath(root, ".neoconf.json"), [[{ "lspconfig": { "ty": false, }, /* retained UI format */ }]])
	local state = harness(root, {
		vscode = { ty = { configuration = { rules = { ["possibly-unresolved-reference"] = "ignore" } } } },
		["lspconfig.ty"] = { ty = { configuration = { rules = { ["unresolved-import"] = "error" } } } },
	})

	local before, before_err = project_settings.get("vscode", {}, root)
	equal(
		"ignore",
		before.ty.configuration.rules["possibly-unresolved-reference"],
		"global Neoconf value was lost before approval"
	)
	assert(before.ty.configuration.rules["unresolved-reference"] == nil, "unapproved VSCode setting escaped")
	assert(before_err == "project settings are not approved")
	local snapshot = assert(project_settings.snapshot(root))
	assert(snapshot.present and not snapshot.approved)
	assert(vim.tbl_isempty(snapshot.values.vscode), "snapshot exposed unapproved data")
	local first_fingerprint = snapshot.fingerprint

	assert(project_settings.approve(root))
	local approved = assert(project_settings.get("vscode", {}, root))
	equal("ignore", approved.ty.configuration.rules["possibly-unresolved-reference"], "global setting did not merge")
	equal("warn", approved.ty.configuration.rules["unresolved-reference"], "approved dotted VSCode key did not expand")
	equal(false, approved.ty.disableLanguageServices, "approved false value was lost")
	equal("https://example.invalid/a//b", approved.ty.configurationFile, "comment lexer changed a string")
	equal(false, project_settings.get("lspconfig.ty", {}, root), "approved server disable did not override global")

	write(
		vim.fs.joinpath(root, ".vscode/settings.json"),
		'{ "ty.configuration.rules.unresolved-reference": "error" }\n'
	)
	local changed, changed_err = project_settings.get("vscode", {}, root)
	equal(
		"ignore",
		changed.ty.configuration.rules["possibly-unresolved-reference"],
		"global fallback was lost after mutation"
	)
	assert(changed.ty.configuration.rules["unresolved-reference"] == nil, "changed unapproved content remained active")
	assert(changed_err == "project settings are not approved")
	local changed_snapshot = assert(project_settings.snapshot(root))
	assert(changed_snapshot.fingerprint ~= first_fingerprint and not changed_snapshot.approved)
	assert(state.approvals[root] == first_fingerprint, "adapter rewrote approval automatically")

	vim.fn.delete(root, "rf")
end)

test("batch lookup reads each file once and returns isolated values", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	local neoconf_path = vim.fs.joinpath(root, ".neoconf.json")
	local vscode_path = vim.fs.joinpath(root, ".vscode/settings.json")
	write(neoconf_path, [[{ "lspconfig.ty": { "ty.configurationFile": "project.toml" } }]])
	write(vscode_path, [[{ "ty.disableLanguageServices": false }]])
	local state = harness(root, {
		vscode = { global = { enabled = true } },
		["lspconfig.ty"] = { globalServer = true },
	})
	assert(project_settings.approve(root))
	for name in pairs(state.counts) do
		state.counts[name] = 0
	end

	local original_open = vim.uv.fs_open
	local reads = { [neoconf_path] = 0, [vscode_path] = 0 }
	vim.uv.fs_open = function(path, ...)
		if reads[path] ~= nil then
			reads[path] = reads[path] + 1
		end
		return original_open(path, ...)
	end
	local ok, values, lookup_err = xpcall(function()
		return project_settings.get_many({ vscode = {}, ["lspconfig.ty"] = {} }, root)
	end, debug.traceback)
	vim.uv.fs_open = original_open
	assert(ok, values)
	assert(lookup_err == nil, lookup_err)
	equal(1, reads[neoconf_path], "batch lookup reread .neoconf.json")
	equal(1, reads[vscode_path], "batch lookup reread .vscode/settings.json")
	equal(1, state.counts.root, "batch lookup resolved the repository root more than once")
	equal(1, state.counts.register, "batch lookup registered more than one candidate")
	equal(1, state.counts.approval, "batch lookup performed more than one durable approval lookup")
	equal(0, state.counts.approve, "batch lookup mutated project approval")
	equal(false, values.vscode.ty.disableLanguageServices, "batch lookup lost VSCode project settings")
	equal(true, values.vscode.global.enabled, "batch lookup lost global VSCode settings")
	equal("project.toml", values["lspconfig.ty"].ty.configurationFile, "batch lookup lost server settings")
	equal(true, values["lspconfig.ty"].globalServer, "batch lookup lost global server settings")

	values.vscode.ty.disableLanguageServices = true
	values["lspconfig.ty"].ty.configurationFile = "mutated.toml"
	local fresh = assert(project_settings.get_many({ vscode = {}, ["lspconfig.ty"] = {} }, root))
	equal(false, fresh.vscode.ty.disableLanguageServices, "batch result shared nested VSCode state")
	equal("project.toml", fresh["lspconfig.ty"].ty.configurationFile, "batch result shared server state")
	local snapshot = assert(project_settings.snapshot(root))
	snapshot.values.vscode.ty.disableLanguageServices = true
	equal(
		false,
		project_settings.snapshot(root).values.vscode.ty.disableLanguageServices,
		"snapshot returned mutable adapter state"
	)

	vim.fn.delete(root, "rf")
end)

test("single lookup preserves an explicit nil default", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "ty.disableLanguageServices": false }')
	harness(root, {})
	assert(project_settings.approve(root))
	local value, err = project_settings.get("vscode", nil, root)
	assert(err == nil, err)
	equal(false, value.ty.disableLanguageServices, "nil default discarded the approved single setting")
	vim.fn.delete(root, "rf")
end)

test("approved Neoconf settings preserve dotted-key expansion", function()
	local root = temp_dir()
	write(
		vim.fs.joinpath(root, ".neoconf.json"),
		[[{
  "lspconfig.ty": {
    "ty.configuration.rules.unresolved-reference": "warn",
    "ty.disableLanguageServices": false
  },
  "lspconfig.ruff.settings.lint.preview": true
}]]
	)
	harness(root, {})
	assert(project_settings.approve(root))
	local ty = assert(project_settings.get("lspconfig.ty", {}, root))
	equal("warn", ty.ty.configuration.rules["unresolved-reference"], "server-local dotted key did not expand")
	equal(false, ty.ty.disableLanguageServices, "server-local false value was lost")
	local ruff = assert(project_settings.get("lspconfig.ruff", {}, root))
	equal(true, ruff.settings.lint.preview, "top-level Neoconf dotted key did not expand")
	vim.fn.delete(root, "rf")
end)

test("global Neoconf lspconfig settings preserve dotted-key expansion", function()
	local root = temp_dir()
	harness(root, {
		["lspconfig.ty"] = {
			["ty.configuration.rules.unresolved-reference"] = "warn",
			["ty.disableLanguageServices"] = false,
		},
	})
	local ty = assert(project_settings.get("lspconfig.ty", {}, root))
	equal("warn", ty.ty.configuration.rules["unresolved-reference"], "global server dotted key did not expand")
	equal(false, ty.ty.disableLanguageServices, "global server false value was lost")
	vim.fn.delete(root, "rf")
end)

test("combined fingerprint covers appearance and disappearance of either file", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "editor.formatOnSave": true }')
	harness(root, {})
	local approved = assert(project_settings.approve(root))
	assert(project_settings.snapshot(root).approved)
	write(vim.fs.joinpath(root, ".neoconf.json"), '{ "lspconfig": {} }')
	local appeared = assert(project_settings.snapshot(root))
	assert(not appeared.approved and appeared.fingerprint ~= approved.fingerprint)
	assert(vim.uv.fs_unlink(vim.fs.joinpath(root, ".neoconf.json")))
	assert(project_settings.snapshot(root).approved, "returning to exact approved bytes did not restore approval")
	assert(vim.uv.fs_unlink(vim.fs.joinpath(root, ".vscode/settings.json")))
	local absent = assert(project_settings.snapshot(root))
	assert(not absent.present and not absent.approved)
	assert(project_settings.approve(root) == nil, "absence was approvable")
	vim.fn.delete(root, "rf")
end)

test("a file change between approval lookup and consumption fails closed", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	local path = vim.fs.joinpath(root, ".vscode/settings.json")
	write(path, '{ "python.analysis.typeCheckingMode": "strict" }')
	local state = harness(root, { vscode = { safe = true } })
	assert(project_settings.approve(root))
	local original_has_approval = state.authority.has_approval
	local changed = false
	state.authority.has_approval = function(...)
		local approved = original_has_approval(...)
		if not changed then
			changed = true
			write(path, '{ "python.analysis.typeCheckingMode": "basic" }')
		end
		return approved
	end
	local value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "TOCTOU mutation reached the consumer")
	assert(err == "project settings changed during fingerprint validation")
	assert(not project_settings.snapshot(root).approved, "changed candidate remained approved")
	vim.fn.delete(root, "rf")
end)

test("a same-size ctime change fails metadata-only revalidation", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	local path = vim.fs.joinpath(root, ".vscode/settings.json")
	local original = '{ "python.analysis.typeCheckingMode": "strict" }'
	local replacement = '{ "python.analysis.typeCheckingMode": "normal" }'
	equal(#original, #replacement, "ctime fixture did not preserve file size")
	write(path, original)
	local state = harness(root, { vscode = { safe = true } })
	assert(project_settings.approve(root))

	local original_has_approval = state.authority.has_approval
	local original_lstat = vim.uv.fs_lstat
	local spoof_metadata = false
	local before
	state.authority.has_approval = function(...)
		local approved = original_has_approval(...)
		before = assert(original_lstat(path))
		vim.uv.sleep(2)
		write(path, replacement)
		local after = assert(original_lstat(path))
		equal(before.dev, after.dev, "same-size mutation moved devices")
		equal(before.ino, after.ino, "same-size mutation replaced the inode")
		equal(before.size, after.size, "same-size mutation changed size")
		equal(before.mode, after.mode, "same-size mutation changed mode")
		assert(
			before.ctime.sec ~= after.ctime.sec or before.ctime.nsec ~= after.ctime.nsec,
			"same-size mutation did not advance ctime"
		)
		spoof_metadata = true
		return approved
	end
	vim.uv.fs_lstat = function(candidate, ...)
		local info, err = original_lstat(candidate, ...)
		if spoof_metadata and candidate == path and info then
			info = vim.deepcopy(info)
			-- Hide the mtime change so this assertion specifically exercises ctime.
			info.mtime = vim.deepcopy(before.mtime)
		end
		return info, err
	end
	local ok, values, err = xpcall(function()
		return project_settings.get_many({ vscode = {} }, root)
	end, debug.traceback)
	vim.uv.fs_lstat = original_lstat
	state.authority.has_approval = original_has_approval
	assert(ok, values)
	equal({ safe = true }, values.vscode, "ctime mutation reached the consumer")
	equal("project settings changed during fingerprint validation", err, "ctime mutation did not fail closed")

	vim.fn.delete(root, "rf")
end)

test("durable approval is reread after metadata validation", function()
	local parent = temp_dir()
	local root = vim.fs.joinpath(parent, "project")
	local state_root = vim.fs.joinpath(parent, "trust-state")
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "ty.disableLanguageServices": false }')

	local module_path =
		vim.fs.joinpath(checkout, "local-plugins", "trusted-workspace.nvim", "lua", "trusted_workspace", "init.lua")
	local authority_a = assert(loadfile(module_path))()
	local authority_b = assert(loadfile(module_path))()
	assert(authority_a.setup({ state_root = state_root, mode = "full" }))
	project_settings.setup({
		active = true,
		command = false,
		authority = authority_a,
		repo = {
			root = function()
				return root
			end,
		},
		neoconf = {
			get = function(_, default)
				return vim.deepcopy(default)
			end,
		},
		notify = function() end,
	})

	local approval = assert(project_settings.approve(root))
	local approved = assert(project_settings.get_many({ vscode = { safe = true } }, root))
	equal(false, approved.vscode.ty.disableLanguageServices, "durably approved settings were not consumed")
	assert(authority_b.setup({ state_root = state_root, mode = "full" }))
	assert(authority_b.revoke_approval(root, project_settings.SOURCE_ID))
	equal(
		approval.fingerprint,
		authority_a.approvals(root)[project_settings.SOURCE_ID],
		"second instance unexpectedly refreshed the first instance cache"
	)
	local revoked, revoked_err = project_settings.get_many({ vscode = { safe = true } }, root)
	equal({ safe = true }, revoked.vscode, "durably revoked settings reached the consumer")
	equal("project settings are not approved", revoked_err, "durable revocation was not reported")

	assert(project_settings.approve(root))
	local state_path = vim.fs.joinpath(state_root, "trusted-workspace.json")
	write(state_path, "{")
	local corrupt, corrupt_err = project_settings.get_many({ vscode = { safe = true } }, root)
	equal({ safe = true }, corrupt.vscode, "corrupt durable approval state reached the consumer")
	assert(tostring(corrupt_err):find("corrupt", 1, true), tostring(corrupt_err))
	equal("{", table.concat(vim.fn.readfile(state_path), "\n"), "approval observation repaired corrupt state")

	vim.fn.delete(parent, "rf")
end)

test("invalid oversized and hostile files fail closed without consuming approval", function()
	local root = temp_dir()
	local vscode_dir = vim.fs.joinpath(root, ".vscode")
	assert(vim.fn.mkdir(vscode_dir, "p", tonumber("700", 8)) == 1)
	local settings = vim.fs.joinpath(vscode_dir, "settings.json")
	local globals = { vscode = { safe = true } }
	harness(root, globals)

	write(settings, "{ broken")
	local value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "invalid JSONC changed global fallback")
	assert(err:find("invalid JSONC", 1, true))
	assert(project_settings.approve(root) == nil, "invalid JSONC was approved")

	local prefix = '{ "value": true }'
	write(settings, prefix .. string.rep(" ", project_settings.MAX_FILE_BYTES - #prefix))
	assert(project_settings.approve(root), "exact 1 MiB file was rejected")
	write(settings, prefix .. string.rep(" ", project_settings.MAX_FILE_BYTES - #prefix + 1))
	value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "oversized file changed global fallback")
	assert(err:find("1 MiB", 1, true))

	local outside = vim.fs.joinpath(temp_dir(), "outside.json")
	write(outside, '{ "escaped": true }')
	assert(vim.uv.fs_unlink(settings))
	assert(vim.uv.fs_symlink(outside, settings))
	value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "symlinked settings escaped")
	assert(err:find("single-link", 1, true))
	assert(vim.uv.fs_unlink(settings))
	write(settings, '{ "linked": true }')
	local hardlink = vim.fs.joinpath(root, "hardlink.json")
	assert(vim.uv.fs_link(settings, hardlink))
	value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "hard-linked settings escaped")
	assert(err:find("single-link", 1, true))
	assert(vim.fn.delete(vscode_dir, "rf") == 0)
	local real_settings = vim.fs.joinpath(root, "real-settings")
	assert(vim.fn.mkdir(real_settings, "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(real_settings, "settings.json"), '{ "ancestor": "escaped" }')
	assert(vim.uv.fs_symlink(real_settings, vscode_dir, { dir = true }))
	value, err = project_settings.get("vscode", {}, root)
	equal({ safe = true }, value, "ancestor symlink settings escaped")
	assert(err:find("real directory without symlinks", 1, true))

	vim.fn.delete(vim.fs.dirname(outside), "rf")
	vim.fn.delete(root, "rf")
end)

test("repository root replacement during a read is rejected", function()
	local root = temp_dir()
	local moved = root .. ".moved"
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "raced": true }')
	harness(root, { vscode = { safe = true } })
	local original_read = vim.uv.fs_read
	local replaced = false
	vim.uv.fs_read = function(...)
		if not replaced then
			replaced = true
			assert(vim.uv.fs_rename(root, moved))
			assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
			write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "replacement": true }')
		end
		return original_read(...)
	end
	local ok, value, err = xpcall(function()
		local result, reason = project_settings.get("vscode", {}, root)
		return result, reason
	end, debug.traceback)
	vim.uv.fs_read = original_read
	assert(ok, value)
	equal({ safe = true }, value, "replacement root settings escaped")
	assert(err:find("identity changed", 1, true) or err:find("changed or escaped", 1, true))
	vim.fn.delete(root, "rf")
	vim.fn.delete(moved, "rf")
end)

test("outside Git uses only immutable global values", function()
	local root = temp_dir()
	harness(root, { vscode = { global = { enabled = true } } })
	local value, err = project_settings.get("vscode", {}, "outside")
	equal({ global = { enabled = true } }, value, "outside-Git global value was lost")
	assert(err:find("not inside a Git repository", 1, true))
	value.global.enabled = false
	equal(true, project_settings.get("vscode", {}, "outside").global.enabled, "global return was mutable")
	vim.fn.delete(root, "rf")
end)

test("read warnings deduplicate while every successful command approval notifies", function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	local path = vim.fs.joinpath(root, ".vscode/settings.json")
	write(path, '{ "x": /* unique unterminated warning')
	local state = harness(root, {})
	project_settings.get("vscode", {}, root)
	project_settings.get("vscode", {}, root)
	equal(1, #state.notifications, "repeated invalid reads spammed warnings")
	write(path, '{ "python.analysis.typeCheckingMode": "strict" }')
	project_settings.setup({ command = true })
	vim.cmd("NvimConfigTrustProjectSettings")
	write(path, '{ "python.analysis.typeCheckingMode": "basic" }')
	vim.cmd("NvimConfigTrustProjectSettings")
	equal(3, #state.notifications, "a successful approval restart notice was suppressed")
	assert(state.notifications[2] == state.notifications[3], "success notification text drifted between approvals")
	vim.api.nvim_del_user_command("NvimConfigTrustProjectSettings")
	vim.fn.delete(root, "rf")
end)

test("LSP settings merge requests one batch for VSCode and server values", function()
	local original_get_many = project_settings.get_many
	local calls = 0
	local requested
	local requested_start
	project_settings.get_many = function(defaults, start)
		calls = calls + 1
		requested = vim.deepcopy(defaults)
		requested_start = start
		return {
			vscode = { ty = { disableLanguageServices = false } },
			["lspconfig.ty"] = { ty = { configuration = { environment = { python = "/repo/.venv" } } } },
		}
	end
	local ok, err = xpcall(function()
		local config = { root_dir = "/repo", settings = { ty = { baseline = true } } }
		lsp_neoconf.wrap_before_init("ty")({}, config)
		equal(1, calls, "LSP merge split one operation into multiple project lookups")
		equal(
			{ vscode = {}, ["lspconfig.ty"] = {} },
			requested,
			"LSP merge did not request the exact VSCode/server batch"
		)
		equal("/repo", requested_start, "LSP merge lost its project root")
		equal(true, config.settings.ty.baseline, "LSP batch merge lost baseline settings")
		equal(false, config.settings.ty.disableLanguageServices, "LSP batch merge lost VSCode settings")
		equal(
			"/repo/.venv",
			config.settings.ty.configuration.environment.python,
			"LSP batch merge lost server settings"
		)
	end, debug.traceback)
	project_settings.get_many = original_get_many
	assert(ok, err)
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("project_settings_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
