-- Unified on-demand Mermaid and PlantUML viewer. Rendering is asynchronous and
-- generation-aware: closing a float or requesting a newer zoom invalidates old
-- callbacks, and every renderer output is promoted atomically.
local M = {}

local async_runner = require("config.async_runner")
local blocks = require("config.diagram_blocks")
local cache = require("config.diagram_cache")
local fs = require("config.fs")

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Diagram" })
end

local LANGS = { mermaid = "mermaid", plantuml = "plantuml", puml = "plantuml", uml = "plantuml" }

local INSTALL = { ["rsvg-convert"] = "brew install librsvg" }

local DEPS = {
	mermaid = { svg = { "mmdflux", "rsvg-convert" }, ascii = { "mmdflux" } },
	plantuml = { svg = { "plantuml", "rsvg-convert" }, ascii = { "plantuml" } },
}

local function missing(kind, mode)
	local out = {}
	for _, executable in ipairs(DEPS[kind][mode]) do
		if vim.fn.executable(executable) ~= 1 then
			out[#out + 1] = executable
		end
	end
	return out
end

local function install_hint(list)
	local hints = {}
	for _, executable in ipairs(list) do
		if executable == "mmdflux" or executable == "plantuml" then
			local command = ":NvimConfigToolsInstall " .. executable
			hints[#hints + 1] = require("config.pager").active and ("open full Neovim and run " .. command) or command
		else
			hints[#hints + 1] = INSTALL[executable] or ("install " .. executable)
		end
	end
	return table.concat(hints, "; ")
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

local function detect(buf)
	local filetype = vim.bo[buf].filetype
	if filetype == "plantuml" then
		return { kind = "plantuml", src = whole_buffer(buf) }
	end
	if filetype ~= "markdown" then
		return { kind = "mermaid", src = whole_buffer(buf) }
	end
	local accepted = {}
	for language in pairs(LANGS) do
		accepted[language] = true
	end
	local block = blocks.under_cursor(buf, accepted)
	return block and { kind = LANGS[block.lang], src = block.src } or nil
end

local function set_float_lines(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.bo[buf].modified = false
end

-- A centered, read-only scratch float. q / <Esc> closes it.
local function make_float(title)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local width = math.max(1, math.floor(vim.o.columns * 0.9))
	local height = math.max(1, math.floor(vim.o.lines * 0.9))
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
	set_float_lines(buf, { "Rendering…" })
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

local function svg_dims(svg)
	local root = svg:match("<svg[^>]*>") or svg
	local ox, oy, width, height = root:match('viewBox="%s*(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)')
	if width then
		return tonumber(ox), tonumber(oy), tonumber(width), tonumber(height)
	end
	local width_string = root:match('width="(%-?[%d%.]+)')
	local height_string = root:match('height="(%-?[%d%.]+)')
	if width_string and height_string then
		return 0, 0, tonumber(width_string), tonumber(height_string)
	end
	return nil
end

local function svg_info(kind, src, svg, svg_key)
	local ox, oy, width, height = svg_dims(svg)
	return {
		svg = svg,
		ox = ox,
		oy = oy,
		w = width,
		h = height,
		kind = kind,
		src = src,
		svg_key = svg_key,
	}
end

local function valid_svg(svg)
	return type(svg) == "string" and svg ~= "" and svg:find("<svg[%s>]") ~= nil
end

local function to_svg(session, kind, src, callback)
	local command = kind == "mermaid" and { "mmdflux", "-f", "svg" } or { "plantuml", "-tsvg", "-pipe" }
	local tool = kind == "mermaid" and "mmdflux" or "plantuml"
	local key = cache.key({ source = src, mode = kind .. ":svg", argv = command })
	local path = cache.path(key, "svg")
	local cached = cache.read(path)
	if valid_svg(cached) then
		callback(svg_info(kind, src, cached, key))
		return
	elseif cached then
		pcall(vim.uv.fs_unlink, path)
	end

	session.runner:request({
		command = command,
		options = { text = true, stdin = src },
		on_result = function(result)
			if result.code ~= 0 or not valid_svg(result.stdout) then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				notify(msg == "" and (tool .. " failed to render the diagram") or msg, vim.log.levels.ERROR)
				return
			end
			local written, write_err = fs.write_binary_atomic(path, result.stdout)
			if not written then
				notify("Could not cache rendered SVG: " .. tostring(write_err), vim.log.levels.ERROR)
				return
			end
			callback(svg_info(kind, src, result.stdout, key))
		end,
	})
end

local function render_view(session, info, view, target, callback)
	local view_key = view and ("%g,%g,%g,%g"):format(view.x, view.y, view.w, view.h) or "full"
	local svg = info.svg
	local command = {
		"rsvg-convert",
		"-f",
		"png",
		"-w",
		tostring(target.width),
		"-h",
		tostring(target.height),
	}
	if view then
		svg = svg:gsub('viewBox="[^"]*"', ('viewBox="%g %g %g %g"'):format(view.x, view.y, view.w, view.h), 1)
	else
		command[#command + 1] = "--keep-aspect-ratio"
	end

	local key_argv = vim.list_extend(vim.deepcopy(command), { "-o", "<output>" })
	local key = cache.key({
		source = info.src,
		mode = ("%s:png:%dx%d:%s"):format(info.kind, target.width, target.height, view_key),
		argv = key_argv,
		extra = info.svg_key,
	})
	local png = cache.path(key, "png")
	if cache.is_valid_png(png) then
		callback(png)
		return
	elseif vim.fn.filereadable(png) == 1 then
		pcall(vim.uv.fs_unlink, png)
	end

	local temp = fs.temp_path(png)
	cache.retain(temp)
	command[#command + 1] = "-o"
	command[#command + 1] = temp
	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		pcall(vim.uv.fs_unlink, temp)
		cache.release(temp)
	end

	session.runner:request({
		command = command,
		options = { stdin = svg },
		on_finish = function(_, delivered)
			if not delivered then
				cleanup()
			end
		end,
		on_result = function(result)
			if result.code ~= 0 or not cache.is_valid_png(temp) then
				cleanup()
				local msg = vim.trim(result.stderr or "")
				notify(msg == "" and "rsvg-convert failed to rasterize the SVG" or msg, vim.log.levels.ERROR)
				return
			end
			local replaced, replace_err = fs.replace_atomic(temp, png)
			cache.release(temp)
			cleaned = true
			if not replaced or not cache.is_valid_png(png) then
				notify("Could not cache rendered PNG: " .. tostring(replace_err or "invalid PNG"), vim.log.levels.ERROR)
				return
			end
			callback(png)
		end,
	})
end

local function to_text(session, kind, src, callback)
	local command = kind == "mermaid" and { "mmdflux" } or { "plantuml", "-ttxt", "-pipe" }
	local key = cache.key({ source = src, mode = kind .. ":ascii", argv = command })
	local path = cache.path(key, "txt")
	local cached = cache.read(path)
	if cached then
		callback(vim.split(cached, "\n", { plain = true }))
		return
	end

	session.runner:request({
		command = command,
		options = { text = true, stdin = src },
		on_result = function(result)
			if result.code ~= 0 then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				notify(msg == "" and "diagram render failed" or msg, vim.log.levels.ERROR)
				return
			end
			local output = result.stdout or ""
			local written, write_err = fs.write_binary_atomic(path, output)
			if not written then
				notify("Could not cache rendered text: " .. tostring(write_err), vim.log.levels.ERROR)
				return
			end
			callback(vim.split(output, "\n", { plain = true }))
		end,
	})
end

local function to_clipboard(png, on_done)
	if vim.fn.has("mac") == 1 then
		local script = ('set the clipboard to (read (POSIX file "%s") as «class PNGf»)'):format(png)
		vim.system({ "osascript", "-e", script }, {}, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif vim.fn.executable("wl-copy") == 1 then
		local data = cache.read(png) or ""
		vim.system({ "wl-copy", "--type", "image/png" }, { stdin = data }, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif vim.fn.executable("xclip") == 1 then
		vim.system({ "xclip", "-selection", "clipboard", "-t", "image/png", png }, {}, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	else
		on_done(false, "no image clipboard tool (need osascript, wl-copy or xclip)")
	end
end

local function show_svg(diagram)
	local buf, width, height, win = make_float(diagram.kind .. " (svg)")
	local session = { runner = async_runner.new() }
	local copy_session = { runner = async_runner.new() }
	local placement
	local shown

	local function alive()
		return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			session.runner:close()
			copy_session.runner:close()
			if placement then
				pcall(function()
					placement:close()
				end)
			end
			cache.release(shown)
			shown = nil
		end,
	})

	local term = Snacks.image.terminal.size()
	local size = {
		width = math.max(1, math.floor(width * term.cell_width)),
		height = math.max(1, math.floor(height * term.cell_height)),
	}

	to_svg(session, diagram.kind, diagram.src, function(info)
		if not alive() then
			return
		end
		local can_zoom = info.w and info.h and info.w > 0 and info.h > 0
		local zoom_min, zoom_max, zoom_step, pan_step = 1, 8, 1.25, 0.2
		local zoom = 1
		local center_x, center_y = (info.w or 0) / 2, (info.h or 0) / 2
		local display = {
			width = size.width,
			height = math.max(1, size.height - 2 * term.cell_height),
		}
		local display_aspect = display.width / display.height
		local base_width, base_height
		if can_zoom then
			if info.w / info.h < display_aspect then
				base_height, base_width = info.h, info.h * display_aspect
			else
				base_width, base_height = info.w, info.w / display_aspect
			end
		end

		local function clamp(value, lower, upper)
			return math.min(math.max(value, lower), upper)
		end

		local function clamp_center()
			local visible_width, visible_height = base_width / zoom, base_height / zoom
			center_x = visible_width >= info.w and info.w / 2
				or clamp(center_x, visible_width / 2, info.w - visible_width / 2)
			center_y = visible_height >= info.h and info.h / 2
				or clamp(center_y, visible_height / 2, info.h - visible_height / 2)
		end

		local function current_view()
			local visible_width, visible_height = base_width / zoom, base_height / zoom
			return {
				x = info.ox + center_x - visible_width / 2,
				y = info.oy + center_y - visible_height / 2,
				w = visible_width,
				h = visible_height,
			}
		end

		local function place(image)
			if not alive() then
				return
			end
			local box_height = math.max(1, height - 2)
			local dimensions = Snacks.image.util.dim(image)
			local aspect = (dimensions.width * term.cell_height) / (dimensions.height * term.cell_width)
			local image_width, image_height
			if aspect > width / box_height then
				image_width, image_height = width, math.floor(width / aspect)
			else
				image_width, image_height = math.floor(box_height * aspect), box_height
			end
			local top = math.max(1, math.floor((height - image_height) / 2))
			local left = math.max(0, math.floor((width - image_width) / 2))
			local padding = {}
			for _ = 1, top do
				padding[#padding + 1] = ""
			end
			set_float_lines(buf, padding)

			cache.retain(image)
			if placement then
				pcall(function()
					placement:close()
				end)
			end
			cache.release(shown)
			local placed, new_placement = pcall(Snacks.image.placement.new, buf, image, {
				inline = true,
				pos = { top, left },
				max_width = width,
				max_height = box_height,
				auto_resize = true,
			})
			if not placed then
				cache.release(image)
				placement = nil
				shown = nil
				notify("Could not display rendered diagram: " .. tostring(new_placement), vim.log.levels.ERROR)
				return
			end
			placement = new_placement
			shown = image
		end

		local function update_title()
			local ok, config = pcall(vim.api.nvim_win_get_config, win)
			if not ok then
				return
			end
			config.title = can_zoom and (" %s (svg) · %d%% "):format(diagram.kind, math.floor(zoom * 100 + 0.5))
				or (" " .. diagram.kind .. " (svg) ")
			config.title_pos = "center"
			pcall(vim.api.nvim_win_set_config, win, config)
		end

		local function rerender()
			if not alive() then
				return
			end
			update_title()
			render_view(session, info, can_zoom and current_view() or nil, can_zoom and display or size, place)
		end

		rerender()

		local function copy()
			local function copy_image(image)
				to_clipboard(image, function(ok, err)
					vim.schedule(function()
						if ok then
							notify("Diagram copied to clipboard")
						else
							notify(
								"Copy to clipboard failed: " .. (err ~= "" and err or "unknown"),
								vim.log.levels.ERROR
							)
						end
					end)
				end)
			end
			if can_zoom then
				local scale = 2000 / math.max(info.w, info.h)
				local target = {
					width = math.max(1, math.floor(info.w * scale)),
					height = math.max(1, math.floor(info.h * scale)),
				}
				render_view(copy_session, info, nil, target, copy_image)
			elseif shown then
				copy_image(shown)
			end
		end
		vim.keymap.set("n", "y", copy, { buffer = buf, nowait = true, desc = "Copy diagram to clipboard" })

		if can_zoom then
			local function change_zoom(factor)
				zoom = clamp(zoom * factor, zoom_min, zoom_max)
				clamp_center()
				rerender()
			end
			local function pan(dx, dy)
				center_x = center_x + dx * (base_width / zoom) * pan_step
				center_y = center_y + dy * (base_height / zoom) * pan_step
				clamp_center()
				rerender()
			end
			local mappings = {
				h = function()
					pan(-1, 0)
				end,
				l = function()
					pan(1, 0)
				end,
				k = function()
					pan(0, -1)
				end,
				j = function()
					pan(0, 1)
				end,
				["+"] = function()
					change_zoom(zoom_step)
				end,
				["="] = function()
					change_zoom(zoom_step)
				end,
				["_"] = function()
					change_zoom(1 / zoom_step)
				end,
				["-"] = function()
					change_zoom(1 / zoom_step)
				end,
				["0"] = function()
					zoom, center_x, center_y = 1, info.w / 2, info.h / 2
					rerender()
				end,
			}
			for lhs, callback in pairs(mappings) do
				vim.keymap.set("n", lhs, callback, { buffer = buf, nowait = true, desc = "Diagram zoom/pan" })
			end
		end
	end)
end

local function show_ascii(diagram)
	local buf = make_float(diagram.kind .. " (ascii)")
	local session = { runner = async_runner.new() }
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			session.runner:close()
		end,
	})
	to_text(session, diagram.kind, diagram.src, function(lines)
		set_float_lines(buf, lines)
	end)
end

function M.show(mode)
	mode = mode or "svg"
	local diagram = detect(vim.api.nvim_get_current_buf())
	if not diagram then
		notify("No mermaid/plantuml diagram under the cursor", vim.log.levels.WARN)
		return
	end

	if mode == "svg" then
		local reason
		if not image_terminal_ok() then
			reason = "the terminal has no inline image support (needs the Kitty graphics protocol)"
		else
			local absent = missing(diagram.kind, "svg")
			if #absent > 0 then
				reason = "missing " .. table.concat(absent, ", ") .. " (install: " .. install_hint(absent) .. ")"
			end
		end
		if reason then
			notify("SVG unavailable: " .. reason .. ". Falling back to ASCII.", vim.log.levels.WARN)
			mode = "ascii"
		end
	end

	if mode == "ascii" then
		local absent = missing(diagram.kind, "ascii")
		if #absent > 0 then
			notify(
				("Cannot render %s as ASCII: missing %s (install: %s)"):format(
					diagram.kind,
					table.concat(absent, ", "),
					install_hint(absent)
				),
				vim.log.levels.ERROR
			)
			return
		end
		show_ascii(diagram)
	else
		show_svg(diagram)
	end
end

function M.setup()
	if vim.g.vscode then
		return
	end

	vim.api.nvim_create_user_command("DiagramShow", function(options)
		local mode = vim.trim(options.args or "")
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
		callback = function(args)
			map(args.buf)
		end,
	})
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local filetype = vim.bo[buf].filetype
			if filetype == "markdown" or filetype == "plantuml" then
				map(buf)
			end
		end
	end
end

return M
