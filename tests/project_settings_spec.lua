vim.o.shadafile = "NONE"
vim.o.swapfile = false

local checkout = vim.fn.getcwd()
vim.opt.runtimepath:prepend(checkout)
package.path = table.concat({ checkout .. "/lua/?.lua", checkout .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local project_settings = require("config.project_settings")
local lsp_neoconf = require("config.lsp_neoconf")

local equal = require("tests.helpers").equal

local T = MiniTest.new_set()

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
	local notifications = {}
	local counts = { root = 0 }
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
		repo = repo,
		neoconf = neoconf,
		notify = function(message)
			notifications[#notifications + 1] = tostring(message)
		end,
	})
	return {
		counts = counts,
		notifications = notifications,
	}
end

T["project JSONC applies immediately and edits apply on the next read"] = function()
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
	harness(root, {
		vscode = { ty = { configuration = { rules = { ["possibly-unresolved-reference"] = "ignore" } } } },
		["lspconfig.ty"] = { ty = { configuration = { rules = { ["unresolved-import"] = "error" } } } },
	})

	local value, err = project_settings.get("vscode", {}, root)
	assert(err == nil, err)
	equal("ignore", value.ty.configuration.rules["possibly-unresolved-reference"], "global setting did not merge")
	equal("warn", value.ty.configuration.rules["unresolved-reference"], "dotted VSCode key did not expand")
	equal(false, value.ty.disableLanguageServices, "false value was lost")
	equal("https://example.invalid/a//b", value.ty.configurationFile, "comment lexer changed a string")
	equal(false, project_settings.get("lspconfig.ty", {}, root), "server disable did not override global")
	local snapshot = assert(project_settings.snapshot(root))
	assert(snapshot.present and snapshot.approved == nil, "snapshot still reports an approval state")
	equal("warn", snapshot.values.vscode.ty.configuration.rules["unresolved-reference"], "snapshot hid project data")
	local first_fingerprint = snapshot.fingerprint

	write(
		vim.fs.joinpath(root, ".vscode/settings.json"),
		'{ "ty.configuration.rules.unresolved-reference": "error" }\n'
	)
	local changed = assert(project_settings.get("vscode", {}, root))
	equal(
		"ignore",
		changed.ty.configuration.rules["possibly-unresolved-reference"],
		"global fallback was lost after mutation"
	)
	equal("error", changed.ty.configuration.rules["unresolved-reference"], "edited project setting was not applied")
	assert(assert(project_settings.snapshot(root)).fingerprint ~= first_fingerprint, "fingerprint ignored the edit")
	assert(vim.fn.exists(":NvimConfigTrustProjectSettings") == 0, "removed approval command still exists")

	vim.fn.delete(root, "rf")
end

T["batch lookup reads each file once and returns isolated values"] = function()
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
end

T["single lookup preserves an explicit nil default"] = function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "ty.disableLanguageServices": false }')
	harness(root, {})
	local value, err = project_settings.get("vscode", nil, root)
	assert(err == nil, err)
	equal(false, value.ty.disableLanguageServices, "nil default discarded the single setting")
	vim.fn.delete(root, "rf")
end

T["project Neoconf settings preserve dotted-key expansion"] = function()
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
	local ty = assert(project_settings.get("lspconfig.ty", {}, root))
	equal("warn", ty.ty.configuration.rules["unresolved-reference"], "server-local dotted key did not expand")
	equal(false, ty.ty.disableLanguageServices, "server-local false value was lost")
	local ruff = assert(project_settings.get("lspconfig.ruff", {}, root))
	equal(true, ruff.settings.lint.preview, "top-level Neoconf dotted key did not expand")
	vim.fn.delete(root, "rf")
end

T["global Neoconf lspconfig settings preserve dotted-key expansion"] = function()
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
end

T["combined fingerprint covers appearance and disappearance of either file"] = function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	write(vim.fs.joinpath(root, ".vscode/settings.json"), '{ "editor.formatOnSave": true }')
	harness(root, {})
	local original = assert(project_settings.snapshot(root))
	assert(original.present, "existing settings were not detected")
	write(vim.fs.joinpath(root, ".neoconf.json"), '{ "lspconfig": {} }')
	local appeared = assert(project_settings.snapshot(root))
	assert(appeared.present and appeared.fingerprint ~= original.fingerprint, "appearance kept the fingerprint")
	assert(vim.uv.fs_unlink(vim.fs.joinpath(root, ".neoconf.json")))
	equal(original.fingerprint, assert(project_settings.snapshot(root)).fingerprint, "exact bytes changed fingerprint")
	assert(vim.uv.fs_unlink(vim.fs.joinpath(root, ".vscode/settings.json")))
	local absent = assert(project_settings.snapshot(root))
	assert(not absent.present and vim.tbl_isempty(absent.values.vscode), "absent settings exposed values")
	vim.fn.delete(root, "rf")
end

T["invalid oversized and hostile files fail closed"] = function()
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

	local prefix = '{ "value": true }'
	write(settings, prefix .. string.rep(" ", project_settings.MAX_FILE_BYTES - #prefix))
	local exact, exact_err = project_settings.get("vscode", {}, root)
	assert(exact_err == nil and exact.value == true, "exact 1 MiB file was rejected")
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
end

T["repository root replacement during a read is rejected"] = function()
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
end

T["outside Git uses only immutable global values"] = function()
	local root = temp_dir()
	harness(root, { vscode = { global = { enabled = true } } })
	local value, err = project_settings.get("vscode", {}, "outside")
	equal({ global = { enabled = true } }, value, "outside-Git global value was lost")
	assert(err:find("not inside a Git repository", 1, true))
	value.global.enabled = false
	equal(true, project_settings.get("vscode", {}, "outside").global.enabled, "global return was mutable")
	vim.fn.delete(root, "rf")
end

T["read warnings deduplicate"] = function()
	local root = temp_dir()
	assert(vim.fn.mkdir(vim.fs.joinpath(root, ".vscode"), "p", tonumber("700", 8)) == 1)
	local path = vim.fs.joinpath(root, ".vscode/settings.json")
	write(path, '{ "x": /* unique unterminated warning')
	local state = harness(root, {})
	project_settings.get("vscode", {}, root)
	project_settings.get("vscode", {}, root)
	equal(1, #state.notifications, "repeated invalid reads spammed warnings")
	write(path, '{ "python.analysis.typeCheckingMode": "strict" }')
	local value, err = project_settings.get("vscode", {}, root)
	assert(err == nil, err)
	equal("strict", value.python.analysis.typeCheckingMode, "repaired settings were not applied")
	equal(1, #state.notifications, "valid settings produced a notification")
	vim.fn.delete(root, "rf")
end

T["LSP settings merge requests one batch for VSCode and server values"] = function()
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
end

return T
