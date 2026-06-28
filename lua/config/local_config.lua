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
--     obsidian = {               -- list of vaults
--       { name = "personal", path = "~/Obsidian" },
--     },
--     clangd = { path = "clangd" },
--     path = { "~/bin" },          -- dirs prepended to $PATH
--     env = { FOO = "bar" },       -- environment variables to export
--     plugins_dir = { "~/.nvim-plugins" }, -- dirs of extra lazy.nvim specs
--   }
--
-- Override the host path with $NVIM_CONFIG_FILE (for testing).

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
	obsidian = {
		type = "list",
		default = {},
		item = {
			type = "table",
			fields = {
				name = { type = "string", required = true },
				path = { type = "string", required = true },
			},
		},
	},
	clangd = {
		type = "table",
		fields = {
			path = { type = "string", default = "clangd" },
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
	return result, result and "loaded" or "error"
end

-- Deep merge --------------------------------------------------------------

local function is_array(t)
	if type(t) ~= "table" then
		return false
	end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
		n = n + 1
	end
	return n > 0
end

local function deep_merge(base, override)
	if type(base) ~= "table" or type(override) ~= "table" then
		return override
	end
	-- Lists replace wholesale; we don't merge vault lists element-by-element.
	if is_array(base) or is_array(override) then
		return override
	end
	local out = {}
	for k, v in pairs(base) do
		out[k] = v
	end
	for k, v in pairs(override) do
		out[k] = deep_merge(out[k], v)
	end
	return out
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
	return value
end

-- Compute -----------------------------------------------------------------

local function compute()
	sources = {}
	last_errors = {}

	local home = home_path()
	local host_cfg, host_status = load_host(home)
	sources[#sources + 1] = { path = home, status = host_status }
	local merged = host_cfg or {}

	local project = project_path()
	if project ~= home then
		local proj_cfg, proj_status = load_project(project)
		sources[#sources + 1] = { path = project, status = proj_status }
		if proj_cfg then
			merged = deep_merge(merged, proj_cfg)
		end
	end

	local validated = validate_fields(SCHEMA, merged, "", last_errors)
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
	return cache
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

-- Prepend a directory to $PATH (idempotent), mirroring init.lua's prepend_path.
local function prepend_path(dir)
	dir = vim.fn.expand(dir)
	if dir == "" then
		return
	end
	local current = vim.env.PATH or ""
	if not string.find(current, dir, 1, true) then
		vim.env.PATH = dir .. ":" .. current
	end
end

-- Apply $PATH and environment overrides. Call early in init.lua so they are in
-- place before plugins/mason rely on them.
function M.apply_env()
	local cfg = M.read()
	for _, dir in ipairs(cfg.path or {}) do
		prepend_path(dir)
	end
	for key, value in pairs(cfg.env or {}) do
		vim.env[key] = value
	end
end

-- Introspection for :NvimConfigDump and :checkhealth.
function M.sources()
	M.read()
	return sources
end

function M.errors()
	M.read()
	return last_errors
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

  -- Obsidian vaults. Paths are expanded (~ and env vars).
  obsidian = {
    -- { name = "personal", path = "~/Obsidian" },
  },

  -- Override the clangd binary on this host.
  clangd = { path = "clangd" },

  -- Directories prepended to $PATH (expanded).
  path = {
    -- "~/bin",
  },

  -- Environment variables exported on startup.
  env = {
    -- PKG_CONFIG_PATH = "/opt/x/lib/pkgconfig",
    -- AI (CodeCompanion via Claude subscription): token from `claude setup-token`.
    -- CLAUDE_CODE_OAUTH_TOKEN = "sk-ant-oat...",
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
		local cfg = M.read()
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
		notify("Local config reloaded", vim.log.levels.INFO)
	end, { desc = "Reload the local config" })

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
