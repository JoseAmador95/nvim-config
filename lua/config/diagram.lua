-- Host adapter for diagram-view.nvim. Tool discovery, user commands, keymaps,
-- and the concrete Neovim/Snacks presenters deliberately stay in config.
local view = require("diagram_view")

local M = {}

local INSTALL = { ["rsvg-convert"] = "brew install librsvg" }
local DEPS = {
	mermaid = { svg = { "mmdflux", "rsvg-convert" }, ascii = { "mmdflux" } },
	plantuml = { svg = { "plantuml", "rsvg-convert" }, ascii = { "plantuml" } },
}

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
		row = math.max(0, math.floor((vim.o.lines - height) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	set_float_lines(buf, { "Rendering…" })
	local function close()
		session:cancel("presenter closed")
	end
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true, desc = "Close diagram" })
	end
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = close,
	})
	return { buf = buf, win = win, width = width, height = height }
end

local function close_float(presentation)
	if presentation.placement then
		pcall(function()
			presentation.placement:close()
		end)
		presentation.placement = nil
	end
	if vim.api.nvim_win_is_valid(presentation.win) then
		pcall(vim.api.nvim_win_close, presentation.win, true)
	end
end

local function present_error(presentation, message)
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
	if vim.fn.has("mac") == 1 then
		local script = ('set the clipboard to (read (POSIX file "%s") as «class PNGf»)'):format(path)
		vim.system({ "osascript", "-e", script }, {}, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif vim.fn.executable("wl-copy") == 1 then
		local data, read_err = read_binary(path)
		if not data then
			on_done(false, "could not read rendered image: " .. tostring(read_err))
			return
		end
		vim.system({ "wl-copy", "--type", "image/png" }, { stdin = data }, function(result)
			on_done(result.code == 0, vim.trim(result.stderr or ""))
		end)
	elseif vim.fn.executable("xclip") == 1 then
		vim.system({ "xclip", "-selection", "clipboard", "-t", "image/png", path }, {}, function(result)
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
			set_float_lines(presentation.buf, vim.split(result.data, "\n", { plain = true }))
		end,
		error = present_error,
		close = close_float,
	}
end

local function image_presenter()
	return {
		open = function(request, session)
			local presentation = make_float(request.kind .. " (svg)", session)
			vim.keymap.set("n", "y", function()
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
			local term = Snacks.image.terminal.size()
			local dimensions = Snacks.image.util.dim(result.path)
			assert(dimensions and dimensions.width > 0 and dimensions.height > 0, "invalid rendered image dimensions")
			local box_height = math.max(1, presentation.height - 2)
			local aspect = (dimensions.width * term.cell_height) / (dimensions.height * term.cell_width)
			local image_width, image_height
			if aspect > presentation.width / box_height then
				image_width, image_height = presentation.width, math.max(1, math.floor(presentation.width / aspect))
			else
				image_width, image_height = math.max(1, math.floor(box_height * aspect)), box_height
			end
			local top = math.max(1, math.floor((presentation.height - image_height) / 2))
			local left = math.max(0, math.floor((presentation.width - image_width) / 2))
			local padding = {}
			for _ = 1, top do
				padding[#padding + 1] = ""
			end
			set_float_lines(presentation.buf, padding)
			if presentation.placement then
				pcall(function()
					presentation.placement:close()
				end)
			end
			presentation.placement = Snacks.image.placement.new(presentation.buf, result.path, {
				inline = true,
				pos = { top, left },
				max_width = presentation.width,
				max_height = box_height,
				auto_resize = true,
			})
			presentation.path = result.path
		end,
		error = present_error,
		close = close_float,
	}
end

local function valid_png(data)
	return type(data) == "string" and data:sub(1, 8) == "\137PNG\r\n\26\n"
end

local function register_renderers()
	local registrations = {
		["mermaid:ascii"] = {
			build = function()
				return { extension = "txt", stages = { { argv = { "mmdflux" }, text = true } } }
			end,
		},
		["plantuml:ascii"] = {
			plantuml = true,
			build = function()
				return { extension = "txt", stages = { { argv = { "plantuml", "-ttxt", "-pipe" }, text = true } } }
			end,
		},
		["mermaid:svg"] = {
			build = function(request)
				return {
					extension = "png",
					stages = {
						{ argv = { "mmdflux", "-f", "svg" }, text = true },
						{
							argv = {
								"rsvg-convert",
								"-f",
								"png",
								"-w",
								tostring(request.metadata.pixel_width),
								"-h",
								tostring(request.metadata.pixel_height),
								"--keep-aspect-ratio",
							},
						},
					},
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
						{ argv = { "plantuml", "-tsvg", "-pipe" }, text = true },
						{
							argv = {
								"rsvg-convert",
								"-f",
								"png",
								"-w",
								tostring(request.metadata.pixel_width),
								"-h",
								tostring(request.metadata.pixel_height),
								"--keep-aspect-ratio",
							},
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

local function missing(kind, mode)
	local result = {}
	for _, executable in ipairs(DEPS[kind][mode]) do
		if vim.fn.executable(executable) ~= 1 then
			result[#result + 1] = executable
		end
	end
	return result
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
	local width = math.max(1, math.floor(vim.o.columns * 0.9))
	local height = math.max(1, math.floor(vim.o.lines * 0.9))
	return {
		pixel_width = math.max(1, math.floor(width * term.cell_width)),
		pixel_height = math.max(1, math.floor(height * term.cell_height)),
	}
end

function M.show(mode)
	mode = mode or "svg"
	if mode ~= "svg" and mode ~= "ascii" then
		local message = "diagram mode must be svg or ascii"
		notify(message, vim.log.levels.WARN)
		return nil, message
	end
	local diagram, extract_err = view.extract({
		bufnr = vim.api.nvim_get_current_buf(),
		winid = vim.api.nvim_get_current_win(),
	})
	if not diagram then
		notify(extract_err, vim.log.levels.WARN)
		return nil, extract_err
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

	local absent = missing(diagram.kind, mode)
	if #absent > 0 then
		local message = ("Cannot render %s as %s: missing %s (install: %s)"):format(
			diagram.kind,
			mode:upper(),
			table.concat(absent, ", "),
			install_hint(absent)
		)
		notify(message, vim.log.levels.ERROR)
		return nil, message
	end

	return view.open({
		renderer = diagram.kind .. ":" .. mode,
		presenter = mode == "svg" and "image" or "ascii",
		kind = diagram.kind,
		source = diagram.source,
		metadata = mode == "svg" and image_metadata() or {},
	})
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

function M.setup(opts)
	if vim.g.vscode then
		return true
	end
	opts = opts or {}
	local limits = require("config.local_config").get("diagram_cache", {})
	local ok, err = view.setup({
		cache_root = opts.cache_root or (vim.fn.stdpath("cache") .. "/diagram-v3"),
		max_age_seconds = limits.max_age_seconds,
		max_bytes = limits.max_bytes,
		spawn = opts.spawn,
		schedule = opts.schedule,
		plantuml_policy = opts.plantuml_policy,
		notify = opts.notify or notify,
		event = opts.event,
	})
	if not ok then
		notify("Could not initialize diagram viewer: " .. tostring(err), vim.log.levels.ERROR)
		return nil, err
	end
	register_renderers()
	assert(view.register_presenter("ascii", ascii_presenter()))
	assert(view.register_presenter("image", image_presenter()))
	register_interface()
	return true
end

M.extract = view.extract

return M
