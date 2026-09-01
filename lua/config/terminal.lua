-- Host adapter for terminal-lifecycle.nvim. All callers use the plugin's
-- structured TerminalSpec contract; this module only supplies the Snacks view.
local M = {}

local uv = vim.uv
local lifecycle = require("terminal_lifecycle")
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve config.terminal source")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local devcontainer_bashrc = vim.fs.joinpath(config_root, "scripts", "devcontainer-bashrc")

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Terminal" })
end

local function canonical_directory(path, label)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
		return nil, (label or "directory") .. " must be an absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local stat = uv.fs_stat(normalized)
	if not stat or stat.type ~= "directory" then
		return nil, (label or "directory") .. " is not a directory: " .. normalized
	end
	return uv.fs_realpath(normalized) or normalized
end

local function normalize_spec(spec)
	local normalized, err = lifecycle._normalize(spec)
	if not normalized then
		return nil, err
	end
	local layout = normalized.view.layout or "bottom"
	if layout ~= "bottom" and layout ~= "float" then
		return nil, "view.layout must be bottom or float"
	end
	normalized.view.layout = layout
	return normalized
end

local function key_for(identity)
	if type(identity) == "string" then
		return identity ~= "" and not identity:find("\0", 1, true) and identity or nil, "terminal key must be non-empty"
	end
	if type(identity) == "table" and type(identity.key) == "string" and identity.key ~= "" then
		return identity.key
	end
	return nil, "terminal identity must be a key string or TerminalSpec"
end

local function workspace_key(runtime, root, id)
	if type(runtime) ~= "string" or runtime == "" or type(id) ~= "string" or id == "" then
		return nil, "terminal key requires runtime and id"
	end
	local canonical, err = canonical_directory(root, "root")
	if not canonical then
		return nil, err
	end
	return vim.json.encode({ runtime, canonical, id })
end

local function count_for(key)
	return (tonumber(vim.fn.sha256(key):sub(1, 7), 16) % 999999) + 1
end

local function buffer_job(buf)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	local ok, job = pcall(function()
		return vim.b[buf].terminal_job_id
	end)
	return ok and type(job) == "number" and job > 0 and job or nil
end

local function remember_terminal_job(win)
	if not win then
		return nil
	end
	local cached = win._terminal_lifecycle_job_id
	if type(cached) == "number" and cached > 0 then
		return cached
	end
	local job = buffer_job(win.buf)
	if job then
		win._terminal_lifecycle_job_id = job
	end
	return job
end

local function window_options(spec, callbacks)
	local view = spec.view
	local bound = false
	local function bind(win)
		if bound then
			return
		end
		bound = true
		local buf = win.buf
		local exit_reported = false
		local function report_exit(status)
			if exit_reported then
				return
			end
			exit_reported = true
			callbacks.on_exit(tonumber(status) or 0)
		end
		win._terminal_lifecycle_on_exit = report_exit
		callbacks.on_buffer(buf)
		vim.b[buf].nvim_config_terminal = {
			runtime = spec.metadata.runtime,
			root = spec.metadata.root,
			id = spec.metadata.id,
		}
		win:on("TermClose", function(_, event)
			local fallback = type(vim.v.event) == "table" and vim.v.event or {}
			local status = tonumber((event or {}).status) or tonumber(fallback.status) or 0
			win._terminal_lifecycle_observed_exit = status
			if status == -1 then
				vim.schedule(function()
					report_exit(status)
				end)
			else
				report_exit(status)
			end
		end, { buf = true })
		win:on("BufWipeout", function()
			remember_terminal_job(win)
			callbacks.on_dispose()
		end, { buf = true })
	end
	local options = {
		position = view.layout or "bottom",
		title = view.title,
		border = view.layout == "float" and "rounded" or nil,
		on_buf = bind,
	}
	if view.layout == "float" then
		options.width = view.width or 0.95
		options.height = view.height or 0.95
	else
		options.height = view.height or 0.35
	end
	return options, bind
end

local snacks_backend = {}

function snacks_backend.open(spec, callbacks)
	local window, bind = window_options(spec, callbacks)
	local win = require("snacks").terminal.open(spec.launch.argv, {
		cwd = spec.launch.cwd,
		env = spec.launch.env,
		count = count_for(spec.key),
		interactive = true,
		auto_close = false,
		win = window,
	})
	bind(win)
	remember_terminal_job(win)
	return win
end

function snacks_backend.buffer(win)
	return win.buf
end

function snacks_backend.visible(win)
	return win.valid and win:valid() or false
end

function snacks_backend.show(win)
	win:show()
	return true
end

function snacks_backend.focus(win)
	win:focus()
	return true
end

function snacks_backend.hide(win)
	win:hide()
	return true
end

local function terminal_job(win)
	return remember_terminal_job(win)
end

function snacks_backend.stop(win)
	if type(win._terminal_lifecycle_observed_exit) == "number" then
		win._terminal_lifecycle_on_exit(win._terminal_lifecycle_observed_exit)
		return true
	end
	local job = terminal_job(win)
	if not job then
		return nil, "terminal process has no job id"
	end
	local status = vim.fn.jobwait({ job }, 0)[1]
	if type(status) == "number" and status >= 0 then
		if type(win._terminal_lifecycle_on_exit) == "function" then
			win._terminal_lifecycle_on_exit(status)
		end
		return true
	end
	if status ~= -1 then
		return nil, "terminal process state could not be confirmed"
	end
	local stopped = vim.fn.jobstop(job)
	return stopped == 1 and true or nil, stopped == 1 and nil or "terminal process could not be stopped"
end

function snacks_backend.dispose(win)
	local ok, err = pcall(win.close, win)
	return ok and true or nil, ok and nil or tostring(err)
