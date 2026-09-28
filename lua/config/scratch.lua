local M = {}

local deferred = require("config.deferred")
local local_config = require("config.local_config")
local scratch
local configured = false
local effective_config
local setup_options = {}
local active = {}

local DEFAULT_CONFIG = { retention_days = 30, lease_seconds = 300, prune_on_open = true }

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Scratch" })
end

local function state_root()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "scratch")
end

local function load_scratch()
	if scratch then
		return scratch
	end
	local ok, result = deferred.try("repo_scratch")
	if not ok then
		return nil, result
	end
	scratch = result
	return scratch
end

local function configure_scratch(core, options, config)
	local ok, setup_ok, setup_err = pcall(core.setup, {
		state_root = options.state_root or state_root(),
		max_age_seconds = config.retention_days * 24 * 60 * 60,
		lease_seconds = config.lease_seconds,
		event = options.event,
	})
	if not ok then
		return nil, setup_ok
	end
	if not setup_ok then
		return nil, setup_err
	end
	configured = true
	return core
end

local function ensure_scratch()
	if configured then
		return scratch
	end
	local core, load_err = load_scratch()
	if not core then
		return nil, load_err
	end
	effective_config = effective_config or local_config.plugin("repo_scratch", DEFAULT_CONFIG)
	return configure_scratch(core, setup_options, effective_config)
end

local function git(root, arguments)
	return require("config.repo").git(root, arguments)
end

local function identity(root)
	local full_ref = git(root, { "symbolic-ref", "--quiet", "HEAD" })
	local legacy_ref
	if full_ref and vim.trim(full_ref) ~= "" then
		full_ref = vim.trim(full_ref)
		legacy_ref = full_ref:gsub("^refs/heads/", "")
	else
		full_ref = git(root, { "rev-parse", "HEAD" })
		if not full_ref or not vim.trim(full_ref):match("^[0-9a-f]+$") then
			return nil, "repository has no resolvable HEAD"
		end
		full_ref = vim.trim(full_ref)
		legacy_ref = "detached-" .. full_ref:sub(1, 12)
	end
	return {
		key = { repo_identity = root, ref = full_ref },
		label = legacy_ref,
		legacy_ids = { vim.fn.sha256(root .. "\0" .. legacy_ref) },
	}
end

local function loaded_scratch_paths()
	local result = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[buf].repo_scratch_handle then
			result[#result + 1] = vim.api.nvim_buf_get_name(buf)
		end
	end
	return result
end

local function buffer_content(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local stop_timer

local function save(buf)
	local handle = vim.b[buf].repo_scratch_handle
	if not handle then
		return false
	end
	local lifecycle = active[buf]
	if lifecycle and lifecycle.lease_lost then
		notify("Could not save scratch: lease-lost", vim.log.levels.ERROR)
		return false
	end
	local updated, err = scratch.save(handle, buffer_content(buf))
	if not updated then
		local detail = type(err) == "table" and err.kind or tostring(err)
		if lifecycle and (detail == "lease-lost" or detail == "lease-unsafe") then
			lifecycle.lease_lost = true
			lifecycle.error = detail
			stop_timer(lifecycle.timer)
		end
		notify("Could not save scratch: " .. detail, vim.log.levels.ERROR)
		return false
	end
	vim.b[buf].repo_scratch_handle = updated
	vim.bo[buf].modified = false
	return true
end

stop_timer = function(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local ok, closing = pcall(timer.is_closing, timer)
	if not ok or not closing then
		pcall(timer.close, timer)
	end
end

local function release(buf, fallback)
	local lifecycle = active[buf]
	if lifecycle then
		stop_timer(lifecycle.timer)
		active[buf] = nil
	end
	local handle = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].repo_scratch_handle or nil
	return scratch.release(handle or fallback)
end

local function heartbeat(buf, handle)
	local timer_factory = setup_options.new_timer or vim.uv.new_timer
	local timer, timer_err = timer_factory()
	if not timer then
		return nil, timer_err or "could not create scratch lease heartbeat"
	end
	local interval = math.max(1, math.floor(effective_config.lease_seconds * 1000 / 3))
	local lifecycle = { timer = timer, interval_ms = interval, lease_lost = false, error = nil, handle = handle }
	active[buf] = lifecycle
	local started, start_result = pcall(timer.start, timer, interval, interval, function()
		(setup_options.schedule or vim.schedule)(function()
			if active[buf] ~= lifecycle or not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			local current = vim.b[buf].repo_scratch_handle or handle
			local renewed, renew_err = scratch.renew(current)
			if not renewed then
				lifecycle.lease_lost = true
				lifecycle.error = tostring(renew_err)
				stop_timer(timer)
				notify("Scratch lease was lost; saving is disabled: " .. lifecycle.error, vim.log.levels.ERROR)
			end
		end)
	end)
	if not started or start_result == nil or start_result == false then
		active[buf] = nil
		stop_timer(timer)
		return nil, tostring(started and "heartbeat start failed" or start_result)
	end
	return true
end

local function present(root, label, handle)
	local win = require("snacks").scratch.open({
		file = handle.path,
		name = "Scratch · " .. vim.fs.basename(root) .. " · " .. label,
		ft = "markdown",
		autowrite = false,
		win = { bo = { buftype = "acwrite", swapfile = false } },
	})
	if not win or not win.buf then
		scratch.release(handle)
		return nil
	end
	local buf = win.buf
	vim.b[buf].repo_scratch_handle = handle
	local heartbeat_ok, heartbeat_err = heartbeat(buf, handle)
	if not heartbeat_ok then
		scratch.release(handle)
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
		notify("Could not start scratch lease heartbeat: " .. tostring(heartbeat_err), vim.log.levels.ERROR)
		return nil
	end
	local group = vim.api.nvim_create_augroup("NvimConfigScratch" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			save(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufHidden", {
		group = group,
		buffer = buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				save(buf)
			end
		end,
	})
	local released = false
	local function release_once()
		if released then
			return false
		end
		released = true
		return release(buf, handle)
	end
	active[buf].release = release_once
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = buf,
		once = true,
		callback = release_once,
	})
	return win
