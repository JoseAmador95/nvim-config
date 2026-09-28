-- lua/config/pager.lua
-- "Pager profile" for when this config is loaded by nvimpager.
--
-- nvimpager starts nvim with NVIM_APPNAME=nvimpager, so with the symlink
-- ~/.config/nvimpager -> ~/.config/nvim this same config runs, but we do NOT
-- want the full IDE weight (Mason installs, LSP, completion, 50+ plugins).
-- lua/config/lazy.lua checks M.active and, when true, loads only M.specs()
-- instead of `{ import = "plugins" }` -- an allowlist that is safe by default.
local M = {}
local markdown_view

local MAX_STRIP_BYTES = 64 * 1024 * 1024
local STRIP_CHUNK_BYTES = 256 * 1024

-- nvimpager exports NVIM_APPNAME=nvimpager before nvim starts (see the
-- nvimpager script). Available immediately in init.lua, no load-order caveats.
M.active = vim.env.NVIM_APPNAME == "nvimpager"

-- Treesitter parsers for the pager: markdown source plus
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
-- theme/colors and the same reading renderer as the editor.
function M.specs()
	-- Reuse the snacks spec but drop its day-to-day picker keymaps
	-- (<leader>ff/fb/fh/u): those are editor-workflow bindings that make no sense
	-- over piped content. The picker engine still loads (needed by <leader>ft,
	-- added in M.setup).
	local snacks = vim.deepcopy(require("plugins.snacks"))
	snacks.keys = nil
	snacks.opts.dashboard.enabled = false
	snacks.opts.terminal.enabled = false
	snacks.opts.scratch.enabled = false

	return {
		require("plugins.core"), -- plenary (dormant) + nvim-web-devicons
		require("plugins.colorscheme"), -- VSCode/Catppuccin themes (+ OSC11 bg detection)
		snacks, -- picker engine used by :SetFileType; no editor keymaps
		require("plugins.md-render"), -- read-only document view
		{
			-- Slim treesitter: only already-installed M.parsers, with no implicit
			-- network work and no textobjects/context/rainbow.
			"nvim-treesitter/nvim-treesitter",
			version = false,
			lazy = false,
			config = function()
				require("nvim-treesitter").setup()
				require("config.treesitter_runtime").setup({
					profile = "pager",
					parsers = M.parsers,
					highlight = true,
					indent = false,
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
local function current_buffer_bytes(buf)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local ok, bytes = pcall(vim.api.nvim_buf_get_offset, buf, line_count)
	if not ok or type(bytes) ~= "number" or bytes < 0 then
		return nil, "Could not measure current pager contents: " .. tostring(bytes)
	end
	return bytes, line_count
end

local function stripped_contents(buf, line_count)
	local output = {}
	local pending = {}
	local pending_bytes = 0
	local mode = "text"
	local osc = false
	local changed = false

	local function flush()
		if pending_bytes > 0 then
			output[#output + 1] = table.concat(pending)
			pending = {}
			pending_bytes = 0
		end
	end

	local function append(value)
		if value == "" then
			return
		end
		pending[#pending + 1] = value
		pending_bytes = pending_bytes + #value
		if pending_bytes >= STRIP_CHUNK_BYTES then
			flush()
		end
	end

	local function feed(chunk)
		local index = 1
		while index <= #chunk do
			if mode == "text" then
				local escape = chunk:find("\27", index, true)
				if not escape then
					append(chunk:sub(index))
					break
				end
				append(chunk:sub(index, escape - 1))
				changed = true
				mode = "escape"
				index = escape + 1
			elseif mode == "escape" then
				local byte = chunk:byte(index)
				index = index + 1
				if byte == 91 then -- CSI: ESC [
					mode = "csi"
				elseif byte == 93 then -- OSC: ESC ]
					mode = "string"
					osc = true
				elseif byte == 80 or byte == 88 or byte == 94 or byte == 95 then -- DCS/SOS/PM/APC
					mode = "string"
					osc = false
				else
					mode = "text"
				end
			elseif mode == "csi" then
				local byte = chunk:byte(index)
				index = index + 1
				if byte >= 64 and byte <= 126 then
					mode = "text"
				end
			elseif mode == "string" then
				local byte = chunk:byte(index)
				index = index + 1
				if osc and byte == 7 then
					mode = "text"
				elseif byte == 27 then
					mode = "string_escape"
				end
			else -- string_escape
				local byte = chunk:byte(index)
				index = index + 1
				if byte == 92 or (osc and byte == 7) then
					mode = "text"
				elseif byte ~= 27 then
					mode = "string"
				end
			end
		end
	end

	for row = 0, line_count - 1 do
		local ok_start, start_offset = pcall(vim.api.nvim_buf_get_offset, buf, row)
		local ok_finish, finish_offset = pcall(vim.api.nvim_buf_get_offset, buf, row + 1)
		if not ok_start or not ok_finish then
			return nil, "Could not locate current pager contents"
		end
		local line_bytes = finish_offset - start_offset - 1
		if line_bytes < 0 then
			return nil, "Pager buffer offsets are inconsistent"
		end
		local column = 0
		while column < line_bytes do
			local finish = math.min(column + STRIP_CHUNK_BYTES, line_bytes)
			local ok, parts = pcall(vim.api.nvim_buf_get_text, buf, row, column, row, finish, {})
			if not ok or type(parts) ~= "table" or type(parts[1]) ~= "string" then
				return nil, "Could not read current pager contents: " .. tostring(parts)
			end
			feed(parts[1])
			column = finish
		end
		if row < line_count - 1 then
			feed("\n")
		end
	end
	flush()
	return table.concat(output), changed
end

function M.strip_ansi(buf)
	buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
		return nil, "Pager buffer is invalid or unloaded"
	end
	local bytes, line_count_or_err = current_buffer_bytes(buf)
	if not bytes then
		return nil, line_count_or_err
	end
	if bytes > MAX_STRIP_BYTES then
		return nil, ("Pager contents exceed the %d MiB stripping limit"):format(MAX_STRIP_BYTES / 1024 / 1024)
	end
	local contents, changed_or_err = stripped_contents(buf, line_count_or_err)
	if not contents then
		return nil, changed_or_err
	end
	if not changed_or_err then
		return true
	end

	local modifiable = vim.bo[buf].modifiable
	local modified = vim.bo[buf].modified
	local ok, set_err = pcall(function()
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(contents, "\n", { plain = true }))
	end)
	local modified_ok, modified_err = pcall(function()
		vim.bo[buf].modified = modified
	end)
	local modifiable_ok, modifiable_err = pcall(function()
		vim.bo[buf].modifiable = modifiable
	end)
	if not modified_ok or not modifiable_ok then
		return nil, "Could not restore pager buffer state: " .. tostring(modified_err or modifiable_err)
	end
	if not ok then
		return nil, "Could not strip pager escapes: " .. tostring(set_err)
	end
	return true
end

-- Apply the chosen filetype to `win`'s (paged) buffer: strip ANSI, then set the
-- filetype directly. We target the buffer by handle (not the current buffer)
-- because the picker changed focus, and we set the option in Lua rather than via
-- the `:SetFileType` command string so a bad/edge filetype can't blow up inside
-- `nvim_exec2()` with an opaque, truncated error. Any failure is reported whole.
local function apply_filetype(win, ft)
	if not ft or ft == "" or not vim.api.nvim_win_is_valid(win) then
		return nil, "Filetype or pager window is invalid"
	end
	if markdown_view and not markdown_view.pager_show_source(win) then
		return nil, "Pager source buffer is unavailable"
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local stripped, strip_err = M.strip_ansi(buf)
	if not stripped then
		vim.notify("Set filetype failed: " .. tostring(strip_err), vim.log.levels.ERROR, { title = "pager" })
		return nil, strip_err
	end
	local ok, err = pcall(function()
		vim.bo[buf].filetype = ft
		-- Keep the paged buffer read-only: setting the filetype (and any ftplugin
		-- it triggers) can flip 'modifiable' back on, which would expose editing
		-- mappings that make no sense over piped content.
		vim.bo[buf].modifiable = false
		vim.bo[buf].modified = false
	end)
	if not ok then
		vim.notify("Set filetype failed: " .. tostring(err), vim.log.levels.ERROR, { title = "pager" })
		return nil, tostring(err)
	end
	if markdown_view then
		markdown_view.pager_filetype_changed(buf)
	end
	return true
end

function M.set_markdown_view(view)
	markdown_view = view
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
-- content lives in a normal window, so any float belongs to Snacks UI.
local function in_float(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			return true
		end
	end
	return false
end

-- nvimpager's blanket read-only handling needs to be undone only for real input
-- buffers. Result/list/preview floats manage their own mutability and must stay
-- read-only; Snacks input can briefly be identified by either option below.
function M.is_input_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	return vim.bo[buf].buftype == "prompt" or vim.bo[buf].filetype == "snacks_picker_input"
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
	--  - prompt/input float: restore `modifiable` so it accepts typing;
	--  - result/list/preview float: leave its own mutability policy untouched;
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
				if in_float(buf) and M.is_input_buffer(buf) then
					pcall(function()
						vim.bo[buf].modifiable = true
					end)
				elseif not in_float(buf) then
					free_cursor_maps(buf)
				end
			end)
		end,
	})

	-- `:SetFileType` itself lives in viewer_commands.lua (shared); here we only
	-- add the pager-only picker keymap that drives it.
	vim.keymap.set("n", "<leader>ft", pick_filetype, { desc = "Set filetype (picker)" })
end

M.MAX_STRIP_BYTES = MAX_STRIP_BYTES
M._apply_filetype = apply_filetype

return M
