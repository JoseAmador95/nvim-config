-- lua/config/pager.lua
-- "Pager profile" for when this config is loaded by nvimpager.
--
-- nvimpager starts nvim with NVIM_APPNAME=nvimpager, so with the symlink
-- ~/.config/nvimpager -> ~/.config/nvim this same config runs, but we do NOT
-- want the full IDE weight (Mason installs, LSP, completion, 50+ plugins).
-- lua/config/lazy.lua checks M.active and, when true, loads only M.specs()
-- instead of `{ import = "plugins" }` -- an allowlist that is safe by default.
local M = {}

-- nvimpager exports NVIM_APPNAME=nvimpager before nvim starts (see the
-- nvimpager script). Available immediately in init.lua, no load-order caveats.
M.active = vim.env.NVIM_APPNAME == "nvimpager"

-- Treesitter parsers for the pager: markdown (required by render-markdown) plus
-- a common code set to highlight sources and ``` fenced blocks. Edit freely.
M.parsers = {
	"markdown",
	"markdown_inline",
	"bash",
	"c",
	"cpp",
	"lua",
	"python",
	"json",
	"yaml",
}

-- Minimal plugin allowlist for pager mode. Reuses the real plugin specs so the
-- theme/colors and render-markdown behavior match the editor exactly.
function M.specs()
	-- Reuse the snacks spec but drop its day-to-day picker keymaps
	-- (<leader>ff/fb/fh/u): those are editor-workflow bindings that make no sense
	-- over piped content. The picker engine still loads (needed by <leader>ft,
	-- added in M.setup).
	local snacks = {}
	for k, v in pairs(require("plugins.snacks")) do
		snacks[k] = v
	end
	snacks.keys = nil

	return {
		require("plugins.core"), -- plenary (dormant) + nvim-web-devicons
		require("plugins.colorscheme"), -- vscode.nvim theme (+ OSC11 bg detection)
		snacks, -- picker engine (used by :SetFileType) + UI niceties, no keymaps
		require("plugins.noice"), -- fancy command line / messages UI
		require("plugins.blink"), -- completion (cmdline/buffer/path; loads on demand)
		require("plugins.render-markdown"), -- activates on ft=markdown
		require("plugins.mermaid"), -- inline ASCII mermaid diagrams (mmdflux)
		{
			-- Slim treesitter: only M.parsers, no textobjects/context/rainbow and
			-- none of the 19-parser install from lua/plugins/treesitter.lua.
			"nvim-treesitter/nvim-treesitter",
			version = false,
			lazy = false,
			build = ":TSUpdate",
			config = function()
				require("nvim-treesitter").setup()
				require("nvim-treesitter").install(M.parsers, { summary = false })

				local installable = {}
				for _, lang in ipairs(M.parsers) do
					installable[lang] = true
				end

				vim.api.nvim_create_autocmd("FileType", {
					group = vim.api.nvim_create_augroup("PagerTreesitter", { clear = true }),
					callback = function(args)
						local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
							or vim.bo[args.buf].filetype
						if installable[lang] then
							pcall(vim.treesitter.start, args.buf, lang)
						end
					end,
				})
			end,
		},
	}
end

-- Explicit, opt-in filetype override for piped stdin (no content guessing).
-- nvimpager only auto-detects man/git/pydoc/perldoc/ri, so markdown coming from
-- a pipe has an empty filetype. Set NVIMPAGER_FILETYPE=markdown to force it,
-- e.g. `some-md-generator | NVIMPAGER_FILETYPE=markdown nvimpager`. Only applied
-- to buffers whose filetype ended up empty, so it never overrides detection.
function M.apply_stdin_filetype(buf)
	local ft = vim.env.NVIMPAGER_FILETYPE
	if ft and ft ~= "" and vim.bo[buf].filetype == "" then
		vim.bo[buf].filetype = ft
	end
end

-- Strip ANSI/OSC escape sequences left in the buffer text (from `gh`, git,
-- colored CLI output, ...). nvimpager only *conceals* them; when we switch to a
-- real filetype the conceal is dropped and the raw bytes show up as garbage, so
-- we remove them for good before rendering. Mirrors nvimpager's own stripping
-- and also handles OSC (e.g. OSC 8 hyperlinks) and other string sequences.
-- Exposed so `:SetFileType` (lua/config/viewer_commands.lua) can call it in
-- pager mode. Never call this in normal nvim: it would edit real file buffers.
function M.strip_ansi(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local changed = false
	for i, line in ipairs(lines) do
		local new = line
			:gsub("\27%[[%d;:?]*%a", "") -- CSI: colors, cursor moves, erase, ...
			:gsub("\27%].-\7", "") -- OSC ... BEL
			:gsub("\27%].-\27\\", "") -- OSC ... ST
			:gsub("\27[PX^_].-\27\\", "") -- DCS/SOS/PM/APC ... ST
		if new ~= line then
			changed = true
			lines[i] = new
		end
	end
	if changed then
		local modifiable = vim.bo[buf].modifiable
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = modifiable
		vim.bo[buf].modified = false
	end
end

-- Apply the chosen filetype to `win`'s (paged) buffer: strip ANSI, then set the
-- filetype directly. We target the buffer by handle (not the current buffer)
-- because the picker changed focus, and we set the option in Lua rather than via
-- the `:SetFileType` command string so a bad/edge filetype can't blow up inside
-- `nvim_exec2()` with an opaque, truncated error. Any failure is reported whole.
local function apply_filetype(win, ft)
	if not ft or ft == "" or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local ok, err = pcall(function()
		M.strip_ansi(buf)
		vim.bo[buf].filetype = ft
		-- Keep the paged buffer read-only: setting the filetype (and any ftplugin
		-- it triggers) can flip 'modifiable' back on, which would expose editing
		-- mappings that make no sense over piped content.
		vim.bo[buf].modifiable = false
		vim.bo[buf].modified = false
	end)
	if not ok then
		vim.notify("Set filetype failed: " .. tostring(err), vim.log.levels.ERROR, { title = "pager" })
	end
end

-- Pick a filetype with the snacks picker (falls back to vim.ui.select).
local function pick_filetype()
	local win = vim.api.nvim_get_current_win()
	local items = vim.fn.getcompletion("", "filetype")

	if not (Snacks and Snacks.picker and Snacks.picker.select) then
		vim.ui.select(items, { prompt = "Set filetype" }, function(choice)
			apply_filetype(win, choice)
		end)
		return
	end

	-- The shared snacks spec sets a global `confirm = "open_in_tab"`, which
	-- hijacks select's default confirm (a filetype item has no file, so nothing
	-- happens). Override confirm for this picker via `opts.snacks` and apply the
	-- filetype ourselves.
	Snacks.picker.select(items, {
		prompt = "Set filetype",
		snacks = {
			confirm = function(picker, item)
				picker:close()
				apply_filetype(win, item and item.item)
			end,
		},
	}, function() end)
end

-- nvimpager remaps j/k/<Up>/<Down> to scroll (see its runtime pager.lua
-- set_maps). Delete those buffer-local maps so they move the cursor again;
-- 'scrolloff' keeps context on screen. Scheduled so it runs AFTER nvimpager's
-- pager_mode has installed them. q/<Space>/<S-Space>/g stay as nvimpager set.
local function free_cursor_maps(buf)
	for _, lhs in ipairs({ "j", "k", "<Up>", "<Down>" }) do
		pcall(vim.keymap.del, "n", lhs, { buffer = buf })
	end
end

-- True if the buffer is displayed in a floating window. nvimpager's paged
-- content lives in a normal window, so any float is plugin UI (snacks picker
-- input, noice popup, blink menu, ...).
local function in_float(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			return true
		end
	end
	return false
end

-- Pager-only wiring. No-op outside nvimpager. Called from init.lua.
function M.setup()
	if not M.active then
		return
	end

	-- nvimpager registers `BufWinEnter *` -> pager_mode, which force-sets
	-- `modifiable=false` and pager scroll maps on EVERY buffer entering a
	-- window. That breaks plugin float inputs (e.g. the snacks picker: you
	-- can't type). Run after it (scheduled) and fix things up per buffer:
	--  - float (plugin UI): restore `modifiable` so its input accepts typing;
	--  - normal window (paged content): keep it read-only but free j/k/arrows
	--    so they move the cursor instead of scrolling.
	vim.api.nvim_create_autocmd({ "VimEnter", "BufWinEnter" }, {
		group = vim.api.nvim_create_augroup("PagerBufFixups", { clear = true }),
		callback = function(args)
			local buf = args.buf
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				if in_float(buf) then
					pcall(function()
						vim.bo[buf].modifiable = true
					end)
				else
					free_cursor_maps(buf)
				end
			end)
		end,
	})

	-- `:SetFileType` itself lives in viewer_commands.lua (shared); here we only
	-- add the pager-only picker keymap that drives it.
	vim.keymap.set("n", "<leader>ft", pick_filetype, { desc = "Set filetype (picker)" })
end

return M