end

function M.open()
	local core, setup_err = ensure_scratch()
	if not core then
		notify("Could not initialize scratch state: " .. tostring(setup_err), vim.log.levels.ERROR)
		return nil
	end
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		notify(root_err, vim.log.levels.ERROR)
		return nil
	end
	local target, target_err = identity(root)
	if not target then
		notify(target_err, vim.log.levels.ERROR)
		return nil
	end
	if effective_config.prune_on_open then
		local pruned, prune_err = core.prune(loaded_scratch_paths())
		if not pruned then
			notify(prune_err, vim.log.levels.ERROR)
			return nil
		end
	end
	local handle, open_err = core.open({ key = target.key, legacy_ids = target.legacy_ids })
	if not handle then
		local detail = type(open_err) == "table" and open_err.kind or tostring(open_err)
		notify("Could not open scratch: " .. detail, vim.log.levels.ERROR)
		return nil
	end
	return present(root, target.label, handle)
end

function M.setup(opts)
	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	for key in pairs(opts) do
		if key ~= "state_root" and key ~= "new_timer" and key ~= "schedule" and key ~= "event" then
			return nil, "setup contains an unknown option: " .. tostring(key)
		end
	end
	for _, key in ipairs({ "new_timer", "schedule", "event" }) do
		if opts[key] ~= nil and type(opts[key]) ~= "function" then
			return nil, "setup." .. key .. " must be a function"
		end
	end
	if next(active) ~= nil then
		return nil, "cannot reconfigure scratch while buffers hold active leases"
	end
	local candidate_config = local_config.plugin("repo_scratch", DEFAULT_CONFIG)
	if configured then
		local core, setup_err = configure_scratch(scratch, opts, candidate_config)
		if not core then
			return nil, setup_err
		end
	end
	setup_options = opts
	effective_config = candidate_config
	vim.api.nvim_create_user_command(
		"Scratch",
		M.open,
		{ nargs = 0, desc = "Open the private repo/ref scratch", force = true }
	)
	vim.keymap.set("n", "<leader>.", M.open, { desc = "Project scratch" })
	return true
end

function M.effective_config()
	return vim.deepcopy(effective_config or DEFAULT_CONFIG)
end

function M.status()
	local buffers = {}
	for buf, lifecycle in pairs(active) do
		buffers[#buffers + 1] = {
			bufnr = buf,
			interval_ms = lifecycle.interval_ms,
			lease_lost = lifecycle.lease_lost,
			error = lifecycle.error,
		}
	end
	table.sort(buffers, function(left, right)
		return left.bufnr < right.bufnr
	end)
	return vim.deepcopy({ configured = configured, config = M.effective_config(), buffers = buffers })
end

function M.teardown()
	local buffers = vim.tbl_keys(active)
	for _, buf in ipairs(buffers) do
		local lifecycle = active[buf]
		if lifecycle and lifecycle.release then
			lifecycle.release()
		else
			release(buf, lifecycle and lifecycle.handle)
		end
	end
	active = {}
	if scratch and configured then
		scratch.teardown()
	end
	configured = false
	effective_config = nil
	return true
end

M._scratch = setmetatable({}, {
	__index = function(_, key)
		local core, err = load_scratch()
		if not core then
			error("could not load repo scratch: " .. tostring(err), 2)
		end
		return core[key]
	end,
})
M._identity = identity
M._state_root = state_root

return M
