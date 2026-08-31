-- lua/config/local_config.lua
-- Per-host / per-project local configuration.
--
-- Reads an owner-defined Lua file that returns a table. Two locations are
-- consulted and deep-merged, with the project file overriding the host file:
--
--   ~/.nvim-local.lua    -- per host (trusted: it is yours)
--   ./.nvim-local.lua    -- per project (loaded via vim.secure.read trust prompt)
--
-- A missing or malformed file is ignored (never raises). Unknown or wrong-typed
-- fields are reported as warnings and fall back to their defaults; a broken
-- local config must not break startup.
--
-- Schema (all fields optional; defaults shown):
--
--   return {
--     theme = {
--       background = "auto",     -- auto | light | dark
--       transparent = false,
--       italic_comments = true,
--     },
--     clangd = { path = "clangd", profile = "full" },
--     dap = { ui = "dap-ui" }, -- dap-ui | dap-view
--     mason = { auto_install = true },
--     review = { hunk_context = 3 }, -- finite non-negative integer
--     log_watch = { max_lines = 100000, max_bytes = 67108864 },
--     diagram_cache = { max_age_seconds = 2592000, max_bytes = 268435456 },
--     path = { "~/bin" },          -- dirs prepended to $PATH
--     env = { FOO = "bar" },       -- environment variables to export
--     plugins_dir = { "~/.nvim-plugins" }, -- dirs of extra lazy.nvim specs
--   }
--
-- Override the host path with $NVIM_CONFIG_FILE (for testing).

local trusted_workspace = require("trusted_workspace")

local M = {}

local TITLE = "nvim.config"
local PROJECT_NAME = ".nvim-local.lua"

local SCHEMA = {
	theme = {
		type = "table",
		fields = {
			background = { type = "enum", values = { "auto", "light", "dark" }, default = "auto" },
			transparent = { type = "boolean", default = false },
			italic_comments = { type = "boolean", default = true },
		},
	},
	clangd = {
		type = "table",
		fields = {
			path = { type = "string", default = "clangd" },
			profile = { type = "enum", values = { "full", "light" }, default = "full" },
		},
	},
	dap = {
		type = "table",
		fields = {
			ui = { type = "enum", values = { "dap-ui", "dap-view" }, default = "dap-ui" },
		},
	},
	mason = {
		type = "table",
		fields = {
			auto_install = { type = "boolean", default = true },
		},
	},
	review = {
		type = "table",
		fields = {
			hunk_context = { type = "number", default = 3, finite = true, integer = true, min = 0 },
		},
	},
	log_watch = {
		type = "table",
		fields = {
			max_lines = { type = "number", default = 100000 },
			max_bytes = { type = "number", default = 64 * 1024 * 1024 },
		},
	},
	diagram_cache = {
		type = "table",
		fields = {
			max_age_seconds = { type = "number", default = 30 * 24 * 60 * 60 },
			max_bytes = { type = "number", default = 256 * 1024 * 1024 },
		},
	},
	path = {
		type = "list",
		default = {},
		item = { type = "string" },
	},
	env = {
		type = "map",
		default = {},
		value = { type = "string" },
		sensitive = true,
	},
	plugins_dir = {
		type = "list",
		default = {},
		item = { type = "string" },
	},
}

local cache = nil
local sources = {}
local last_errors = {}
local blocked_env_warnings = {}
local BLOCKED_ENV_KEYS = {
	CLAUDE_CODE_OAUTH_TOKEN = true,
}

local function warn_blocked_env_key(key)
	if blocked_env_warnings[key] then
		return
	end
	blocked_env_warnings[key] = true
	vim.notify(
		("env.%s is ignored and will not be exported by this config"):format(key),
		vim.log.levels.WARN,
		{ title = TITLE }
	)
end

-- Paths -------------------------------------------------------------------

local function home_path()
	local override = vim.env.NVIM_CONFIG_FILE
	if override and override ~= "" then
		return vim.fn.fnamemodify(vim.fn.expand(override), ":p")
	end
	return vim.fn.fnamemodify(vim.fn.expand("~/" .. PROJECT_NAME), ":p")
end

local function project_path()
	return vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. PROJECT_NAME, ":p")
end

local function trust_state_root()
	local override = vim.env.NVIM_CONFIG_TRUST_STATE_ROOT
	if override and override ~= "" then
		return vim.fn.fnamemodify(vim.fn.expand(override), ":p")
	end
	return vim.fs.joinpath(vim.fn.stdpath("state"), "trusted-workspace")
end

