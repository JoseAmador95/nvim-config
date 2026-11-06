-- Host-only adapter: private IPC, source observation, and one owned Rex float.
local rex = require("rex")
local sources = require("config.diagram_rex_source")
local tool_paths = require("config.tool_paths")
local M = {}
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local current
local initialized = false
local leaving = false
local layouts = {
	center = { 0.05, 0.05, 0.9, 0.9 },
	right = { 0.52, 0.05, 0.43, 0.9 },
}

local function notify(message)
	vim.notify(message, vim.log.levels.WARN, { title = "Rex diagram" })
end

local function cleanup(viewer)
	if viewer.watcher then
		viewer.watcher:stop()
	end
	if viewer.timer and not viewer.timer:is_closing() then
		viewer.timer:stop()
		viewer.timer:close()
	end
	if viewer.channel then
		pcall(vim.fn.chanclose, viewer.channel)
	end
	if viewer.directory then
		vim.fn.delete(viewer.directory, "rf")
	end
	if current == viewer then
		current = nil
	end
end

local function send(viewer)
	if not viewer.channel then
		return
	end
	local ok = pcall(vim.rpcnotify, viewer.channel, "nvim_exec_lua", "NvimRexDiagram.update(...)", { viewer.payload })
	if not ok then
		notify("The diagram viewer disconnected; close its Rex float and open the diagram again.")
		pcall(vim.fn.chanclose, viewer.channel)
		viewer.channel = nil
	end
end

local function update(viewer, diagram, err, reset)
	viewer.generation = viewer.generation + 1
	viewer.payload = {
		generation = viewer.generation,
		diagram = diagram and { kind = diagram.kind, source = diagram.source, title = diagram.title } or nil,
		error = err,
		mode = viewer.mode,
		reset = reset or (viewer.payload and viewer.payload.reset),
		executables = viewer.executables,
		unavailable = viewer.unavailable,
	}
	send(viewer)
	if viewer.channel then
		viewer.payload.reset = false
	end
end

local function connect(viewer)
	local deadline = vim.uv.hrtime() + 6e9
	viewer.timer = assert(vim.uv.new_timer())
	viewer.timer:start(
		0,
		50,
		vim.schedule_wrap(function()
			if current ~= viewer or leaving then
				return
			end
			local ok, channel = pcall(vim.fn.sockconnect, "pipe", viewer.socket, { rpc = true })
			if ok and channel > 0 then
				viewer.timer:stop()
				viewer.timer:close()
				viewer.channel = channel
				vim.rpcnotify(channel, "nvim_set_client_info", "nvim-rex-diagram-source", {}, "remote", {}, {})
				send(viewer)
				viewer.payload.reset = false
			elseif vim.uv.hrtime() > deadline then
				viewer.timer:stop()
				viewer.timer:close()
				notify("Rex diagram did not start; closing the owned float.")
				rex.close(viewer.handle, function(err)
					if err then
						notify("Could not close the Rex diagram: " .. err)
					end
				end)
			end
		end)
	)
end

local function runtime_root(module)
	local path = vim.api.nvim_get_runtime_file("lua/" .. module .. "/init.lua", false)[1]
	assert(path, module .. " is not available in the current runtime")
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(path)))
end

