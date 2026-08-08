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

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p") == 1, "could not create temporary directory")
	return path
end

test("local config diagnostics redact environment values without mutating cache", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	local secret = "security-spec-secret-value"
	local oauth_secret = "security-spec-oauth-value"
	assert(vim.fn.writefile({
		"return {",
		"  theme = { background = 'light' },",
		"  codecompanion = { oauth_token = '" .. oauth_secret .. "' },",
		"  env = { CONFIG_SECRET = '" .. secret .. "', EMPTY_SECRET = '' },",
		"}",
	}, config_path) == 0, "could not write temporary local config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	vim.env.NVIM_CONFIG_FILE = config_path
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local runtime = local_config.read()
	local display = local_config.display_config()

	assert(display ~= runtime, "display helper returned the runtime cache")
	assert(display.env.CONFIG_SECRET == "<redacted>", "secret value was not redacted")
	assert(display.env.EMPTY_SECRET == "<redacted>", "empty environment value was not redacted")
	assert(display.codecompanion.oauth_token == "<redacted>", "nested OAuth token was not redacted")
	assert(runtime.env.CONFIG_SECRET == secret, "display helper mutated the cached secret")
	assert(runtime.env.EMPTY_SECRET == "", "display helper mutated the cached empty value")
	assert(runtime.codecompanion.oauth_token == oauth_secret, "display helper mutated the cached OAuth token")
	display.theme.background = "dark"
	assert(local_config.read().theme.background == "light", "display snapshot shares nested runtime tables")

	local notifications = {}
	local original_notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	local_config.setup()
	vim.cmd("NvimConfigDump")
	local dump = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	assert(dump:find("CONFIG_SECRET", 1, true), "dump removed the environment key")
	assert(dump:find("<redacted>", 1, true), "dump omitted the redaction marker")
	assert(not dump:find(secret, 1, true), "dump disclosed a secret value")
	assert(not dump:find(oauth_secret, 1, true), "dump disclosed the nested OAuth token")

	vim.cmd("NvimConfigReload")
	local message = notifications[#notifications] or ""
	assert(message:lower():find("restart", 1, true), "reload message does not require a restart")
	assert(message:find("runtime", 1, true), "reload message overstates live runtime application")

	vim.notify = original_notify
	vim.env.NVIM_CONFIG_FILE = original_override
	vim.fn.delete(root, "rf")
end)

test("legacy OAuth config is isolated from vim.env and warns once", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	local legacy_token = "security-spec-legacy-oauth"
	assert(vim.fn.writefile({
		"return { env = {",
		"  CLAUDE_CODE_OAUTH_TOKEN = '" .. legacy_token .. "',",
		"  SECURITY_SPEC_PUBLIC = 'applied',",
		"} }",
	}, config_path) == 0, "could not write temporary legacy config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	local original_oauth = vim.env.CLAUDE_CODE_OAUTH_TOKEN
	local original_public = vim.env.SECURITY_SPEC_PUBLIC
	local original_path = vim.env.PATH
	local original_notify = vim.notify
	local notifications = {}
	vim.env.NVIM_CONFIG_FILE = config_path
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = nil
	vim.env.SECURITY_SPEC_PUBLIC = nil
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end

	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local_config.apply_env()
	assert(vim.env.CLAUDE_CODE_OAUTH_TOKEN == nil, "legacy OAuth token leaked into vim.env")
	assert(vim.env.SECURITY_SPEC_PUBLIC == "applied", "ordinary environment entry was not applied")
	assert(local_config.codecompanion_oauth_token() == legacy_token, "legacy OAuth fallback was not returned")
	assert(#notifications == 1, string.format("legacy fallback warned %d times instead of once", #notifications))
	assert(notifications[1]:find("deprecated", 1, true), "legacy warning is not actionable")
	assert(local_config.display_config().env.CLAUDE_CODE_OAUTH_TOKEN == "<redacted>", "legacy token was not redacted")

	vim.notify = original_notify
	vim.env.NVIM_CONFIG_FILE = original_override
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = original_oauth
	vim.env.SECURITY_SPEC_PUBLIC = original_public
	vim.env.PATH = original_path
	vim.fn.delete(root, "rf")
end)

test("CodeCompanion keeps OAuth credentials in the ACP child adapter", function()
	local root = temp_dir()
	local config_path = root .. "/host.lua"
	local token = "security-spec-child-only-token"
	assert(vim.fn.writefile({
		"return { codecompanion = {",
		"  oauth_token = '" .. token .. "',",
		"  acp_command = { '/custom/bin/claude-agent-acp', '--stdio' },",
		"} }",
	}, config_path) == 0, "could not write temporary CodeCompanion config")

	local original_override = vim.env.NVIM_CONFIG_FILE
	local original_oauth = vim.env.CLAUDE_CODE_OAUTH_TOKEN
	local original_adapters = package.loaded["codecompanion.adapters"]
	vim.env.NVIM_CONFIG_FILE = config_path
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = nil
	package.loaded["config.local_config"] = nil
	package.loaded["plugins.codecompanion"] = nil
	package.loaded["codecompanion.adapters"] = {
		extend = function(_, overrides)
			return overrides
		end,
	}

	local spec = require("plugins.codecompanion")[1]
	local adapter = spec.opts.adapters.acp.claude_code()
	assert(spec.opts.interactions ~= nil, "CodeCompanion interactions config is missing")
	assert(spec.opts.strategies == nil, "deprecated CodeCompanion strategies config remains")
	assert(
		vim.deep_equal(adapter.commands.default, {
			"/custom/bin/claude-agent-acp",
			"--stdio",
		}),
		"explicit ACP command did not take priority"
	)
	assert(adapter.commands.yolo[#adapter.commands.yolo] == "--yolo", "ACP yolo command lost its mode flag")
	assert(#adapter.commands.yolo == 3, "ACP yolo command was appended more than once")
	assert(adapter.env.CLAUDE_CODE_OAUTH_TOKEN == token, "OAuth token was not attached to adapter.env")
	assert(vim.env.CLAUDE_CODE_OAUTH_TOKEN == nil, "building the ACP adapter mutated vim.env")

	adapter.env_replaced = { CLAUDE_CODE_OAUTH_TOKEN = token }
	assert(adapter.handlers.auth(adapter), "ACP auth override rejected the child token")
	assert(vim.env.CLAUDE_CODE_OAUTH_TOKEN == nil, "ACP auth override mutated vim.env")

	package.loaded["codecompanion.adapters"] = original_adapters
	package.loaded["plugins.codecompanion"] = nil
	vim.env.NVIM_CONFIG_FILE = original_override
	vim.env.CLAUDE_CODE_OAUTH_TOKEN = original_oauth
	vim.fn.delete(root, "rf")
end)

test("CodeCompanion resolves a host ACP before its exact npx fallback", function()
	local original_local_config = package.loaded["config.local_config"]
	local original_tool_paths = package.loaded["config.tool_paths"]
	local original_adapters = package.loaded["codecompanion.adapters"]
	package.loaded["codecompanion.adapters"] = {
		extend = function(_, overrides)
			return overrides
		end,
	}
	package.loaded["config.local_config"] = {
		get = function()
			return { acp_command = {} }
		end,
		codecompanion_oauth_token = function()
			return "child-token"
		end,
	}

	package.loaded["config.tool_paths"] = {
		external_executable = function(name)
			assert(name == "claude-agent-acp")
			return "/host/bin/claude-agent-acp"
		end,
	}
	package.loaded["plugins.codecompanion"] = nil
	local adapter = require("plugins.codecompanion")[1].opts.adapters.acp.claude_code()
	assert(vim.deep_equal(adapter.commands.default, { "/host/bin/claude-agent-acp" }))

	package.loaded["config.tool_paths"].external_executable = function()
		return nil
	end
	package.loaded["plugins.codecompanion"] = nil
	adapter = require("plugins.codecompanion")[1].opts.adapters.acp.claude_code()
	assert(vim.deep_equal(adapter.commands.default, {
		"npx",
		"--yes",
		"@agentclientprotocol/claude-agent-acp@0.66.0",
	}))

	package.loaded["config.local_config"].get = function()
		return { acp_command = { "/custom/acp", "--yolo" } }
	end
	package.loaded["plugins.codecompanion"] = nil
	adapter = require("plugins.codecompanion")[1].opts.adapters.acp.claude_code()
	local yolo_count = 0
	for _, argument in ipairs(adapter.commands.yolo) do
		if argument == "--yolo" then
			yolo_count = yolo_count + 1
		end
	end
	assert(yolo_count == 1, "ACP mode flag was duplicated")

	package.loaded["config.local_config"] = original_local_config
	package.loaded["config.tool_paths"] = original_tool_paths
	package.loaded["codecompanion.adapters"] = original_adapters
	package.loaded["plugins.codecompanion"] = nil
end)

test("lazy bootstrap reports clone failure without network access", function()
	local root = temp_dir()
	local bin = root .. "/bin"
	assert(vim.fn.mkdir(bin, "p") == 1, "could not create fake binary directory")
	local fake_git = bin .. "/git"
	assert(
		vim.fn.writefile({ "#!/bin/sh", "printf '%s\\n' '  simulated clone failure  '", "exit 23" }, fake_git) == 0,
		"could not write fake git"
	)
	assert(vim.fn.setfperm(fake_git, "rwxr-xr-x") == 1, "could not make fake git executable")

	local result = vim.system({
		vim.v.progpath,
		"--headless",
		"-u",
		"NONE",
		"--cmd",
		"set runtimepath^=" .. repo,
		"-c",
		"lua local ok, err = pcall(require, 'config.lazy'); if ok then vim.cmd('quitall!') else vim.api.nvim_err_writeln(tostring(err)); vim.cmd('cquit 42') end",
	}, {
		text = true,
		env = {
			PATH = bin .. ":" .. (vim.env.PATH or ""),
			XDG_DATA_HOME = root .. "/data",
			NVIM_APPNAME = "nvim-security-spec",
		},
	}):wait(10000)
	vim.fn.delete(root, "rf")

	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
	assert(result.code ~= 0, "bootstrap unexpectedly succeeded")
	assert(output:find("simulated clone failure", 1, true), "clone output was not reported")
	assert(output:find("lazy/lazy.nvim", 1, true), "bootstrap destination was not reported")
	assert(output:find("git exit 23", 1, true), "git exit status was not reported")
	assert(output:find("Check Git/network access", 1, true), "bootstrap error is not actionable")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("security_spec: %d tests passed", count))
vim.cmd("quitall!")