local function workspace_mode()
	if vim.g.vscode or vim.env.NVIM_APPNAME == "nvimpager" then
		return "host-only"
	end
	return "full"
end

local function repo_identity()
	local cwd = vim.fn.getcwd()
	return vim.uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
end

-- Loading -----------------------------------------------------------------

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.WARN, { title = TITLE })
end

local function run_chunk(chunk, err, path)
	if not chunk then
		notify("Error loading " .. path .. ": " .. err)
		return nil
	end
	local ok, result = pcall(chunk)
	if not ok then
		notify("Error running " .. path .. ": " .. tostring(result))
		return nil
	end
	if type(result) ~= "table" then
		notify(path .. " must return a table")
		return nil
	end
	return result
end

-- Host file: it belongs to the owner, so load it directly.
local function load_host(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil, "absent"
	end
	local chunk, err = loadfile(path)
	local result = run_chunk(chunk, err, path)
	return result, result and "loaded" or "error"
end

-- Project file: arbitrary directories are untrusted, so gate on vim.secure.read
-- (the same trust flow as exrc). Returns nil if the user declines.
local function load_project(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil, "absent"
	end
	local contents = vim.secure.read(path)
	if not contents then
		return nil, "untrusted"
	end
	local chunk, err = load(contents, "@" .. path)
	local result = run_chunk(chunk, err, path)
	return result, result and "loaded" or "error", result and vim.fn.sha256(contents) or nil
end

-- Validation --------------------------------------------------------------

local validate_value, validate_fields

function validate_fields(fields, value, path, errors)
	local out = {}
	for key, spec in pairs(fields) do
		local child = path == "" and key or (path .. "." .. key)
		out[key] = validate_value(spec, value[key], child, errors)
	end
	for key in pairs(value) do
		if not fields[key] then
			errors[#errors + 1] = (path == "" and key or path .. "." .. key) .. ": unknown field (ignored)"
		end
	end
	return out
end

function validate_value(spec, value, path, errors)
	local t = spec.type

	if t == "table" then
		local v = value == nil and {} or value
		if type(v) ~= "table" then
			errors[#errors + 1] = string.format("%s: expected table, got %s", path, type(v))
			v = {}
		end
		return validate_fields(spec.fields, v, path, errors)
	end

	if t == "list" then
		if value == nil then
			return spec.default or {}
		end
		-- Accept a bare string where a list of strings is expected.
		if type(value) == "string" and spec.item and spec.item.type == "string" then
			value = { value }
		end
		if type(value) ~= "table" then
			errors[#errors + 1] = string.format("%s: expected list, got %s", path, type(value))
			return spec.default or {}
		end
		local out = {}
		for i, item in ipairs(value) do
			local before = #errors
			local v = validate_value(spec.item, item, string.format("%s[%d]", path, i), errors)
			-- Drop any item that produced an error rather than keep it half-valid.
			if #errors == before then
				out[#out + 1] = v
			end
		end
		return out
	end

	if t == "map" then
		local v = value == nil and {} or value
		if type(v) ~= "table" then
			errors[#errors + 1] = string.format("%s: expected table, got %s", path, type(v))
			return spec.default or {}
		end
		local out = {}
		for key, item in pairs(v) do
			if type(key) ~= "string" then
				errors[#errors + 1] = string.format("%s: keys must be strings", path)
			else
				local before = #errors
				local vv = validate_value(spec.value, item, path .. "." .. key, errors)
				-- Drop any entry that produced an error rather than keep it invalid.
				if #errors == before then
					out[key] = vv
				end
			end
		end
		return out
	end

	if value == nil then
		if spec.required then
			errors[#errors + 1] = path .. ": required"
		end
		return spec.default
	end

	if t == "enum" then
		if type(value) ~= "string" or not vim.tbl_contains(spec.values, value) then
			errors[#errors + 1] = string.format(
				"%s: expected one of %s, got %s",
				path,
				table.concat(spec.values, "|"),
				vim.inspect(value)
			)
			return spec.default
		end
		return value
	end

	-- string | boolean | number
	if type(value) ~= t then
		errors[#errors + 1] = string.format("%s: expected %s, got %s", path, t, type(value))
		return spec.default
	end
	if t == "number" then
		local invalid = (spec.finite and (value ~= value or value == math.huge or value == -math.huge))
			or (spec.integer and value % 1 ~= 0)
			or (spec.min and value < spec.min)
		if invalid then
			errors[#errors + 1] =
				string.format("%s: expected a finite non-negative integer, got %s", path, vim.inspect(value))
			return spec.default
		end
	end
	return value
end

-- Compute -----------------------------------------------------------------

local function compute()
	sources = {}
	last_errors = {}
	local mode = workspace_mode()
	local setup_ok, setup_err = trusted_workspace.setup({
		state_root = trust_state_root(),
		mode = mode,
	})
	if not setup_ok then
		last_errors[#last_errors + 1] = "trusted workspace state: " .. tostring(setup_err)
	end

	local home = home_path()
	local host_cfg, host_status = load_host(home)
	sources[#sources + 1] = { path = home, status = host_status }
	local _, host_err = trusted_workspace.register_source({
		id = "local-config-host",
		layer = "host",
		value = host_cfg or {},
	})
	if host_err then
		last_errors[#last_errors + 1] = "host source: " .. tostring(host_err)
	end

	local project = project_path()
	if project ~= home then
		local proj_cfg
		local proj_status
		local fingerprint
		if mode == "full" then
			proj_cfg, proj_status, fingerprint = load_project(project)
		else
			proj_status = "disabled"
		end
		sources[#sources + 1] = { path = project, status = proj_status }
		if proj_cfg then
			local repo = repo_identity()
			local _, source_err = trusted_workspace.register_source({
				id = "local-config-project",
				layer = "project",
				repo = repo,
				fingerprint = fingerprint,
				value = proj_cfg,
			})
			if source_err then
				last_errors[#last_errors + 1] = "project source: " .. tostring(source_err)
			end
			local approved, approval_err = trusted_workspace.approve(repo, "local-config-project", fingerprint)
			if not approved then
				last_errors[#last_errors + 1] = "project approval: " .. tostring(approval_err)
			end
		else
			local _, source_err = trusted_workspace.register_source({
				id = "local-config-project",
				layer = "project",
				repo = repo_identity(),
				fingerprint = "disabled:" .. tostring(proj_status),
				value = {},
				enabled = false,
			})
			if source_err then
				last_errors[#last_errors + 1] = "project source: " .. tostring(source_err)
			end
		end
	else
		local _, source_err = trusted_workspace.register_source({
			id = "local-config-project",
			layer = "project",
			repo = repo_identity(),
			fingerprint = "disabled:same-as-host",
			value = {},
			enabled = false,
		})
		if source_err then
			last_errors[#last_errors + 1] = "project source: " .. tostring(source_err)
		end
	end

	local snapshot, snapshot_err = trusted_workspace.snapshot()
	if not snapshot then
		last_errors[#last_errors + 1] = "trusted workspace snapshot: " .. tostring(snapshot_err)
		snapshot = { value = {} }
	end
	local authority_status = trusted_workspace.status()
	if
		type(authority_status) == "table"
		and type(authority_status.candidate) == "table"
		and type(authority_status.candidate.validity) == "table"
		and type(authority_status.candidate.validity.errors) == "table"
	then
		vim.list_extend(last_errors, authority_status.candidate.validity.errors)
	end
	local validated = validate_fields(SCHEMA, snapshot.value, "", last_errors)
	if #last_errors > 0 then
		notify("Local config issues:\n  " .. table.concat(last_errors, "\n  "))
	end
	return validated
end

-- Public API --------------------------------------------------------------

function M.read()
	if cache == nil then
		cache = compute()
	end
	return vim.deepcopy(cache)
end

function M.get(key, default)
	local v = M.read()[key]
	if v == nil then
		return default
	end
	return v
end

function M.reload()
	cache = nil
	return M.read()
end

-- Apply $PATH and environment overrides. Call early in init.lua so they are in
-- place before plugins/mason rely on them.
function M.apply_env()
	local cfg = M.read()
	for key, value in pairs(cfg.env or {}) do
		if BLOCKED_ENV_KEYS[key] then
			warn_blocked_env_key(key)
		else
			vim.env[key] = value
		end
	end
	require("config.tool_paths").apply(cfg.path)
end

-- Introspection for :NvimConfigDump and :checkhealth.
function M.sources()
	M.read()
	return vim.deepcopy(sources)
end

function M.errors()
	M.read()
	return vim.deepcopy(last_errors)
end

local function redact_all(value)
	if type(value) ~= "table" then
		return "<redacted>"
	end
	local out = {}
	for key, child in pairs(value) do
		out[key] = redact_all(child)
	end
	return out
end

local function redact_value(spec, value)
	if value == nil then
		return nil
	end
	if spec.sensitive then
		return redact_all(value)
	end
	if type(value) ~= "table" then
		return value
	end

	local out = {}
	if spec.type == "table" then
		for key, child in pairs(value) do
			local child_spec = spec.fields[key]
			out[key] = child_spec and redact_value(child_spec, child) or vim.deepcopy(child)
		end
	elseif spec.type == "list" then
		for index, child in ipairs(value) do
			out[index] = redact_value(spec.item, child)
		end
	elseif spec.type == "map" then
		for key, child in pairs(value) do
			out[key] = redact_value(spec.value, child)
		end
	else
		return vim.deepcopy(value)
	end
	return out
end

-- Return a safe, recursively redacted snapshot for diagnostics. Work on a new
-- table so displaying or modifying it cannot affect the runtime cache.
function M.display_config()
	return redact_value({ type = "table", fields = SCHEMA }, M.read())
end

-- Template written by :NvimConfigInit.
local TEMPLATE = [[-- ~/.nvim-local.lua -- per-host Neovim settings (not under version control).
-- See lua/config/local_config.lua for the full schema. All fields are optional.

return {
  theme = {
    background = "auto", -- auto | light | dark
    transparent = false,
    italic_comments = true,
  },
  -- Override the clangd binary on this host.
  clangd = { path = "clangd", profile = "full" }, -- full | light

  -- Debug UI selected at startup. $NVIM_DAP_UI overrides this value.
  dap = { ui = "dap-ui" }, -- dap-ui | dap-view

  -- Attempt each exact Mason/managed tool pin once on interactive startup.
  mason = { auto_install = true },

  -- Unchanged lines shown around each native review hunk.
  review = { hunk_context = 3 },

  -- Safety bounds for incremental log following and rendered-diagram cache.
  log_watch = { max_lines = 100000, max_bytes = 64 * 1024 * 1024 },
  diagram_cache = { max_age_seconds = 30 * 24 * 60 * 60, max_bytes = 256 * 1024 * 1024 },

  -- Directories prepended to $PATH (expanded).
  path = {
    -- "~/bin",
  },

  -- Environment variables exported on startup.
  env = {
    -- PKG_CONFIG_PATH = "/opt/x/lib/pkgconfig",
  },

  -- Directories of extra lazy.nvim plugin specs (like lua/plugins, but external).
  -- Each *.lua file returns a spec or list of specs; loaded via a trust prompt.
  plugins_dir = {
    -- "~/.nvim-plugins",
  },
}
]]

-- Commands & autocmds -----------------------------------------------------

local function open_scratch(lines, name)
	vim.cmd("new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "lua"
	vim.bo[buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, buf, name)
end

function M.setup()
	vim.api.nvim_create_user_command("NvimConfigDump", function()
		local cfg = M.display_config()
		local lines = {}
		for _, s in ipairs(M.sources()) do
			lines[#lines + 1] = "-- " .. s.path .. " [" .. s.status .. "]"
		end
		lines[#lines + 1] = ""
		vim.list_extend(lines, vim.split("return " .. vim.inspect(cfg), "\n", { plain = true }))
		open_scratch(lines, "nvim-local config")
	end, { desc = "Show the effective local config" })

	vim.api.nvim_create_user_command("NvimConfigInit", function(opts)
		local path = home_path()
		if vim.fn.filereadable(path) == 1 and not opts.bang then
			notify(path .. " already exists (use :NvimConfigInit! to overwrite)")
			return
		end
		local ok, err = pcall(vim.fn.writefile, vim.split(TEMPLATE, "\n", { plain = true }), path)
		if not ok then
			notify("Failed to write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		notify("Wrote local config template to " .. path, vim.log.levels.INFO)
	end, { bang = true, desc = "Create a local config template in $HOME" })

	vim.api.nvim_create_user_command("NvimConfigEdit", function()
		local path = home_path()
		vim.cmd.edit(vim.fn.fnameescape(path))
		-- Seed a fresh (on-disk-absent) buffer with the template as a starting
		-- point; nothing is written until the user saves.
		if vim.fn.filereadable(path) ~= 1 and vim.api.nvim_buf_line_count(0) <= 1 then
			vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(TEMPLATE, "\n", { plain = true }))
		end
	end, { desc = "Open the host local config (~/.nvim-local.lua) for editing" })

	vim.api.nvim_create_user_command("NvimConfigReload", function()
		M.reload()
		notify(
			"Local config cache reloaded; restart Neovim to apply all runtime, theme, and plugin changes",
			vim.log.levels.INFO
		)
	end, { desc = "Reload local config cache (restart to apply all changes)" })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = vim.api.nvim_create_augroup("nvim_local_config", { clear = true }),
		pattern = "*" .. PROJECT_NAME,
		callback = function()
			M.reload()
		end,
		desc = "Reload local config when .nvim-local.lua is saved",
	})
end

return M
