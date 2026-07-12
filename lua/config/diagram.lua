-- lua/config/diagram.lua
-- Unified on-demand diagram viewer for mermaid and PlantUML. `:DiagramShow [svg|ascii]`
-- (default svg) renders the diagram under the cursor in a floating window:
--   svg   -> the rendered diagram as an image (fit to the float), Chromium-free
--            (mermaid: mmdflux -> rsvg-convert; plantuml: plantuml -tsvg -> rsvg-convert)
--            zoom/pan in the float: h/j/k/l pan, +/_ (or =/-) zoom, 0 resets to
--            fit, q/<Esc> close. Zoom re-rasterizes an SVG viewBox sub-region, so
--            it stays crisp at any level.
--   ascii -> the diagram as text (mermaid: mmdflux; plantuml: plantuml -ttxt)
-- svg falls back to ascii when the terminal can't display images or an image
-- dependency is missing; any missing dependency is announced (with its install
-- command) via a notification, so nothing fails silently.
local M = {}

local blocks = require("config.diagram_blocks")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Diagram" })
end

-- Fenced-code language -> diagram kind.
local LANGS = { mermaid = "mermaid", plantuml = "plantuml", puml = "plantuml", uml = "plantuml" }

-- Manual install command per external tool (announced when missing).
local INSTALL = {
	mmdflux = "cargo install mmdflux",
	["rsvg-convert"] = "brew install librsvg",
	plantuml = "brew install plantuml",
}

-- External tools required per kind and mode.
local DEPS = {
	mermaid = { svg = { "mmdflux", "rsvg-convert" }, ascii = { "mmdflux" } },
	plantuml = { svg = { "plantuml", "rsvg-convert" }, ascii = { "plantuml" } },
}

