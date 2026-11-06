local usage_map = require("config.usage").mapper("config.diagram")
-- Host adapter for diagram-view.nvim. Tool discovery, user commands, keymaps,
-- and the concrete Neovim/Snacks presenters deliberately stay in config.
local M = {}

local deferred = require("config.deferred")
local diagram_image = require("config.diagram_image")
local diagram_viewport = require("config.diagram_viewport")
local local_config = require("config.local_config")
local markdown_view = require("config.markdown_view")
local code_review = require("config.code_review")
local tool_paths = require("config.tool_paths")
local view
local configured = false
local setup_options = {}
local embedded_presentation
local embedded_session

local INSTALL = { ["rsvg-convert"] = "brew install librsvg" }
local DEPS = {
	mermaid = { svg = { "mmdflux", "rsvg-convert" }, ascii = { "mmdflux" } },
	plantuml = { svg = { "plantuml", "rsvg-convert" }, ascii = { "plantuml" } },
	-- An image is already its own picture: there is no ASCII rendering of one.
	image = { svg = { "rsvg-convert" } },
}
local MANAGED = { mmdflux = true, plantuml = true }

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Diagram" })
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

local function make_float(title, session)
	if setup_options.embedded and embedded_presentation and not embedded_presentation.closed then
		embedded_presentation.session = session
		return embedded_presentation
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	local width = math.max(1, math.floor(vim.o.columns * 0.9))
	local height = math.max(1, math.floor(vim.o.lines * 0.9))
	local win = setup_options.embedded and vim.api.nvim_get_current_win()
		or vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = math.max(0, math.floor((vim.o.lines - height) / 2)),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
			style = "minimal",
			border = "rounded",
			title = " " .. title .. " ",
			title_pos = "center",
		})
	if setup_options.embedded then
		vim.api.nvim_win_set_buf(win, buf)
		width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
	end
	local presentation = {
		buf = buf,
		win = win,
		width = width,
		height = height,
		session = session,
		embedded = setup_options.embedded == true,
	}
	vim.wo[win].wrap = false
	set_float_lines(buf, { "Rendering…" })
	local function close()
		if presentation.embedded then
			if setup_options.on_close then
				setup_options.on_close()
			end
		else
			presentation.session:cancel("presenter closed")
		end
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		usage_map("n", lhs, close, { buffer = buf, nowait = true, desc = "Close diagram" })
	end
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = close,
	})
	if presentation.embedded then
		embedded_presentation = presentation
	end
	return presentation
end

local function stop_refinement(presentation)
	local timer = presentation.refine_timer
	presentation.refine_timer = nil
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
end

local function close_float(presentation)
	if presentation.preserve then
		presentation.generation = (presentation.generation or 0) + 1
		stop_refinement(presentation)
		if presentation.pending_frame then
			local cancelled, err = presentation.pending_frame:cancel("diagram source changed")
			if cancelled == nil then
				notify("Could not stop diagram frame: " .. tostring(err), vim.log.levels.ERROR)
				return false
			end
			presentation.pending_frame = nil
		end
		return true
	end
	presentation.closed = true
	presentation.generation = (presentation.generation or 0) + 1
	stop_refinement(presentation)
	local cancelled = true
	for _, name in ipairs({ "pending_frame", "displayed_frame" }) do
		local frame = presentation[name]
		if frame then
			local ok, result, err = pcall(frame.cancel, frame, "diagram closed")
			if not ok or result == nil then
				cancelled = false
				notify("Could not stop diagram frame: " .. tostring(ok and err or result), vim.log.levels.ERROR)
			else
				presentation[name] = nil
			end
		end
	end
	if not cancelled then
		return false
	end
	if presentation.resize_autocmd then
		pcall(vim.api.nvim_del_autocmd, presentation.resize_autocmd)
		presentation.resize_autocmd = nil
	end
	diagram_viewport.close(presentation)
	if presentation.placement then
		pcall(function()
			presentation.placement:close()
		end)
		presentation.placement = nil
	end
	if presentation.embedded then
		if setup_options.on_close then
			setup_options.on_close()
		end
	elseif vim.api.nvim_win_is_valid(presentation.win) then
		pcall(vim.api.nvim_win_close, presentation.win, true)
	end
	return cancelled
end

local function present_error(presentation, message)
	presentation.stale = message
	if presentation.embedded and (presentation.path or presentation.delivered) then
		vim.wo[presentation.win].statusline = (" OUTDATED: " .. message):gsub("%%", "%%%%"):gsub("[\r\n]", " ")
		return
	end
	set_float_lines(presentation.buf, vim.split(message, "\n", { plain = true }))
