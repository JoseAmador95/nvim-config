-- lua/config/diagram.lua
-- Unified on-demand diagram viewer for mermaid and PlantUML. `:DiagramShow [svg|ascii]`
-- (default svg) renders the diagram under the cursor in a floating window:
--   svg   -> the rendered diagram as an image (fit to the float), Chromium-free
--            (mermaid: mmdflux -> rsvg-convert; plantuml: plantuml -tpng)
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
	plantuml = { svg = { "plantuml" }, ascii = { "plantuml" } },
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

-- A centered scratch float; q / <Esc> close it. Returns buf, width, height.
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
	return buf, width, height
end

local function cache_dir()
	local dir = vim.fn.stdpath("cache") .. "/diagram"
	vim.fn.mkdir(dir, "p")
	return dir
end

-- Render `src` to a PNG (async), calling cb(png) on success. Cached by hash.
local function to_png(kind, src, cb)
	local png = cache_dir() .. "/" .. vim.fn.sha256(kind .. ":" .. src) .. ".png"
	if vim.fn.filereadable(png) == 1 then
		cb(png)
		return
	end
	if kind == "mermaid" then
		vim.system({ "mmdflux", "-f", "svg" }, { text = true, stdin = src }, function(r)
			if r.code ~= 0 or not r.stdout or r.stdout == "" then
				vim.schedule(function()
					notify("mmdflux failed to render the diagram", vim.log.levels.ERROR)
				end)
				return
			end
			vim.system({ "rsvg-convert", "-f", "png", "-o", png }, { stdin = r.stdout }, function(r2)
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
		end)
	else
		vim.system({ "plantuml", "-tpng", "-pipe" }, { stdin = src }, function(r)
			if r.code ~= 0 then
				vim.schedule(function()
					local msg = vim.trim(r.stderr or "")
					notify(msg == "" and "plantuml failed" or msg, vim.log.levels.ERROR)
				end)
				return
			end
			vim.fn.writefile({ r.stdout or "" }, png, "b")
			vim.schedule(function()
				cb(png)
			end)
		end)
	end
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
	to_png(d.kind, d.src, function(png)
		local buf, width, height = make_float(d.kind .. " (svg)")
		Snacks.image.placement.new(buf, png, {
			inline = true,
			pos = { 1, 0 },
			max_width = width,
			max_height = height,
			auto_resize = true,
		})
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
