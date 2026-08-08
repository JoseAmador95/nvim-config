-- Browser-backed Mermaid preview with generation-safe live rerenders.
local M = {}

local async_runner = require("config.async_runner")
local diagram_blocks = require("config.diagram_blocks")
local fs = require("config.fs")

local states = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "MermaidPreview" })
end

local function mermaid_src(buf, win)
	if vim.bo[buf].filetype ~= "markdown" then
		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local block = diagram_blocks.under_cursor(buf, { mermaid = true }, win)
	return block and block.src or nil
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
	local stem = ("mermaid-preview-%d-%d"):format(vim.uv.os_getpid(), buf)
	local dir = ensure_cache_dir()
	return dir .. "/" .. stem .. ".svg", dir .. "/" .. stem .. ".html"
end

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
	if vim.fn.executable("mmdflux") ~= 1 then
		local command = ":NvimConfigToolsInstall mmdflux"
		local hint = require("config.pager").active and ("open full Neovim and run " .. command) or command
		notify("mmdflux not found in PATH (" .. hint .. ")", vim.log.levels.ERROR)
		return nil
	end
	local source = mermaid_src(state.buf, state.anchor_win)
	if not source or vim.trim(source) == "" then
		notify("No mermaid block under cursor", vim.log.levels.WARN)
		return nil
	end

	return {
		command = { "mmdflux", "-f", "svg" },
		options = { text = true, stdin = source },
		on_result = function(result)
			if not vim.api.nvim_buf_is_valid(state.buf) then
				return
			end
			if result.code ~= 0 or not (result.stdout or ""):find("<svg[%s>]") then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				notify(msg == "" and "mmdflux failed" or msg, vim.log.levels.ERROR)
				return
			end
			local written, write_err = fs.write_binary_atomic(state.svg_path, result.stdout)
			if not written then
				notify("Failed to write Mermaid preview: " .. tostring(write_err), vim.log.levels.ERROR)
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
	state.runner:debounce(700, function()
		if states[state.buf] ~= state or not state.enabled then
			return nil
		end
		return render_spec(state)
	end)
end

local function ensure_state(buf, anchor_win)
	local state = states[buf]
	if state then
		state.anchor_win = anchor_win
		return state
	end

	local svg_path, html_path = preview_paths(buf)
	state = {
		buf = buf,
		anchor_win = anchor_win,
		svg_path = svg_path,
		html_path = html_path,
		runner = async_runner.new(),
		enabled = true,
	}
	states[buf] = state

	local group = vim.api.nvim_create_augroup("MermaidPreview_" .. buf, { clear = true })
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
	set_buf_var(buf, "mermaid_preview_group", group)
	return state
end

function M.preview()
	local buf = vim.api.nvim_get_current_buf()
	local state = ensure_state(buf, vim.api.nvim_get_current_win())
	state.enabled = true
	state.open_pending = true
	set_buf_var(buf, "mermaid_preview_enabled", true)
	set_buf_var(buf, "mermaid_preview_svg", state.svg_path)
	set_buf_var(buf, "mermaid_preview_html", state.html_path)

	local written, write_err = write_html(state.html_path, state.svg_path)
	if not written then
		notify("Failed to write Mermaid preview page: " .. tostring(write_err), vim.log.levels.ERROR)
		return
	end
	local spec = render_spec(state)
	if spec then
		state.runner:request(spec)
	end
end

return M