end

local function read_binary(path)
	local fd, open_err = vim.uv.fs_open(path, "r", 384)
	if not fd then
		return nil, open_err
	end
	local info, stat_err = vim.uv.fs_fstat(fd)
	if not info then
		vim.uv.fs_close(fd)
		return nil, stat_err
	end
	local data, read_err = vim.uv.fs_read(fd, info.size, 0)
	vim.uv.fs_close(fd)
	return data, read_err
end

local function to_clipboard(path, on_done)
	local osascript = vim.fn.has("mac") == 1 and tool_paths.external_executable("osascript") or nil
	local wl_copy = tool_paths.external_executable("wl-copy")
	local xclip = tool_paths.external_executable("xclip")
	if osascript then
		local script = [[
on run argv
  set the clipboard to (read (POSIX file (item 1 of argv)) as «class PNGf»)
end run
]]
		vim.system({ osascript, "-e", script, path }, {}, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif wl_copy then
		local data, read_err = read_binary(path)
		if not data then
			on_done(false, "could not read rendered image: " .. tostring(read_err))
			return
		end
		vim.system({ wl_copy, "--type", "image/png" }, { stdin = data }, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif xclip then
		vim.system({ xclip, "-selection", "clipboard", "-t", "image/png", path }, {}, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	else
		on_done(false, "no image clipboard tool (need osascript, wl-copy or xclip)")
	end
end

local function ascii_presenter()
	return {
		open = function(request, session)
			return make_float(request.kind .. " (ascii)", session)
		end,
		deliver = function(presentation, result)
			presentation.stale = nil
			if presentation.embedded and presentation.viewport then
				for _, lhs in ipairs({
					"+",
					"=",
					"-",
					"0",
					"h",
					"j",
					"k",
					"l",
					"<Left>",
					"<Down>",
					"<Up>",
					"<Right>",
					"y",
				}) do
					pcall(vim.keymap.del, "n", lhs, { buffer = presentation.buf })
				end
				if presentation.resize_autocmd then
					vim.api.nvim_del_autocmd(presentation.resize_autocmd)
					presentation.resize_autocmd = nil
				end
				if presentation.displayed_frame then
					presentation.displayed_frame:cancel("ASCII view")
					presentation.displayed_frame = nil
				end
				diagram_viewport.close(presentation)
			end
			if presentation.placement then
				presentation.placement:close()
				presentation.placement = nil
			end
			presentation.path = nil
			set_float_lines(presentation.buf, vim.split(result.data, "\n", { plain = true }))
			presentation.delivered = true
			if presentation.embedded then
				vim.api.nvim_echo({ { "" } }, false, {})
				vim.wo[presentation.win].statusline = " Diagram (ASCII)   q/Esc close"
			end
		end,
		error = present_error,
		close = close_float,
	}
end

local function image_geometry(presentation, full)
	local term = Snacks.image.terminal.size()
	local width = vim.api.nvim_win_get_width(presentation.win)
	local height = vim.api.nvim_win_get_height(presentation.win)
	local dimensions = presentation.dimensions
	local scale = math.min(width * term.cell_width / dimensions.width, height * term.cell_height / dimensions.height)
	local pixel_width = math.max(1, math.floor(dimensions.width * scale))
	local pixel_height = math.max(1, math.floor(dimensions.height * scale))
	local image_width = full and width or math.min(width, math.max(1, math.ceil(pixel_width / term.cell_width)))
	local image_height = full and height or math.min(height, math.max(1, math.ceil(pixel_height / term.cell_height)))
	return {
		width = image_width,
		height = image_height,
		top = 1 + math.floor((height - image_height) / 2),
		left = math.max(0, math.floor((width - image_width) / 2)),
		pixel_width = math.max(1, math.floor(width * term.cell_width)),
		pixel_height = math.max(1, math.floor(height * term.cell_height)),
		scale = scale,
	}
end

local function scaled_image_size(presentation, geometry)
	return math.max(1, math.floor(presentation.dimensions.width * geometry.scale * presentation.viewport.zoom)),
		math.max(1, math.floor(presentation.dimensions.height * geometry.scale * presentation.viewport.zoom))
end

local function image_footer(presentation, rendering)
	if not vim.api.nvim_win_is_valid(presentation.win) then
		return
	end
	local footer = (" %d%%%s  +/- zoom  0 fit  hjkl/arrows pan  y copy  q close "):format(
		math.floor(presentation.viewport.zoom * 100 + 0.5),
		rendering and "…" or ""
	)
	if presentation.embedded then
		local message = presentation.stale and (" OUTDATED: " .. presentation.stale) or footer
		vim.wo[presentation.win].statusline = message:gsub("%%", "%%%%"):gsub("[\r\n]", " ")
		return
	end
	vim.api.nvim_win_set_config(presentation.win, {
		footer = footer,
		footer_pos = "center",
	})
end

local function place_image(presentation, path, full)
	local geometry = image_geometry(presentation, full)
	-- Keep the preview anchor until the sharp placement is ready.
	if not presentation.preview then
		local padding = {}
		for _ = 1, geometry.top + geometry.height - 1 do
			padding[#padding + 1] = ""
		end
		set_float_lines(presentation.buf, padding)
	end
	local placement = Snacks.image.placement.new(presentation.buf, path, {
		inline = true,
		conceal = true,
		pos = { geometry.top, geometry.left },
		range = { geometry.top, geometry.left, geometry.top + geometry.height - 1, geometry.left },
		max_width = geometry.width,
		max_height = geometry.height,
		auto_resize = true,
		on_update = presentation.preview and function(current)
			if not presentation.closed and presentation.placement == current then
				diagram_viewport.hide(presentation)
			end
		end,
	})
	if presentation.placement then
		presentation.placement:close()
	end
	presentation.placement = placement
end

local function preview_viewport(presentation)
	if not diagram_viewport.supported() then
		return false
	end
	local geometry = image_geometry(presentation)
	local width, height = scaled_image_size(presentation, geometry)
	local rows = vim.api.nvim_win_get_height(presentation.win)
	local columns = vim.api.nvim_win_get_width(presentation.win)
	if
		presentation.placement
		or presentation.preview_columns ~= columns
		or vim.api.nvim_buf_line_count(presentation.buf) ~= rows
	then
		set_float_lines(presentation.buf, vim.fn["repeat"]({ string.rep(" ", columns) }, rows))
		presentation.preview_columns = columns
	end
	return diagram_viewport.show(presentation, geometry, width, height)
end

local function replace_frame(presentation, path, frame)
	if frame or not preview_viewport(presentation) then
		place_image(presentation, path, frame ~= nil)
	end
	local previous = presentation.displayed_frame
	presentation.displayed_frame = frame
	if previous then
		previous:cancel("diagram frame replaced")
	end
	presentation.shown_viewport = vim.deepcopy(presentation.viewport)
	image_footer(presentation, false)
end

local function refine_viewport(presentation, generation)
	local geometry = image_geometry(presentation)
	local viewport = presentation.viewport
	local metadata = vim.deepcopy(presentation.request.metadata)
	metadata.pixel_width, metadata.pixel_height = scaled_image_size(presentation, geometry)
	metadata.page_width = geometry.pixel_width
	metadata.page_height = geometry.pixel_height
	metadata.left = math.floor(geometry.pixel_width / 2 - viewport.x * metadata.pixel_width + 0.5)
	metadata.top = math.floor(geometry.pixel_height / 2 - viewport.y * metadata.pixel_height + 0.5)
	image_footer(presentation, true)
	local completed = false
	local frame, open_err = view.open({
		renderer = presentation.renderer,
		presenter = "image_frame",
		kind = presentation.request.kind,
		source = presentation.request.source,
		plantuml_profile = presentation.request.plantuml_profile,
		metadata = metadata,
		on_done = function(result, err, session)
			completed = true
			if presentation.closed or generation ~= presentation.generation then
				session:cancel("obsolete diagram frame")
				return
			end
			presentation.pending_frame = nil
			if result then
				local ok, place_err = pcall(replace_frame, presentation, result.path, session)
				if ok then
					return
				end
				err = "Could not display diagram frame: " .. tostring(place_err)
				notify(err, vim.log.levels.ERROR)
			end
			session:cancel(err or "diagram frame failed")
			presentation.viewport = vim.deepcopy(presentation.shown_viewport)
			image_footer(presentation, false)
		end,
	})
	if not frame then
		presentation.viewport = vim.deepcopy(presentation.shown_viewport)
		image_footer(presentation, false)
		notify("Could not render diagram frame: " .. tostring(open_err), vim.log.levels.ERROR)
	elseif not completed then
		presentation.pending_frame = frame
	end
end

local function render_viewport(presentation, resized)
	presentation.generation = presentation.generation + 1
	local generation = presentation.generation
	stop_refinement(presentation)
	local preview = preview_viewport(presentation)
	if preview then
		presentation.shown_viewport = vim.deepcopy(presentation.viewport)
	end
	local previous = presentation.pending_frame
	if previous then
		local cancelled, err = previous:cancel("diagram viewport changed")
		if cancelled == nil then
			presentation.viewport = vim.deepcopy(presentation.shown_viewport)
			image_footer(presentation, false)
			notify("Could not stop diagram frame: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
	end
	presentation.pending_frame = nil
	if presentation.viewport.zoom == 1 and not resized then
		replace_frame(presentation, presentation.path)
		return
	end
	if not preview then
		refine_viewport(presentation, generation)
		return
	end
	image_footer(presentation, true)
	presentation.refine_timer = (setup_options.defer or vim.defer_fn)(function()
		presentation.refine_timer = nil
		if not presentation.closed and generation == presentation.generation then
			refine_viewport(presentation, generation)
		end
	end, 100)
end

local function pan_axis(position, delta, page, content)
	local visible = math.min(1, page / content)
	local half = visible / 2
	return math.max(half, math.min(1 - half, position + delta * visible))
end

local function move_viewport(presentation, zoom, dx, dy)
	if not presentation.path or presentation.closed then
		return
	end
	local viewport = presentation.viewport
	local previous = vim.deepcopy(viewport)
	viewport.zoom = math.max(1, math.min(8, zoom or viewport.zoom))
	local geometry = image_geometry(presentation)
	local width, height = scaled_image_size(presentation, geometry)
	viewport.x = pan_axis(viewport.x, dx or 0, geometry.pixel_width, width)
	viewport.y = pan_axis(viewport.y, dy or 0, geometry.pixel_height, height)
	if not vim.deep_equal(previous, viewport) then
		render_viewport(presentation)
	end
end

local function image_presenter()
	return {
		open = function(request, session)
			local title = request.metadata and request.metadata.title
			local presentation = make_float(title or (request.kind .. " (svg)"), session)
			presentation.request = request
			presentation.renderer = session.renderer_name
			presentation.generation = (presentation.generation or 0) + 1
			presentation.viewport = presentation.viewport or { zoom = 1, x = 0.5, y = 0.5 }
			presentation.shown_viewport = vim.deepcopy(presentation.viewport)
			if presentation.resize_autocmd then
				vim.api.nvim_del_autocmd(presentation.resize_autocmd)
			end
			presentation.resize_autocmd = vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
				callback = function(event)
					if presentation.closed or not vim.api.nvim_win_is_valid(presentation.win) then
						return true
					end
					if event.event == "VimResized" and not presentation.embedded then
						local width = math.max(1, math.floor(vim.o.columns * 0.9))
						local height = math.max(1, math.floor(vim.o.lines * 0.9))
						vim.api.nvim_win_set_config(presentation.win, {
							width = width,
							height = height,
							row = math.max(0, math.floor((vim.o.lines - height) / 2)),
							col = math.max(0, math.floor((vim.o.columns - width) / 2)),
						})
					end
					if presentation.path then
						local geometry = image_geometry(presentation)
						local size = { geometry.pixel_width, geometry.pixel_height }
						if not vim.deep_equal(presentation.size, size) then
							presentation.size = size
							local width, height = scaled_image_size(presentation, geometry)
							local viewport = presentation.viewport
							viewport.x = pan_axis(viewport.x, 0, geometry.pixel_width, width)
							viewport.y = pan_axis(viewport.y, 0, geometry.pixel_height, height)
							render_viewport(presentation, true)
						end
					end
				end,
			})
			for _, lhs in ipairs({ "+", "=" }) do
				usage_map("n", lhs, function()
					move_viewport(presentation, presentation.viewport.zoom * 1.5)
				end, { buffer = presentation.buf, nowait = true, desc = "Zoom into diagram" })
			end
			usage_map("n", "-", function()
				move_viewport(presentation, presentation.viewport.zoom / 1.5)
			end, { buffer = presentation.buf, nowait = true, desc = "Zoom out of diagram" })
			usage_map("n", "0", function()
				move_viewport(presentation, 1)
			end, { buffer = presentation.buf, nowait = true, desc = "Fit diagram to window" })
			for _, mapping in ipairs({
				{ "h", -0.2, 0 },
				{ "<Left>", -0.2, 0 },
				{ "l", 0.2, 0 },
				{ "<Right>", 0.2, 0 },
				{ "j", 0, 0.2 },
				{ "<Down>", 0, 0.2 },
				{ "k", 0, -0.2 },
				{ "<Up>", 0, -0.2 },
			}) do
				usage_map("n", mapping[1], function()
					move_viewport(presentation, nil, mapping[2], mapping[3])
				end, { buffer = presentation.buf, nowait = true, desc = "Pan diagram" })
			end
			image_footer(presentation, false)
			usage_map("n", "y", function()
				if not presentation.path then
					return
				end
				to_clipboard(presentation.path, function(ok, err)
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
			end, { buffer = presentation.buf, nowait = true, desc = "Copy diagram to clipboard" })
			return presentation
		end,
		deliver = function(presentation, result)
			if not vim.api.nvim_buf_is_valid(presentation.buf) then
				return
			end
			local dimensions = Snacks.image.util.dim(result.path)
			assert(dimensions and dimensions.width > 0 and dimensions.height > 0, "invalid rendered image dimensions")
			presentation.dimensions = dimensions
			presentation.stale = nil
			presentation.path = result.path
			if presentation.embedded then
				vim.api.nvim_echo({ { "" } }, false, {})
			end
			local geometry = image_geometry(presentation)
			presentation.size = { geometry.pixel_width, geometry.pixel_height }
			if presentation.embedded and presentation.viewport.zoom > 1 then
				render_viewport(presentation, true)
			else
				replace_frame(presentation, result.path)
			end
		end,
		error = present_error,
		close = close_float,
	}
end

local function valid_png(data)
	return type(data) == "string" and data:sub(1, 8) == "\137PNG\r\n\26\n"
end

local function valid_svg(data)
	return type(data) == "string" and data:find("<svg[%s/>]") ~= nil
end

local function image_conversion_argv(metadata)
	local argv = {
		metadata.executables["rsvg-convert"],
		"-f",
		"png",
		"-w",
		tostring(metadata.pixel_width),
		"-h",
		tostring(metadata.pixel_height),
		"--keep-aspect-ratio",
	}
	if metadata.page_width then
		vim.list_extend(argv, {
			"--page-width=" .. metadata.page_width,
			"--page-height=" .. metadata.page_height,
			"--left=" .. metadata.left,
			"--top=" .. metadata.top,
		})
	end
	return argv
end

local function register_renderers()
	local registrations = {
		["mermaid:ascii"] = {
			build = function(request)
				return {
					extension = "txt",
					stages = { { argv = { request.metadata.executables.mmdflux }, text = true } },
				}
			end,
		},
		["plantuml:ascii"] = {
			plantuml = true,
			build = function(request)
				return {
					extension = "txt",
					stages = {
						{ argv = { request.metadata.executables.plantuml, "-ttxt", "-pipe" }, text = true },
					},
				}
			end,
		},
		["mermaid:svg"] = {
			build = function(request)
				return {
					extension = "png",
					stages = {
						{
							argv = { request.metadata.executables.mmdflux, "-f", "svg" },
							text = true,
							cache = { extension = "svg", validate = valid_svg },
						},
						{
							argv = image_conversion_argv(request.metadata),
						},
					},
					validate = valid_png,
				}
			end,
		},
		["image:svg"] = {
			build = function(request)
				return {
					extension = "png",
					stages = { { argv = image_conversion_argv(request.metadata) } },
					validate = valid_png,
				}
			end,
		},
		["plantuml:svg"] = {
			plantuml = true,
			build = function(request)
				return {
					extension = "png",
					stages = {
						{
							argv = { request.metadata.executables.plantuml, "-tsvg", "-pipe" },
							text = true,
							cache = { extension = "svg", validate = valid_svg },
						},
						{
							argv = image_conversion_argv(request.metadata),
						},
					},
					validate = valid_png,
				}
			end,
		},
	}
	for name, spec in pairs(registrations) do
		local ok, err = view.register_renderer(name, spec)
		assert(ok, err)
	end
end

local function default_resolve_executable(executable)
	if MANAGED[executable] then
		return deferred.load("config.tool_bootstrap").resolve(executable, executable)
	end
	local path = tool_paths.external_executable(executable)
	if not path then
		return nil, "not found on the host PATH"
	end
	local resolved = vim.uv.fs_realpath(path)
	local stat = resolved and vim.uv.fs_stat(resolved) or nil
	if not resolved or not stat or stat.type ~= "file" or vim.fn.executable(resolved) ~= 1 then
		return nil, "did not resolve to an executable regular file"
	end
	return vim.fs.normalize(resolved)
end

local function resolve_dependencies(kind, mode)
	local executables = {}
	local unavailable = {}
	local resolver = setup_options.resolve_executable or default_resolve_executable
	for _, executable in ipairs(DEPS[kind][mode]) do
		local ok, path, resolve_err = pcall(resolver, executable)
		if ok and type(path) == "string" and path ~= "" then
			executables[executable] = path
		else
			unavailable[#unavailable + 1] = {
				name = executable,
				error = ok and tostring(resolve_err or "unavailable") or tostring(path),
			}
		end
	end
	return executables, unavailable
end

local function unavailable_names(entries)
	return vim.tbl_map(function(entry)
		return entry.name
	end, entries)
end

local function unavailable_details(entries)
	return table.concat(
		vim.tbl_map(function(entry)
			return entry.name .. ": " .. entry.error
		end, entries),
		"; "
	)
end

local function install_hint(executables)
	local hints = {}
	for _, executable in ipairs(executables) do
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

local function image_metadata()
	local term = Snacks.image.terminal.size()
	local width = setup_options.embedded and vim.api.nvim_win_get_width(0)
		or math.max(1, math.floor(vim.o.columns * 0.9))
	local height = setup_options.embedded and vim.api.nvim_win_get_height(0)
		or math.max(1, math.floor(vim.o.lines * 0.9))
	return {
		pixel_width = math.max(1, math.floor(width * term.cell_width)),
		pixel_height = math.max(1, math.floor(height * term.cell_height)),
	}
end

local DEFAULT_CONFIG = {
	backend = "auto",
	default_mode = "svg",
	stage_timeout_ms = 30000,
	max_stage_output_bytes = 16 * 1024 * 1024,
	cache = { max_age_seconds = 30 * 24 * 60 * 60, max_bytes = 256 * 1024 * 1024 },
}
local effective_config = vim.deepcopy(DEFAULT_CONFIG)

local function configure_view(core, options, config)
	local ok, setup_ok, setup_err = pcall(core.setup, {
		cache_root = options.cache_root or (vim.fn.stdpath("cache") .. "/diagram-v3"),
		default_mode = config.default_mode,
		stage_timeout_ms = config.stage_timeout_ms,
		max_stage_output_bytes = config.max_stage_output_bytes,
		cache = config.cache,
		spawn = options.spawn,
		system = options.system,
		schedule = options.schedule,
		defer = options.defer,
		plantuml_policy = options.plantuml_policy,
		notify = options.notify or notify,
		event = options.event,
	})
	if not ok or not setup_ok then
		return nil, ok and setup_err or setup_ok
	end
	configured = false
	local registered, register_err = pcall(function()
		register_renderers()
		assert(core.register_presenter("ascii", ascii_presenter()))
		assert(core.register_presenter("image", image_presenter()))
		assert(core.register_presenter("image_frame", {
			open = function()
				return {}
			end,
			deliver = function() end,
		}))
	end)
	if not registered then
		pcall(core.teardown)
		return nil, register_err
	end
	configured = true
	return core
end

local function ensure_view()
	if configured then
		return view
	end
	if not view then
		local ok, result = deferred.try("diagram_view")
		if not ok then
			return nil, result
		end
		view = result
	end
	return configure_view(view, setup_options, effective_config)
end

local function buffer_directory(bufnr)
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		return vim.fn.getcwd()
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return vim.fn.getcwd()
	end
	return vim.fs.dirname(vim.fs.normalize(name))
end

-- An image reference renders through the same SVG pipeline, so zoom, pan, copy,
-- caching, and cancellation behave exactly as they do for a diagram.
local function show_image(core, reference, target, ascii_requested)
	if ascii_requested then
		notify("An image has no ASCII rendering; showing the image instead.", vim.log.levels.WARN)
	end
	if not image_terminal_ok() then
		local message = "Images need inline image support in the terminal (the Kitty graphics protocol)"
		notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	local path, resolve_err = diagram_image.resolve(reference.source, buffer_directory(target.bufnr))
	if not path then
		notify(resolve_err, vim.log.levels.WARN)
		return nil, resolve_err
	end
	local loaded, load_err = diagram_image.load(path)
	if not loaded then
		notify(load_err, vim.log.levels.ERROR)
		return nil, load_err
	end
	local executables, unavailable = resolve_dependencies("image", "svg")
	if #unavailable > 0 then
		local names = unavailable_names(unavailable)
		local message = ("Cannot render %s: unavailable %s (%s; install: %s)"):format(
			vim.fs.basename(path),
			table.concat(names, ", "),
			unavailable_details(unavailable),
			install_hint(names)
		)
		notify(message, vim.log.levels.ERROR)
		return nil, message
	end
	local metadata = vim.tbl_extend("force", {
		executables = executables,
		title = vim.fs.basename(path) .. " (" .. loaded.format .. ")",
	}, image_metadata())
	return core.open({
		renderer = "image:svg",
		presenter = "image",
		kind = "image",
		source = loaded.source,
		metadata = metadata,
	})
end

function M.show(mode, selection)
	local requested = mode
	mode = mode or effective_config.default_mode
	if mode ~= "svg" and mode ~= "ascii" then
		local message = "diagram mode must be svg or ascii"
		notify(message, vim.log.levels.WARN)
		return nil, message
	end
	local core, setup_err = ensure_view()
	if not core then
		notify("Could not initialize diagram viewer: " .. tostring(setup_err), vim.log.levels.ERROR)
		return nil, setup_err
	end
	local target, target_err = code_review.source_document(selection)
	if not target and not target_err then
		target, target_err = markdown_view.diagram_target(selection)
	end
	if not target then
		notify(target_err, vim.log.levels.WARN)
		return nil, target_err
	end
	local rendered_selection = target.rendered and target.selection
	if rendered_selection then
		target.selection = nil
	end
	local diagram, extract_err = core.extract(target)
	if not diagram then
		notify(extract_err, vim.log.levels.WARN)
		return nil, extract_err
	end
	if
		rendered_selection
		and (
			diagram.origin.type ~= "fence"
			or diagram.origin.start_row > rendered_selection.start_row
			or diagram.origin.end_row < rendered_selection.end_row
		)
	then
		local message = "Select rows within a single diagram block in rendered review"
		notify(message, vim.log.levels.WARN)
		return nil, message
	end
	if diagram.kind == "image" then
		if target.frozen then
			local message = "Review images are frozen references; open the source file to preview a current image"
			notify(message, vim.log.levels.WARN)
			return nil, message
		end
		return show_image(core, diagram, target, requested == "ascii")
	end
	if
		effective_config.backend == "auto"
		and not setup_options.embedded
		and vim.env.REX_SESSION
		and vim.env.REX_BLOCK
	then
		local ok, rex = deferred.try("config.diagram_rex")
		if ok then
			return rex.show(target, diagram, mode, {
				config = effective_config,
				cache_root = setup_options.cache_root or (vim.fn.stdpath("cache") .. "/diagram-v3"),
				resolve_executable = setup_options.resolve_executable or default_resolve_executable,
				fallback = M.render,
			})
		end
		notify("Rex unavailable: " .. tostring(rex) .. ". Using Neovim.", vim.log.levels.WARN)
	end
	return M.render(diagram, mode)
end

-- The Rex child uses the same renderers and presenters in its ordinary window.
-- Superseding a request cancels work while keeping the last delivered frame.
function M.render(diagram, mode, reset)
	local core, setup_err = ensure_view()
	if not core then
		return nil, setup_err
	end
	if setup_options.embedded and embedded_session then
		embedded_presentation.preserve = true
		local cancelled, err = embedded_session:cancel("diagram source changed")
		embedded_presentation.preserve = nil
		if cancelled == nil then
			return nil, err
		end
		if reset then
			embedded_presentation.viewport = nil
		end
	end

	local executables
	if mode == "svg" then
		local reason
		if not image_terminal_ok() then
			reason = "the terminal has no inline image support (needs the Kitty graphics protocol)"
		else
			local unavailable
			executables, unavailable = resolve_dependencies(diagram.kind, "svg")
			if #unavailable > 0 then
				local names = unavailable_names(unavailable)
				reason = "unavailable "
					.. table.concat(names, ", ")
					.. " ("
					.. unavailable_details(unavailable)
					.. "; install: "
					.. install_hint(names)
					.. ")"
			end
		end
		if reason then
			notify("SVG unavailable: " .. reason .. ". Falling back to ASCII.", vim.log.levels.WARN)
			mode = "ascii"
			executables = nil
		end
	end

	if not executables then
		local unavailable
		executables, unavailable = resolve_dependencies(diagram.kind, mode)
		if #unavailable > 0 then
			local names = unavailable_names(unavailable)
			local message = ("Cannot render %s as %s: unavailable %s (%s; install: %s)"):format(
				diagram.kind,
				mode:upper(),
				table.concat(names, ", "),
				unavailable_details(unavailable),
				install_hint(names)
			)
			notify(message, vim.log.levels.ERROR)
			return nil, message
		end
	end

	local metadata = { executables = executables }
	if mode == "svg" then
		metadata = vim.tbl_extend("force", metadata, image_metadata())
	end
	local session, err = core.open({
		renderer = diagram.kind .. ":" .. mode,
		presenter = mode == "svg" and "image" or "ascii",
		kind = diagram.kind,
		source = diagram.source,
		metadata = metadata,
	})
	if setup_options.embedded and session then
		embedded_session = session
	end
	return session, err
end

function M.outdated(message)
	if embedded_presentation then
		embedded_presentation.preserve = true
		if embedded_session then
			embedded_session:cancel("diagram source invalid")
		end
		embedded_presentation.preserve = nil
		present_error(embedded_presentation, message)
	else
		vim.wo.statusline = (" OUTDATED: " .. message):gsub("%%", "%%%%"):gsub("[\r\n]", " ")
	end
end

-- Rex may discard uploaded image data while a session is hidden. Reuse the
-- owned Snacks image and placement on focus; no renderer or source change.
function M.refresh()
	local presentation = embedded_presentation
	local placement = presentation and presentation.placement
	if not placement or presentation.closed or not placement:ready() then
		return
	end
	local location = placement:state().loc
	placement.img.sent = false
	placement.img:send()
	Snacks.image.terminal.request({
		a = "p",
		U = 1,
		i = placement.img.id,
		p = placement.id,
		C = 1,
		c = location.width,
		r = location.height,
	})
	placement:render_grid(location)
end

function M.teardown()
	setup_options.on_close = nil
	local ok, err = true, nil
	if view and configured then
		ok, err = view.teardown()
	end
	if ok then
		configured = false
		embedded_session, embedded_presentation = nil, nil
	end
	return ok, err
end

local function register_interface()
	pcall(vim.api.nvim_del_user_command, "DiagramShow")
	vim.api.nvim_create_user_command("DiagramShow", function(options)
		local mode = vim.trim(options.args or "")
		if mode == "" then
			mode = nil
		end
		if mode and mode ~= "svg" and mode ~= "ascii" then
			notify("usage: :DiagramShow [svg|ascii]", vim.log.levels.WARN)
			return
		end
		local selection
		if options.range and options.range > 0 then
			selection = { start_row = options.line1, end_row = options.line2 }
		end
		M.show(mode, selection)
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return { "svg", "ascii" }
		end,
		desc = "Show diagram under cursor (svg default, ascii fallback)",
	})

	if require("config.pager").active then
		usage_map("n", "<leader>md", "<cmd>DiagramShow<cr>", { desc = "Show diagram (SVG/ASCII)" })
		usage_map("x", "<leader>md", ":<C-U>'<,'>DiagramShow<CR>", { desc = "Show selected diagram" })
		return
	end

	local function map(buf)
		usage_map("n", "<leader>md", "<cmd>DiagramShow<cr>", { buffer = buf, desc = "Show diagram (SVG/ASCII)" })
		usage_map("x", "<leader>md", ":<C-U>'<,'>DiagramShow<CR>", { buffer = buf, desc = "Show selected diagram" })
	end
	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "markdown", "plantuml", "md-render" },
		group = vim.api.nvim_create_augroup("DiagramKeymaps", { clear = true }),
		callback = function(args)
			map(args.buf)
		end,
	})
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local filetype = vim.bo[buf].filetype
			if filetype == "markdown" or filetype == "plantuml" or filetype == "md-render" then
				map(buf)
			end
		end
	end
end

function M.setup(opts)
	if vim.g.vscode then
		return true
	end
	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	if opts.resolve_executable ~= nil and type(opts.resolve_executable) ~= "function" then
		return nil, "setup.resolve_executable must be a function"
	end
	local candidate_config = opts.config or local_config.plugin("diagram_view", DEFAULT_CONFIG)
	if configured then
		local core, setup_err = configure_view(view, opts, candidate_config)
		if not core then
			return nil, setup_err
		end
	end
	setup_options = opts
	effective_config = candidate_config
	if not opts.embedded then
		register_interface()
	end
	return true
end

function M.extract(...)
	local core, err = ensure_view()
	if not core then
		return nil, err
	end
	return core.extract(...)
end

return M
