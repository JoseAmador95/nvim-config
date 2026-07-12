-- lua/config/mermaid_preview.lua
-- High-fidelity mermaid view: render the diagram to a real vector SVG with
-- mmdflux (already installed for the inline ASCII in lua/plugins/mermaid.lua)
-- and open it zoomable in the browser. Complements the inline ASCII, which
-- stays for quick glances; this is for large/complex diagrams that are hard to
-- read as text. Mirrors lua/config/plantuml_preview.lua and works in both the
-- normal editor and the pager profile (mmdflux + `open` exist in both).
local M = {}

local uv = vim.uv
local diagram_blocks = require("config.diagram_blocks")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "MermaidPreview" })
end

-- The mermaid source relevant to the cursor: the ```mermaid block under the
-- cursor in markdown, otherwise (a .mmd file) the whole buffer.
local function mermaid_src(buf)
	if vim.bo[buf].filetype ~= "markdown" then
		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local b = diagram_blocks.under_cursor(buf, { mermaid = true })
	return b and b.src or nil
end

local function get_buf_var(buf, name)
	local ok, value = pcall(vim.api.nvim_buf_get_var, buf, name)
	if ok then
		return value
	end
	return nil
end

local function set_buf_var(buf, name, value)
	pcall(vim.api.nvim_buf_set_var, buf, name, value)
end

local function ensure_cache_dir()
	local dir = vim.fn.stdpath("cache") .. "/mermaid_preview"
	vim.fn.mkdir(dir, "p")
	return dir
end

local function preview_paths(buf)
	local dir = ensure_cache_dir()
	local id = tostring(buf)
	return dir .. "/mermaid-preview-" .. id .. ".svg", dir .. "/mermaid-preview-" .. id .. ".html"
end

-- HTML shell around the SVG. Light background because mmdflux's SVG uses dark
-- (#333) strokes/text on white nodes; the JS timer re-fetches the SVG so live
-- edits (TextChanged) refresh the open tab.
local function write_html(html_path, svg_path)
	local svg_name = vim.fn.fnamemodify(svg_path, ":t")
	local lines = {
		"<!doctype html>",
		"<html>",
		"<head>",
		'  <meta charset="utf-8">',
		'  <meta name="viewport" content="width=device-width, initial-scale=1">',
		"  <title>Mermaid Preview</title>",
		"  <style>",
		"    body { margin: 0; padding: 16px; background: #fafafa; }",
		"    img { max-width: 100%; height: auto; display: block; margin: 0 auto; }",
		"  </style>",
		"</head>",
		"<body>",
		'  <img id="diagram" src="' .. svg_name .. '" alt="Mermaid">',
		"  <script>",
		"    const img = document.getElementById('diagram');",
		"    setInterval(() => { img.src = '" .. svg_name .. "?ts=' + Date.now(); }, 1000);",
		"  </script>",
		"</body>",
		"</html>",
	}
	vim.fn.writefile(lines, html_path)
end

local function open_in_browser(path)
	if vim.fn.executable("open") == 1 then
		vim.system({ "open", path })
		return true
	end
	if vim.fn.executable("xdg-open") == 1 then
		vim.system({ "xdg-open", path })
		return true
	end
	return false
end

-- Render the current diagram to `svg_path` (async), then call on_done.
local function render_svg(buf, svg_path, on_done)
	if vim.fn.executable("mmdflux") ~= 1 then
		notify("mmdflux not found in PATH (cargo install mmdflux)", vim.log.levels.ERROR)
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local source = mermaid_src(buf)
	if not source or vim.trim(source) == "" then
		notify("No mermaid block under cursor", vim.log.levels.WARN)
		return
	end

	vim.system({ "mmdflux", "-f", "svg" }, { text = true, stdin = source }, function(res)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if res.code ~= 0 then
				local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
				notify(msg == "" and "mmdflux failed" or msg, vim.log.levels.ERROR)
				return
			end
			vim.fn.writefile(vim.split(res.stdout or "", "\n"), svg_path)
			if on_done then
				on_done()
			end
		end)
	end)
end

-- Lua-side storage for uv timer handles (cannot survive buf-var round-trips).
local timers = {}

local function stop_timer(buf)
	local timer = timers[buf]
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
	timers[buf] = nil
end

local function schedule_render(buf)
	stop_timer(buf)
	local timer = uv.new_timer()
	timers[buf] = timer
	timer:start(
		700,
		0,
		vim.schedule_wrap(function()
			stop_timer(buf)
			if not get_buf_var(buf, "mermaid_preview_enabled") then
				return
			end
			local svg_path = get_buf_var(buf, "mermaid_preview_svg")
			if svg_path then
				render_svg(buf, svg_path)
			end
		end)
	)
end

local function setup_autocmds(buf)
	if get_buf_var(buf, "mermaid_preview_group") then
		return
	end
	local group = vim.api.nvim_create_augroup("MermaidPreview_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			if not get_buf_var(buf, "mermaid_preview_enabled") then
				return
			end
			schedule_render(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			stop_timer(buf)
			set_buf_var(buf, "mermaid_preview_group", nil)
		end,
	})
	set_buf_var(buf, "mermaid_preview_group", group)
end

function M.preview()
	local buf = vim.api.nvim_get_current_buf()
	local svg_path, html_path = preview_paths(buf)
	set_buf_var(buf, "mermaid_preview_enabled", true)
	set_buf_var(buf, "mermaid_preview_svg", svg_path)
	set_buf_var(buf, "mermaid_preview_html", html_path)
	write_html(html_path, svg_path)

	render_svg(buf, svg_path, function()
		if not open_in_browser(html_path) then
			notify("No opener found (open/xdg-open)", vim.log.levels.WARN)
		end
	end)

	setup_autocmds(buf)
end

return M
