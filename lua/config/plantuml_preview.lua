local M = {}

local async_runner = require("config.async_runner")
local cache = require("config.diagram_cache")
local fs = require("config.fs")

local states = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "PlantumlPreview" })
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
	local stem = ("plantuml-preview-%d-%d"):format(vim.uv.os_getpid(), buf)
	local dir = ensure_cache_dir()
	return dir .. "/" .. stem .. ".png", dir .. "/" .. stem .. ".html"
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
	return fs.write_binary_atomic(html_path, table.concat(lines, "\n") .. "\n")
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

local function render_spec(state)
	if not vim.api.nvim_buf_is_valid(state.buf) then
		return nil
	end
	if vim.fn.executable("plantuml") ~= 1 then
		notify("plantuml not found in PATH", vim.log.levels.ERROR)
		return nil
	end
	local input = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
	if input == "" then
		notify("Buffer is empty", vim.log.levels.WARN)
		return nil
	end

	return {
		command = { "plantuml", "-tpng", "-pipe" },
		options = { text = false, stdin = input },
		on_result = function(result)
			if not vim.api.nvim_buf_is_valid(state.buf) then
				return
			end
			if result.code ~= 0 then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				notify(msg == "" and "plantuml failed" or msg, vim.log.levels.ERROR)
				return
			end
			local output = result.stdout or ""
			if not cache.is_png_data(output) then
				notify("plantuml produced an invalid PNG", vim.log.levels.ERROR)
				return
			end
			local written, write_err = fs.write_binary_atomic(state.png_path, output)
			if not written then
				notify("Failed to write PNG preview: " .. tostring(write_err), vim.log.levels.ERROR)
				return
			end
			if state.open_pending then
				state.open_pending = false
				if not open_in_browser(state.html_path) then
					notify("No opener found (open/xdg-open)", vim.log.levels.WARN)
				end
			end
		end,
	}
end

local function schedule_render(state)
	state.runner:debounce(1000, function()
		if states[state.buf] ~= state or not state.enabled then
			return nil
		end
		return render_spec(state)
	end)
end

local function ensure_state(buf)
	local state = states[buf]
	if state then
		return state
	end
	local png_path, html_path = preview_paths(buf)
	state = {
		buf = buf,
		png_path = png_path,
		html_path = html_path,
		runner = async_runner.new(),
		enabled = true,
	}
	states[buf] = state

	local group = vim.api.nvim_create_augroup("PlantumlPreview_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			if states[buf] == state and state.enabled then
				schedule_render(state)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			if states[buf] == state then
				states[buf] = nil
				state.enabled = false
				state.runner:close()
			end
		end,
	})
	set_buf_var(buf, "plantuml_preview_group", group)
	return state
end

local function request_render(state)
	local spec = render_spec(state)
	if spec then
		state.runner:request(spec)
	end
end

function M.render(opts)
	local options = opts or {}
	local buf = options.buf or vim.api.nvim_get_current_buf()
	local state = states[buf]
	if not state or not state.enabled then
		return
	end
	request_render(state)
end

function M.preview()
	local buf = vim.api.nvim_get_current_buf()
	local state = ensure_state(buf)
	state.enabled = true
	state.open_pending = true
	set_buf_var(buf, "plantuml_preview_enabled", true)
	set_buf_var(buf, "plantuml_preview_png", state.png_path)
	set_buf_var(buf, "plantuml_preview_html", state.html_path)

	local written, write_err = write_html(state.html_path, state.png_path)
	if not written then
		notify("Failed to write PlantUML preview page: " .. tostring(write_err), vim.log.levels.ERROR)
		return
	end
	request_render(state)
end

return M
