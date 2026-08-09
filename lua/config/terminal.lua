-- One terminal lifecycle for shells, REPLs, and host TUIs.  Callers identify
-- a process by (runtime, root, id); commands are argv arrays and never pass
-- through a shell.
local M = {}

local uv = vim.uv
local terminals = {}

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

local function normalize_argv(argv)
	if type(argv) ~= "table" or not vim.islist(argv) or #argv == 0 then
		return nil, "argv must be a non-empty array"
	end
	local result = {}
	for index, value in ipairs(argv) do
		if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
			return nil, ("argv[%d] must be a non-empty string without NUL bytes"):format(index)
		end
		result[index] = value
	end
	return result
end

local function normalize_env(env)
	if type(env) ~= "table" or (next(env) ~= nil and vim.islist(env)) then
		return nil, "env must be an explicit string map (use {} to inherit the host environment)"
	end
	local result = vim.empty_dict()
	for name, value in pairs(env) do
		if
			type(name) ~= "string"
			or name == ""
			or name:find("[=%z]")
			or type(value) ~= "string"
			or value:find("\0", 1, true)
		then
			return nil, "env must contain only valid string names and values"
		end
		result[name] = value
	end
	return result
end

local function normalize(spec)
	if type(spec) ~= "table" then
		return nil, "terminal specification must be a table"
	end
	if type(spec.runtime) ~= "string" or spec.runtime == "" or spec.runtime:find("\0", 1, true) then
		return nil, "runtime must be a non-empty string"
	end
	if type(spec.id) ~= "string" or spec.id == "" or spec.id:find("\0", 1, true) then
		return nil, "id must be a non-empty string"
	end
	local root, root_err = canonical_directory(spec.root, "root")
	if not root then
		return nil, root_err
	end
	local cwd, cwd_err = canonical_directory(spec.cwd or root, "cwd")
	if not cwd then
		return nil, cwd_err
	end
	local argv, argv_err = normalize_argv(spec.argv)
	if not argv then
		return nil, argv_err
	end
	local env, env_err = normalize_env(spec.env)
	if not env then
		return nil, env_err
	end
	local layout = spec.layout or "bottom"
	if layout ~= "bottom" and layout ~= "float" then
		return nil, "layout must be bottom or float"
	end
	return {
		runtime = spec.runtime,
		root = root,
		id = spec.id,
		argv = argv,
		cwd = cwd,
		env = env,
		layout = layout,
		title = spec.title or spec.id,
		close_on_success = spec.close_on_success ~= false,
		passthrough = vim.deepcopy(spec.passthrough or {}),
		hide_keys = vim.deepcopy(spec.hide_keys or {}),
	}
end

local function identity(spec)
	return table.concat({ spec.runtime, spec.root, spec.id }, "\0")
end

local function launch_signature(spec)
	return vim.json.encode({ spec.argv, spec.cwd, spec.env, spec.layout })
end

local function count_for(key)
	return (tonumber(vim.fn.sha256(key):sub(1, 7), 16) % 999999) + 1
end

local function record_for(identity_spec)
	if type(identity_spec) ~= "table" then
		return nil
	end
	local root = identity_spec.root and canonical_directory(identity_spec.root, "root") or nil
	if not root or type(identity_spec.runtime) ~= "string" or type(identity_spec.id) ~= "string" then
		return nil
	end
	return terminals[table.concat({ identity_spec.runtime, root, identity_spec.id }, "\0")]
end

local function job_id(record)
	if not record or not record.win or not record.win.buf_valid or not record.win:buf_valid() then
		return nil
	end
	local job = vim.b[record.win.buf].terminal_job_id
	return type(job) == "number" and job > 0 and job or nil
end

local function is_running(record)
	local job = job_id(record)
	return record and record.running == true and job and vim.fn.jobwait({ job }, 0)[1] == -1 or false
end

local function parse_location(record)
	local line = vim.api.nvim_get_current_line()
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
	local absolute = path:sub(1, 1) == "/" and path or vim.fs.joinpath(record.spec.cwd, path)
	local resolved = uv.fs_realpath(absolute)
	if not resolved or not require("config.repo").contains(record.spec.root, resolved) then
		return nil, "location is missing or outside the terminal repository"
	end
	local stat = uv.fs_stat(resolved)
	if not stat or stat.type ~= "file" then
		return nil, "location is not a regular file"
	end
	return resolved, tonumber(lnum) or 1, tonumber(col) or 1
end

local function configure_buffer(record)
	local win = record.win
	local buf = win.buf
	vim.b[buf].nvim_config_terminal = {
		runtime = record.spec.runtime,
		root = record.spec.root,
		id = record.spec.id,
	}
	local map = function(modes, lhs, rhs, desc)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("n", "q", function()
		M.hide(record.spec)
	end, "Hide terminal")
	map("n", "gf", function()
		local path, lnum, col = parse_location(record)
		if not path then
			notify(lnum, vim.log.levels.WARN)
			return
		end
		M.hide(record.spec)
		vim.schedule(function()
			require("config.editor").open_file_in_tab(path, { lnum = lnum, col = col })
		end)
	end, "Open location in tab")
	for _, lhs in ipairs(record.spec.passthrough) do
		map("t", lhs, lhs, "Pass terminal key through")
	end
	for _, lhs in ipairs(record.spec.hide_keys) do
		map({ "n", "t" }, lhs, function()
			M.hide(record.spec)
		end, "Hide terminal")
	end
end