local function missing(kind, mode)
	local out = {}
	for _, exe in ipairs(DEPS[kind][mode]) do
		if vim.fn.executable(exe) ~= 1 then
			out[#out + 1] = exe
		end
	end
	return out
end

local function install_hint(list)
	local h = {}
	for _, exe in ipairs(list) do
		h[#h + 1] = INSTALL[exe] or ("install " .. exe)
	end
	return table.concat(h, "; ")
end

local function image_terminal_ok()
	return Snacks ~= nil
		and Snacks.image ~= nil
		and Snacks.image.supports_terminal ~= nil
		and Snacks.image.supports_terminal()
end

local function whole_buffer(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- The diagram under the cursor: { kind, src } or nil. In a plantuml buffer or a
-- non-markdown buffer the whole buffer is the source; in markdown it's the fenced
-- block under the cursor.
local function detect(buf)
	local ft = vim.bo[buf].filetype
	if ft == "plantuml" then
		return { kind = "plantuml", src = whole_buffer(buf) }
	end
	if ft ~= "markdown" then
		return { kind = "mermaid", src = whole_buffer(buf) }
	end
	local set = {}
	for k in pairs(LANGS) do
		set[k] = true
	end
	local b = blocks.under_cursor(buf, set)
	if not b then
		return nil
	end
	return { kind = LANGS[b.lang], src = b.src }
end

-- A centered scratch float; q / <Esc> close it. Returns buf, width, height, win.
local function make_float(title)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local width = math.floor(vim.o.columns * 0.9)
	local height = math.floor(vim.o.lines * 0.9)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "Close diagram" })
	end
	return buf, width, height, win
end

local function cache_dir()
	local dir = vim.fn.stdpath("cache") .. "/diagram"
	vim.fn.mkdir(dir, "p")
	return dir
end

-- Parse the root <svg> element's intrinsic geometry, in the SVG's user units:
-- ox, oy, w, h taken from `viewBox` (falling back to `width`/`height`). Returns
-- nil when neither is present, in which case zoom/pan is disabled.
local function svg_dims(svg)
	local root = svg:match("<svg[^>]*>") or svg
	local ox, oy, w, h = root:match('viewBox="%s*(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
	if w then
		return tonumber(ox), tonumber(oy), tonumber(w), tonumber(h)
	end
	local ws = root:match('width="(%-?[%d%.]+)')
	local hs = root:match('height="(%-?[%d%.]+)')
	if ws and hs then
		return 0, 0, tonumber(ws), tonumber(hs)
	end
	return nil
end

-- SVG text is generated once per (kind, src) and reused for every zoom/pan view.
local svg_cache = {}

-- Render `src` to its SVG once, parse the root geometry, and cache it. Calls
-- cb({ svg, ox, oy, w, h, kind, src }) on success; w/h are nil when the SVG
-- exposes no size (zoom disabled). mermaid -> mmdflux, plantuml -> plantuml -tsvg.
local function to_svg(kind, src, cb)
	local ckey = kind .. "\0" .. src
	if svg_cache[ckey] then
		cb(svg_cache[ckey])
		return
	end
	local svg_cmd = kind == "mermaid" and { "mmdflux", "-f", "svg" } or { "plantuml", "-tsvg", "-pipe" }
	local tool = kind == "mermaid" and "mmdflux" or "plantuml"
	vim.system(svg_cmd, { text = true, stdin = src }, function(r)
		if r.code ~= 0 or not r.stdout or r.stdout == "" then
			vim.schedule(function()
				local msg = vim.trim(r.stderr or "")
				notify(msg == "" and (tool .. " failed to render the diagram") or msg, vim.log.levels.ERROR)
			end)
			return
		end
		local ox, oy, w, h = svg_dims(r.stdout)
		local info = { svg = r.stdout, ox = ox, oy = oy, w = w, h = h, kind = kind, src = src }
		svg_cache[ckey] = info
		vim.schedule(function()
			cb(info)
		end)
	end)
end

-- Rasterize a view of the SVG to a PNG (async) at `target` ({ width, height } in
-- pixels), calling cb(png) on success. `view` is a { x, y, w, h } sub-region in
-- SVG user units (zoom/pan, whose aspect equals `target`'s) or nil to fit the
-- whole diagram. We rewrite only the root `viewBox` -- rsvg maps it onto the
-- exact -w/-h output -- so every zoom level is re-rasterized from vector and
-- stays crisp. For a view we must NOT pass --keep-aspect-ratio: rsvg would then
-- honor the SVG's *intrinsic* width/height (the diagram's aspect) instead of the
-- viewBox, breaking the fill. The whole-diagram fallback keeps aspect and fills
-- the box (Snacks only scales down, so a small render would otherwise show tiny).
-- The PNG path is content-addressed (kind + target + view + src): distinct views
-- never collide and Snacks' path-keyed image cache stays correct; rsvg writes it.
local function render_view(info, view, target, cb)
	local vk = view and ("%g,%g,%g,%g"):format(view.x, view.y, view.w, view.h) or "full"
	local key = ("%s:%dx%d:%s:%s"):format(info.kind, target.width, target.height, vk, info.src)
	local png = cache_dir() .. "/" .. vim.fn.sha256(key) .. ".png"
	if vim.fn.filereadable(png) == 1 then
		cb(png)
		return
	end
	local svg = info.svg
	local cmd = { "rsvg-convert", "-f", "png", "-w", tostring(target.width), "-h", tostring(target.height) }
	if view then
		svg = svg:gsub('viewBox="[^"]*"', ('viewBox="%g %g %g %g"'):format(view.x, view.y, view.w, view.h), 1)
	else
		cmd[#cmd + 1] = "--keep-aspect-ratio"
	end
	cmd[#cmd + 1] = "-o"
	cmd[#cmd + 1] = png
	vim.system(cmd, { stdin = svg }, function(r2)
		if r2.code == 0 and vim.fn.filereadable(png) == 1 then
			vim.schedule(function()
				cb(png)
			end)
		else
			vim.schedule(function()
				notify("rsvg-convert failed to rasterize the SVG", vim.log.levels.ERROR)
			end)
		end
	end)
end

-- Render `src` to ASCII lines (async), calling cb(lines) on success.
local function to_text(kind, src, cb)
	local cmd = kind == "mermaid" and { "mmdflux" } or { "plantuml", "-ttxt", "-pipe" }
	vim.system(cmd, { text = true, stdin = src }, function(r)
		if r.code ~= 0 then
			vim.schedule(function()
				local msg = vim.trim((r.stderr or "") .. "\n" .. (r.stdout or ""))
				notify(msg == "" and "diagram render failed" or msg, vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			cb(vim.split(r.stdout or "", "\n", { plain = true }))
		end)
	end)
end

local function show_svg(d)
	-- Rasterize to the float's pixel size so the diagram fills it. The float is
	-- 90% of the editor (see make_float); a terminal cell is cell_width x
	-- cell_height pixels per Snacks' probe.
	local cols = math.floor(vim.o.columns * 0.9)
	local rows = math.floor(vim.o.lines * 0.9)
	local term = Snacks.image.terminal.size()
	local size = {
		width = math.floor(cols * term.cell_width),
		height = math.floor(rows * term.cell_height),
	}

	to_svg(d.kind, d.src, function(info)
		-- Fill zoom/pan state. The visible region has the float's *display aspect*
		-- (AF) rather than the diagram's, so the zoomed image uses the WHOLE float;
		-- panning moves that window over the diagram. Disabled when the SVG has no
		-- parseable size. `z` is the zoom factor (1 = whole diagram fits); `cx,cy`
		-- the view center in SVG user units.
		local can_zoom = info.w and info.h and info.w > 0 and info.h > 0
		local ZMIN, ZMAX, ZSTEP, PAN = 1, 8, 1.25, 0.2
		local z, cx, cy = 1, (info.w or 0) / 2, (info.h or 0) / 2

		-- Fill target = the reserved image area (full width x height-2 rows, see
		-- place()) in pixels; its aspect AF drives the visible region. The base
		-- region at z=1 is the smallest AF-aspect box containing the diagram
		-- (letterboxed with the SVG's background at fit).
		local disp = { width = size.width, height = math.max(1, size.height - 2 * term.cell_height) }
		local AF = disp.width / disp.height
		local bw, bh
		if can_zoom then
			if info.w / info.h < AF then
				bh, bw = info.h, info.h * AF
			else
				bw, bh = info.w, info.w / AF
			end
		end

		local function clamp(v, lo, hi)
			return math.min(math.max(v, lo), hi)
		end
		-- Per axis: if the region is larger than the diagram, center it (whole
		-- diagram visible with margins); otherwise clamp so it stays inside.
		local function clamp_center()
			local w, h = bw / z, bh / z
			cx = w >= info.w and info.w / 2 or clamp(cx, w / 2, info.w - w / 2)
			cy = h >= info.h and info.h / 2 or clamp(cy, h / 2, info.h - h / 2)
		end
		local function view()
			local w, h = bw / z, bh / z
			return { x = info.ox + (cx - w / 2), y = info.oy + (cy - h / 2), w = w, h = h }
		end

		-- Render the first view, then build the float around it so it appears with
		-- the image already in place.
		render_view(info, can_zoom and view() or nil, can_zoom and disp or size, function(png)
			local buf, width, height, win = make_float(d.kind .. " (svg)")
			local placement
			local rendering, dirty = false, false

			-- Center the current PNG in the float and (re)create the placement.
			-- Snacks fits the image preserving aspect and only scales down; it also
			-- renders it as virtual lines *below* an anchor line and Neovim drops the
			-- last one when it hits the window's bottom row, so reserve two rows (the
			-- anchor above + one slack below) via `height - 2` and max_height. The
			-- left margin is the placement column, which Snacks turns into per-line
			-- indentation; the top margin is padded with blank lines.
			local function place(image)
				local box_h = math.max(1, height - 2)
				local dim = Snacks.image.util.dim(image)
				local aspect = (dim.width * term.cell_height) / (dim.height * term.cell_width)
				local iw, ih
				if aspect > width / box_h then
					iw, ih = width, math.floor(width / aspect)
				else
					iw, ih = math.floor(box_h * aspect), box_h
				end
				local top = math.max(1, math.floor((height - ih) / 2))
				local left = math.max(0, math.floor((width - iw) / 2))
				local pad = {}
				for _ = 1, top do
					pad[#pad + 1] = ""
				end
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, pad)
				vim.bo[buf].modifiable = false
				if placement then
					pcall(function()
						placement:close()
					end)
				end
				placement = Snacks.image.placement.new(buf, image, {
					inline = true,
					pos = { top, left },
					max_width = width,
					max_height = box_h,
					auto_resize = true,
				})
			end

			local function update_title()
				local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
				if not ok then
					return
				end
				cfg.title = can_zoom and (" %s (svg) · %d%% "):format(d.kind, math.floor(z * 100 + 0.5))
					or (" " .. d.kind .. " (svg) ")
				cfg.title_pos = "center"
				pcall(vim.api.nvim_win_set_config, win, cfg)
			end

			-- Re-render the current view, coalescing rapid key presses: if a render
			-- is already in flight, mark dirty and render once more when it lands.
			local function rerender()
				if not vim.api.nvim_win_is_valid(win) then
					return
				end
				if rendering then
					dirty = true
					return
				end
				rendering = true
				update_title()
				render_view(info, can_zoom and view() or nil, can_zoom and disp or size, function(image)
					rendering = false
					if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
						return
					end
					place(image)
					if dirty then
						dirty = false
						rerender()
					end
				end)
			end

			place(png)
			update_title()

			-- Close the image when the float is dismissed (q/<Esc> wipe the buffer).
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = buf,
				once = true,
				callback = function()
					if placement then
						pcall(function()
							placement:close()
						end)
					end
				end,
			})

			if can_zoom then
				local function zoom(factor)
					z = clamp(z * factor, ZMIN, ZMAX)
					clamp_center()
					rerender()
				end
				local function pan(dx, dy)
					cx = cx + dx * (bw / z) * PAN
					cy = cy + dy * (bh / z) * PAN
					clamp_center()
					rerender()
				end
				local maps = {
					h = function() pan(-1, 0) end,
					l = function() pan(1, 0) end,
					k = function() pan(0, -1) end,
					j = function() pan(0, 1) end,
					["+"] = function() zoom(ZSTEP) end,
					["="] = function() zoom(ZSTEP) end,
					["_"] = function() zoom(1 / ZSTEP) end,
					["-"] = function() zoom(1 / ZSTEP) end,
					["0"] = function()
						z, cx, cy = 1, info.w / 2, info.h / 2
						rerender()
					end,
				}
				for lhs, fn in pairs(maps) do
					vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Diagram zoom/pan" })
				end
			end
		end)
	end)
end

local function show_ascii(d)
	to_text(d.kind, d.src, function(lines)
		local buf = make_float(d.kind .. " (ascii)")
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end)
end

-- mode: "svg" (default) | "ascii". svg falls back to ascii when unavailable.
function M.show(mode)
	mode = mode or "svg"
	local d = detect(vim.api.nvim_get_current_buf())
	if not d then
		notify("No mermaid/plantuml diagram under the cursor", vim.log.levels.WARN)
		return
	end

	if mode == "svg" then
		local reason
		if not image_terminal_ok() then
			reason = "the terminal has no inline image support (needs the Kitty graphics protocol)"
		else
			local miss = missing(d.kind, "svg")
			if #miss > 0 then
				reason = "missing " .. table.concat(miss, ", ") .. " (install: " .. install_hint(miss) .. ")"
			end
		end
		if reason then
			notify("SVG unavailable: " .. reason .. ". Falling back to ASCII.", vim.log.levels.WARN)
			mode = "ascii"
		end
	end

	if mode == "ascii" then
		local miss = missing(d.kind, "ascii")
		if #miss > 0 then
			notify(
				("Cannot render %s as ASCII: missing %s (install: %s)"):format(
					d.kind,
					table.concat(miss, ", "),
					install_hint(miss)
				),
				vim.log.levels.ERROR
			)
			return
		end
		show_ascii(d)
	else
		show_svg(d)
	end
end

function M.setup()
	if vim.g.vscode then
		return
	end

	vim.api.nvim_create_user_command("DiagramShow", function(o)
		local mode = vim.trim(o.args or "")
		if mode == "" then
			mode = nil
		end
		if mode and mode ~= "svg" and mode ~= "ascii" then
			notify("usage: :DiagramShow [svg|ascii]", vim.log.levels.WARN)
			return
		end
		M.show(mode)
	end, {
		nargs = "?",
		complete = function()
			return { "svg", "ascii" }
		end,
		desc = "Show diagram under cursor (svg default, ascii fallback)",
	})

	-- In the pager the content buffer is often not a 'markdown'/'plantuml'
	-- filetype (piped output, man pages, ...), so bind <leader>md globally to keep
	-- it available on whatever is being viewed. In the editor keep it buffer-local
	-- to diagram filetypes.
	if require("config.pager").active then
		vim.keymap.set("n", "<leader>md", "<cmd>DiagramShow<cr>", { desc = "Show diagram (SVG/ASCII)" })
		return
	end

	local function map(buf)
		vim.keymap.set("n", "<leader>md", "<cmd>DiagramShow<cr>", { buffer = buf, desc = "Show diagram (SVG/ASCII)" })
	end
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown", "plantuml" },
		group = vim.api.nvim_create_augroup("DiagramKeymaps", { clear = true }),
		callback = function(a)
			map(a.buf)
		end,
	})
	-- Cover diagram buffers already loaded before setup ran.
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			local ft = vim.bo[b].filetype
			if ft == "markdown" or ft == "plantuml" then
				map(b)
			end
		end
	end
end

return M