local function prepare(viewer, options)
	local runtime = { runtime_root("snacks"), runtime_root("vscode") }
	viewer.directory = assert(vim.uv.fs_mkdtemp("/tmp/nvim-rex-XXXXXX"))
	viewer.directory = assert(vim.uv.fs_realpath(viewer.directory))
	viewer.socket = viewer.directory .. "/viewer.sock"
	local path = viewer.directory .. "/profile.json"
	local data = vim.json.encode({
		root = root,
		runtime = runtime,
		socket = viewer.socket,
		parent_pid = vim.uv.os_getpid(),
		background = vim.o.background,
		config = options.config,
		cache_root = options.cache_root,
	})
	local fd = assert(vim.uv.fs_open(path, "wx", 384))
	local written, err = vim.uv.fs_write(fd, data, 0)
	vim.uv.fs_close(fd)
	assert(written == #data, err or "could not write Rex diagram profile")
	local command = { "/usr/bin/env" }
	for _, name in ipairs({
		"NVIM",
		"NVIM_LISTEN_ADDRESS",
		"TMUX",
		"SSH_CLIENT",
		"SSH_CONNECTION",
		"SSH_TTY",
		"REX_EDITOR_BOOTSTRAP",
		"REX_EDITOR_KEY",
		"REX_EDITOR_OPERATION",
		"REX_EDITOR_SOCKET",
	}) do
		vim.list_extend(command, { "-u", name })
	end
	vim.list_extend(command, {
		"NVIM_REX_PROFILE=" .. path,
		"NVIM_APPNAME=nvimpager",
		"NVIM_LOG_FILE=" .. viewer.directory .. "/nvim.log",
		"XDG_STATE_HOME=" .. viewer.directory .. "/state",
		"XDG_CACHE_HOME=" .. viewer.directory .. "/cache",
		"PATH=" .. (vim.env.PATH or ""),
		vim.v.progpath,
		"-u",
		root .. "/scripts/rex-diagram-viewer.lua",
		"-i",
		"NONE",
		"-n",
	})
	viewer.command = command
	viewer.cwd = vim.fn.getcwd()
end

local function open(viewer)
	viewer.opening = true
	viewer.request = rex.open_float({
		context = viewer.context,
		label = "Neovim diagram",
		command = viewer.command,
		cwd = viewer.cwd,
		on_close = function()
			cleanup(viewer)
		end,
	}, function(err, handle)
		viewer.opening = false
		if err then
			-- Keep the same identity/argv for an explicit retry after uncertainty.
			notify("Could not open Rex diagram: " .. err)
			return
		end
		viewer.handle = handle
		connect(viewer)
	end)
end

function M.show(target, diagram, mode, options)
	local binary = tool_paths.external_executable("rex")
	if not binary then
		notify("Rex CLI is unavailable. Using Neovim.")
		return options.fallback(diagram, mode)
	end
	if not initialized then
		assert(rex.setup({ bin = binary }))
		vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.teardown })
		initialized = true
	end
	local viewer = current or { generation = 0, layout = "center" }
	local fresh = current == nil
	local same = viewer.watcher and viewer.watcher:matches(target, diagram)
	if viewer.watcher then
		viewer.watcher:stop()
	end
	viewer.mode = mode
	viewer.executables, viewer.unavailable = {}, {}
	local dependencies = diagram.kind == "image" and {} or { diagram.kind == "mermaid" and "mmdflux" or "plantuml" }
	if mode == "svg" then
		dependencies[#dependencies + 1] = "rsvg-convert"
	end
	for _, name in ipairs(dependencies) do
		local ok, path, err = pcall(options.resolve_executable, name)
		if ok and path then
			viewer.executables[name] = path
		else
			viewer.unavailable[name] = tostring(ok and err or path)
		end
	end
	viewer.watcher = sources.watch(target, diagram, function(item, err)
		if current == viewer then
			update(viewer, item, err, false)
		end
	end)
	current = viewer
	update(viewer, diagram, nil, not same)
	if not fresh then
		if viewer.handle then
			M.restore()
		elseif not viewer.opening and viewer.context then
			open(viewer)
		end
		return true
	end
	viewer.opening = true
	rex.context(function(err, context)
		if current ~= viewer or leaving then
			return
		end
		if not context then
			local item = viewer.payload.diagram
			local selected_mode = viewer.mode
			cleanup(viewer)
			notify("Rex context is unavailable: " .. tostring(err or "no local session") .. ". Using Neovim.")
			if item then
				options.fallback(item, selected_mode)
			end
			return
		end
		viewer.context = context
		local ok, prepare_err = pcall(prepare, viewer, options)
		if not ok then
			cleanup(viewer)
			notify("Could not prepare Rex diagram: " .. tostring(prepare_err))
			return
		end
		open(viewer)
	end)
	return true
end

local function control(action, layout)
	local viewer = current
	if not viewer or not viewer.handle or leaving then
		notify("No Rex preview is open. Use :DiagramShow first.")
		return nil
	end
	if viewer.controlling then
		notify("A Rex preview control is still pending.")
		return nil
	end
	viewer.controlling = true
	local function completed(err)
		viewer.controlling = false
		if current ~= viewer then
			return
		end
		if err then
			notify("Could not " .. action .. " Rex preview: " .. err)
		elseif layout then
			viewer.layout = layout
		end
	end
	if layout then
		rex.resize(viewer.handle, layouts[layout], completed)
	else
		rex[action](viewer.handle, completed)
	end
	return true
end

function M.hide()
	return control("hide")
end

function M.restore()
	return control("restore")
end

function M.layout(name)
	name = name or (current and current.layout == "right" and "center" or "right")
	if not layouts[name] then
		notify("usage: :DiagramLayout [center|right]")
		return nil
	end
	return control("resize", name)
end

function M.teardown()
	leaving = true
	local viewer = current
	if viewer and viewer.watcher then
		viewer.watcher:stop()
	end
	rex.teardown()
	vim.wait(1500, function()
		return rex.status().pending == 0
	end, 10)
	if viewer and #rex.status().records == 0 then
		cleanup(viewer)
	elseif viewer then
		notify("Rex diagram cleanup is still pending; close its owned float if Rex is unreachable.")
	end
end

function M.status()
	return current
			and {
				handle = vim.deepcopy(current.handle),
				socket = current.socket,
				generation = current.generation,
				connected = current.channel ~= nil,
				layout = current.layout,
			}
		or nil
end

return M