local function window_options(spec, key)
	local window = {
		position = spec.layout,
		title = spec.title,
		border = spec.layout == "float" and "rounded" or nil,
		on_buf = function(win)
			local record = terminals[key]
			if record then
				record.win = win
				configure_buffer(record)
			end
		end,
	}
	if spec.layout == "float" then
		window.width = 0.95
		window.height = 0.95
	else
		window.height = 0.35
	end
	return window
end

local function dispose(record)
	if not record then
		return
	end
	terminals[record.key] = nil
	if record.win and record.win.close then
		pcall(record.win.close, record.win)
	end
end

local function create(spec)
	local key = identity(spec)
	local record = {
		key = key,
		spec = spec,
		signature = launch_signature(spec),
		running = true,
		exit_code = nil,
	}
	terminals[key] = record
	local ok, win = pcall(require("snacks").terminal.open, spec.argv, {
		cwd = spec.cwd,
		env = spec.env,
		count = count_for(key),
		interactive = true,
		auto_close = false,
		win = window_options(spec, key),
	})
	if not ok then
		terminals[key] = nil
		return nil, tostring(win)
	end
	record.win = win
	if win.buf_valid and win:buf_valid() then
		configure_buffer(record)
	end
	win:on("TermClose", function(_, event)
		local active = terminals[key]
		if active ~= record then
			return
		end
		local fallback = type(vim.v.event) == "table" and vim.v.event or {}
		record.exit_code = tonumber((event or {}).status) or tonumber(fallback.status) or 0
		record.running = false
		if record.exit_code == 0 and record.spec.close_on_success then
			vim.schedule(function()
				if terminals[key] == record then
					dispose(record)
				end
			end)
		elseif record.exit_code ~= 0 then
			notify(
				("%s exited with code %d; output was retained"):format(record.spec.title, record.exit_code),
				vim.log.levels.ERROR
			)
		end
	end, { buf = true })
	win:on("BufWipeout", function()
		if terminals[key] == record then
			terminals[key] = nil
		end
	end, { buf = true })
	return record
end

local function resolve(spec, create_missing)
	local normalized, err = normalize(spec)
	if not normalized then
		return nil, err
	end
	local key = identity(normalized)
	local record = terminals[key]
	if record and (not record.win or not record.win.buf_valid or not record.win:buf_valid()) then
		terminals[key] = nil
		record = nil
	end
	if record and record.signature ~= launch_signature(normalized) then
		local restarted, restart_err = M.restart(normalized)
		return restarted, restart_err, restarted ~= nil
	end
	if not record and create_missing then
		local created, create_err = create(normalized)
		return created, create_err, created ~= nil
	end
	return record, nil, false
end

function M.open(spec)
	local record, err = resolve(spec, true)
	if not record then
		return nil, err
	end
	record.win:show():focus()
	return record
end

function M.toggle(spec)
	local record, err, created = resolve(spec, true)
	if not record then
		return nil, err
	end
	if created then
		return record
	end
	if record.win.valid and record.win:valid() then
		record.win:hide()
	else
		record.win:show():focus()
	end
	return record
end

function M.focus(spec)
	local record, err = resolve(spec, true)
	if not record then
		return nil, err
	end
	record.win:show():focus()
	return record
end

function M.hide(identity_spec)
	local record = record_for(identity_spec)
	if not record then
		return false
	end
	record.win:hide()
	return true
end

function M.send(identity_spec, text, options)
	local record = record_for(identity_spec)
	if not record or not is_running(record) then
		return nil, "terminal process is not running"
	end
	if type(text) ~= "string" or text:find("\0", 1, true) then
		return nil, "terminal input must be a string without NUL bytes"
	end
	local payload = text .. ((options and options.newline == false) and "" or "\n")
	local ok, err = pcall(vim.api.nvim_chan_send, assert(job_id(record)), payload)
	return ok and true or nil, ok and nil or tostring(err)
end

function M.restart(spec)
	local normalized, err = normalize(spec)
	if not normalized then
		return nil, err
	end
	local key = identity(normalized)
	local record = terminals[key]
	local job = job_id(record)
	if job and is_running(record) then
		pcall(vim.fn.jobstop, job)
	end
	dispose(record)
	return create(normalized)
end

function M.status(identity_spec)
	local record = record_for(identity_spec)
	if not record then
		return { exists = false, running = false }
	end
	return {
		exists = true,
		running = is_running(record),
		exit_code = record.exit_code,
		visible = record.win.valid and record.win:valid() or false,
		buf = record.win.buf,
	}
end

function M.lines(identity_spec)
	local record = record_for(identity_spec)
	if not record or not record.win:buf_valid() then
		return nil, "terminal does not exist"
	end
	return vim.api.nvim_buf_get_lines(record.win.buf, 0, -1, false)
end

function M.shell_spec(root)
	local shell = vim.env.SHELL or vim.o.shell
	return {
		runtime = "host",
		root = root,
		id = "shell",
		argv = { shell },
		cwd = root,
		env = {},
		layout = "bottom",
		title = "Shell",
		passthrough = { "<Tab>", "<S-Tab>" },
	}
end

function M.toggle_shell()
	local root = require("config.repo").current_root(0) or (uv.cwd() or vim.fn.getcwd())
	local record, err = M.toggle(M.shell_spec(root))
	if not record then
		notify(err, vim.log.levels.ERROR)
	end
end

M._normalize = normalize
M._identity = identity
M._reset = function()
	terminals = {}
end

return M
