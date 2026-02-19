local M = {}

local uv = vim.uv or vim.loop

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "PlantumlPreview" })
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
	local dir = vim.fn.stdpath("cache") .. "/plantuml_preview"
	vim.fn.mkdir(dir, "p")
	return dir
end

local function preview_paths(buf)
	local dir = ensure_cache_dir()
	local id = tostring(buf)
	return dir .. "/plantuml-preview-" .. id .. ".png", dir .. "/plantuml-preview-" .. id .. ".html"
end

local function write_html(html_path, png_path)
	local png_name = vim.fn.fnamemodify(png_path, ":t")
	local lines = {
		"<!doctype html>",
		"<html>",
		"<head>",
		'  <meta charset="utf-8">',
		'  <meta name="viewport" content="width=device-width, initial-scale=1">',
		"  <title>PlantUML Preview</title>",
		"  <style>",
		"    body { margin: 0; padding: 16px; background: #111; color: #ddd; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace; }",
		"    img { max-width: 100%; height: auto; display: block; }",
		"  </style>",
		"</head>",
		"<body>",
		'  <img id="diagram" src="' .. png_name .. '" alt="PlantUML">',
		"  <script>",
		"    const img = document.getElementById('diagram');",
		"    setInterval(() => { img.src = '" .. png_name .. "?ts=' + Date.now(); }, 1000);",
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

local function stop_timer(timer)
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
end

local function render_png(buf, png_path)
	if vim.fn.executable("plantuml") ~= 1 then
		notify("plantuml not found in PATH", vim.log.levels.ERROR)
		return false
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	if input == "" then
		notify("Buffer is empty", vim.log.levels.WARN)
		return false
	end

	local result = vim.system({ "plantuml", "-tpng", "-pipe" }, { text = false, stdin = input }):wait()
	if result.code ~= 0 then
		local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
		if msg == "" then
			msg = "plantuml failed"
		end
		notify(msg, vim.log.levels.ERROR)
		return false
	end

	vim.fn.writefile({ result.stdout or "" }, png_path, "b")
	return true
end

local function schedule_render(buf)
	local timer = get_buf_var(buf, "plantuml_preview_timer")
	stop_timer(timer)

	timer = uv.new_timer()
	set_buf_var(buf, "plantuml_preview_timer", timer)
	timer:start(
		1000,
		0,
		vim.schedule_wrap(function()
			M.render({ buf = buf })
			stop_timer(timer)
			set_buf_var(buf, "plantuml_preview_timer", nil)
		end)
	)
end

local function setup_autocmds(buf)
	local existing = get_buf_var(buf, "plantuml_preview_group")
	if existing and type(existing) == "number" then
		return
	end

	local group = vim.api.nvim_create_augroup("PlantumlPreview_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			if not get_buf_var(buf, "plantuml_preview_enabled") then
				return
			end
			schedule_render(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			local timer = get_buf_var(buf, "plantuml_preview_timer")
			stop_timer(timer)
			set_buf_var(buf, "plantuml_preview_group", nil)
		end,
	})
	set_buf_var(buf, "plantuml_preview_group", group)
end

function M.render(opts)
	local options = opts or {}
	local buf = options.buf or vim.api.nvim_get_current_buf()
	if not get_buf_var(buf, "plantuml_preview_enabled") then
		return
	end

	local png_path = get_buf_var(buf, "plantuml_preview_png")
	local html_path = get_buf_var(buf, "plantuml_preview_html")
	if not png_path or not html_path then
		png_path, html_path = preview_paths(buf)
		set_buf_var(buf, "plantuml_preview_png", png_path)
		set_buf_var(buf, "plantuml_preview_html", html_path)
		write_html(html_path, png_path)
	end

	render_png(buf, png_path)
end

function M.preview()
	local buf = vim.api.nvim_get_current_buf()
	local png_path, html_path = preview_paths(buf)
	set_buf_var(buf, "plantuml_preview_enabled", true)
	set_buf_var(buf, "plantuml_preview_png", png_path)
	set_buf_var(buf, "plantuml_preview_html", html_path)
	write_html(html_path, png_path)

	if render_png(buf, png_path) then
		if not open_in_browser(html_path) then
			notify("No opener found (open/xdg-open)", vim.log.levels.WARN)
		end
	end

	setup_autocmds(buf)
end

return M
