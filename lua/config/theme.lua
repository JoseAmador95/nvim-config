-- lua/config/theme.lua
-- Colorscheme ownership: the picker chooses, and the choice persists.
--
-- Two files, deliberately split:
--
--   lua/config/theme_default.lua  -- versioned; what a fresh clone starts on
--   lua/localconfig/theme.lua     -- gitignored; what THIS machine is on now
--
-- The gitignored file wins whenever it is present, so a per-machine choice
-- never shows up as a dirty working tree. It does not exist until the first
-- selection: until then the versioned default is what runs. Neither file is
-- required — a missing or malformed one falls back rather than breaking
-- startup, the same rule config.local_config follows.
--
-- WHO PAINTS. A colorscheme that needs more than `:colorscheme <name>` (an
-- explicit setup() call, a light/dark variant to pick) registers a painter
-- here with M.register. Everything else is applied with a plain
-- `:colorscheme`. This is what lets the background follow the terminal
-- without this module knowing anything about any particular theme:
-- lua/plugins/colorscheme.lua registers the vscode painter and drives OSC 11
-- detection, then calls M.repaint() and lets the SELECTED theme answer.

local M = {}

local TITLE = "nvim.theme"
local STATE_MODULE = "localconfig.theme"
local DEFAULT_MODULE = "config.theme_default"

-- Ships with Neovim, so it cannot itself be missing. Only reached if both the
-- local and the versioned file are gone or broken.
local FALLBACK = "habamax"

local painters = {}
local cache = nil

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.WARN, { title = TITLE })
end

local function state_path()
	return vim.fs.joinpath(vim.fn.stdpath("config"), "lua", "localconfig", "theme.lua")
end

-- Load one of the two selection files. `require` is used (rather than reading
-- the path) so the runtimepath rules stay the same as the rest of the config;
-- the cache is dropped first so a rewrite during the session is picked up.
local function load_selection(module)
	package.loaded[module] = nil
	local ok, value = pcall(require, module)
	if not ok or type(value) ~= "table" or type(value.colorscheme) ~= "string" then
		return nil
	end
	return { colorscheme = value.colorscheme }
end

-- Public API ---------------------------------------------------------------

--- Register a painter for a colorscheme that needs more than `:colorscheme`.
--- The painter receives the current 'background' ("light" | "dark") and is
--- responsible for applying the colorscheme itself.
---@param name string colorscheme name
---@param fn fun(background: string)
function M.register(name, fn)
	painters[name] = fn
end

--- The effective selection: local file, else versioned default, else fallback.
---@return { colorscheme: string }
function M.selection()
	if cache == nil then
		cache = load_selection(STATE_MODULE) or load_selection(DEFAULT_MODULE) or { colorscheme = FALLBACK }
	end
	return cache
end

--- Apply a colorscheme without persisting it. Returns false (and warns) if the
--- colorscheme is not installed, so callers can fall back.
---@param name string
---@return boolean applied
function M.apply(name)
	local painter = painters[name]
	if painter then
		local ok, err = pcall(painter, vim.o.background)
		if not ok then
			notify("Painter for '" .. name .. "' failed: " .. tostring(err))
			return false
		end
		return true
	end
	if not pcall(vim.cmd.colorscheme, name) then
		notify("Colorscheme '" .. name .. "' is not installed")
		return false
	end
	return true
end

--- Re-apply whatever is currently selected. Called on startup and on every
--- 'background' change, which is how a light/dark flip reaches a theme with a
--- registered painter.
function M.repaint()
	local name = M.selection().colorscheme
	if M.apply(name) then
		return
	end
	-- The selected theme is gone (uninstalled, renamed). Try the versioned
	-- default, then the built-in, so a session never lands with no colorscheme.
	local default = load_selection(DEFAULT_MODULE)
	if default and default.colorscheme ~= name and M.apply(default.colorscheme) then
		return
	end
	M.apply(FALLBACK)
end

--- Write the machine-local selection. Creates lua/localconfig/ if needed.
---@param name string
---@return boolean written
function M.save(name)
	local path = state_path()
	local ok_dir = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
	if not ok_dir then
		notify("Could not create " .. vim.fs.dirname(path), vim.log.levels.ERROR)
		return false
	end
	local lines = {
		"-- lua/localconfig/theme.lua -- machine-local theme selection.",
		"-- Written by :Theme. NOT under version control; see .gitignore.",
		"-- The versioned starting point lives in lua/config/theme_default.lua,",
		"-- and :ThemeReset deletes this file to come back to it.",
		"",
		"return {",
		string.format("\tcolorscheme = %q,", name),
		"}",
	}
	local ok, err = pcall(vim.fn.writefile, lines, path)
	if not ok then
		notify("Could not write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	cache = { colorscheme = name }
	package.loaded[STATE_MODULE] = nil
	return true
end

--- Apply a colorscheme and persist it. Nothing is written if it fails to
--- apply, so a typo cannot leave the config pointing at a missing theme.
---@param name string
function M.select(name)
	if not M.apply(name) then
		return
	end
	if M.save(name) then
		notify("Theme set to " .. name, vim.log.levels.INFO)
	end
end

--- Discard the machine-local selection and go back to the versioned default.
function M.reset()
	local path = state_path()
	if vim.fn.filereadable(path) == 1 then
		local ok, err = pcall(vim.fn.delete, path)
		if not ok then
			notify("Could not delete " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
			return
		end
	end
	cache = nil
	package.loaded[STATE_MODULE] = nil
	M.repaint()
	notify("Theme reset to " .. M.selection().colorscheme, vim.log.levels.INFO)
end

--- Pick a colorscheme interactively. Uses snacks.picker when available, which
--- previews each theme live as the cursor moves; falls back to vim.ui.select
--- so the command still works if snacks is not loaded.
function M.pick()
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks and snacks.picker then
		snacks.picker.colorschemes({
			confirm = function(picker, item)
				picker:close()
				if not item then
					return
				end
				-- Stop the previewer from restoring the pre-picker colorscheme
				-- on close; upstream's own confirm does exactly this.
				picker.preview.state.colorscheme = nil
				vim.schedule(function()
					M.select(item.text)
				end)
			end,
		})
		return
	end
	vim.ui.select(vim.fn.getcompletion("", "color"), { prompt = "Colorscheme" }, function(choice)
		if choice then
			M.select(choice)
		end
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("Theme", function(opts)
		if opts.args ~= "" then
			M.select(opts.args)
			return
		end
		M.pick()
	end, {
		nargs = "?",
		complete = "color",
		desc = "Pick a colorscheme (or set one by name) and persist it",
	})

	vim.api.nvim_create_user_command("ThemeReset", function()
		M.reset()
	end, { desc = "Drop the local theme selection and use the versioned default" })
end

return M
