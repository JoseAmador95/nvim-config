-- Host adapter for diagram-view.nvim. Tool discovery, user commands, keymaps,
-- and the concrete Neovim/Snacks presenters deliberately stay in config.
local M = {}

local deferred = require("config.deferred")
local local_config = require("config.local_config")
local view
local configured = false
local setup_options = {}

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

local DEFAULT_CONFIG = {
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

function M.show(mode, selection)
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
	local diagram, extract_err = core.extract({
		bufnr = vim.api.nvim_get_current_buf(),
		winid = vim.api.nvim_get_current_win(),
		selection = selection,
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

	return core.open({
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
		vim.keymap.set("n", "<leader>md", "<cmd>DiagramShow<cr>", { desc = "Show diagram (SVG/ASCII)" })
		vim.keymap.set("x", "<leader>md", ":<C-U>'<,'>DiagramShow<CR>", { desc = "Show selected diagram" })
		return
	end

	local function map(buf)
		vim.keymap.set("n", "<leader>md", "<cmd>DiagramShow<cr>", { buffer = buf, desc = "Show diagram (SVG/ASCII)" })
		vim.keymap.set(
			"x",
			"<leader>md",
			":<C-U>'<,'>DiagramShow<CR>",
			{ buffer = buf, desc = "Show selected diagram" }
		)
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
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	local candidate_config = local_config.plugin("diagram_view", DEFAULT_CONFIG)
	if configured then
		local core, setup_err = configure_view(view, opts, candidate_config)
		if not core then
			return nil, setup_err
		end
	end
	setup_options = opts
	effective_config = candidate_config
	register_interface()
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