end

function snacks_backend.lines(win)
	if not win or not win.buf_valid or not win:buf_valid() then
		return nil, "terminal does not exist"
	end
	return vim.api.nvim_buf_get_lines(win.buf, 0, -1, false)
end

local function parse_location(spec, buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return nil, "terminal buffer no longer exists"
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""
	local path, lnum, col = line:match("^%s*(.-):(%d+):(%d+):?")
	if not path then
		path, lnum = line:match("^%s*(.-):(%d+):?")
	end
	if not path or path == "" then
		path = vim.fn.expand("<cfile>")
	end
	if not path or path == "" then
		return nil, "no file location under cursor"
	end
	local root = spec.metadata.root or spec.launch.cwd
	local absolute = path:sub(1, 1) == "/" and path or vim.fs.joinpath(spec.launch.cwd, path)
	local resolved = uv.fs_realpath(absolute)
	if not resolved or not require("config.repo").contains(root, resolved) then
		return nil, "location is missing or outside the terminal repository"
	end
	local stat = uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" then
		return nil, "location is not a regular file"
	end
	vim.schedule(function()
		require("config.editor").open_file_in_tab(resolved, { lnum = tonumber(lnum) or 1, col = tonumber(col) or 1 })
	end)
	return true
end

local lifecycle_policy = require("config.local_config").plugin("terminal_lifecycle", {
	stop_timeout_ms = 5000,
	buffer_mappings = { close = "q", open_location = "gf" },
})

local function configure_lifecycle()
	lifecycle.setup({
		backend = snacks_backend,
		notify = notify,
		schedule = vim.schedule,
		open_location = parse_location,
		stop_timeout_ms = lifecycle_policy.stop_timeout_ms,
		buffer_mappings = lifecycle_policy.buffer_mappings,
	})
end

configure_lifecycle()

local function call_with_spec(method, spec)
	local normalized, err = normalize_spec(spec)
	if not normalized then
		return nil, err
	end
	return lifecycle[method](normalized)
end

function M.open(spec)
	return call_with_spec("open", spec)
end

function M.toggle(spec)
	return call_with_spec("toggle", spec)
end

function M.focus(spec)
	if type(spec) ~= "table" or spec.launch == nil then
		local key, err = key_for(spec)
		if not key then
			return nil, err
		end
		return lifecycle.focus(key)
	end
	return call_with_spec("focus", spec)
end

function M.restart(spec)
	return call_with_spec("restart", spec)
end

function M.stop(identity)
	local key, err = key_for(identity)
	if not key then
		return nil, err
	end
	return lifecycle.stop(key)
end

function M.dispose(identity)
	local key, err = key_for(identity)
	if not key then
		return nil, err
	end
	return lifecycle.dispose(key)
end

function M.list()
	return lifecycle.list()
end

function M.dispose_all(filter)
	return lifecycle.dispose_all(filter)
end

function M.send(identity, text, options)
	local status = M.status(identity)
	if not status.accepting_input then
		return nil, "terminal process is not accepting input"
	end
	if type(text) ~= "string" or text:find("\0", 1, true) then
		return nil, "terminal input must be a string without NUL bytes"
	end
	local job = buffer_job(status.buf)
	if type(job) ~= "number" or job <= 0 or vim.fn.jobwait({ job }, 0)[1] ~= -1 then
		return nil, "terminal process is not running"
	end
	local payload = text .. ((options and options.newline == false) and "" or "\n")
	local ok, err = pcall(vim.api.nvim_chan_send, job, payload)
	return ok and true or nil, ok and nil or tostring(err)
end

function M.status(identity)
	if identity == nil then
		return lifecycle.status()
	end
	local key, err = key_for(identity)
	if not key then
		return nil, err
	end
	local status = lifecycle.status(key)
	status.exists = status.state ~= "disposed"
	status.running = status.state == "starting" or status.state == "running"
	local job = buffer_job(status.buf)
	status.accepting_input = status.accepting_input == true
		and type(job) == "number"
		and job > 0
		and vim.fn.jobwait({ job }, 0)[1] == -1
	return status
end

function M.effective_config()
	return lifecycle.effective_config()
end

function M.lines(identity)
	local key, err = key_for(identity)
	if not key then
		return nil, err
	end
	return lifecycle.lines(key)
end

function M.shell_spec(root)
	local key, key_err = workspace_key("host", root, "shell")
	if not key then
		return nil, key_err
	end
	local shell = vim.env.SHELL or vim.o.shell
	local argv = { shell }
	if vim.env.NVIM_DEVCONTAINER == "1" then
		local bash = vim.fn.exepath("bash")
		if bash ~= "" then
			shell = bash
			argv = { bash, "--rcfile", devcontainer_bashrc, "-i" }
		end
	end
	return {
		key = key,
		launch = { argv = argv, cwd = root, env = {} },
		policy = { dispose_on_success = true, dispose_on_stop = false },
		view = { layout = "bottom", title = "Shell", passthrough = { "<Tab>", "<S-Tab>" } },
		metadata = { runtime = "host", root = root, id = "shell" },
	}
end

M._devcontainer_bashrc = devcontainer_bashrc

function M.toggle_shell()
	local root = require("config.repo").current_root(0) or (uv.cwd() or vim.fn.getcwd())
	local spec, spec_err = M.shell_spec(root)
	if not spec then
		notify(spec_err, vim.log.levels.ERROR)
		return
	end
	local record, err = M.toggle(spec)
	if not record then
		notify(err, vim.log.levels.ERROR)
	end
end

M._normalize = normalize_spec
M._key = workspace_key
M._reset = function()
	lifecycle._reset()
	configure_lifecycle()
end

return M
