local M = {}

local review = require("config.code_review")
local clangd_policy = require("config.local_config").plugin("clangd_compile_db", {
	profile = "full",
})

local caches = {}
local diagnostic_dirty = {}
local diagnostic_refresh_pending = false
local refresh_generation = 0
local EMPTY_DIAGNOSTICS = { error = 0, warn = 0, info = 0, hint = 0 }

local function normalize_buffer(buf)
	if not buf or buf == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return buf
end

local function cache(buf)
	local state = caches[buf]
	if not state then
		state = { diagnostics = EMPTY_DIAGNOSTICS }
		caches[buf] = state
	end
	return state
end

local function cached(name)
	local state = caches[vim.api.nvim_get_current_buf()]
	return state and state[name] or ""
end

local function root_input(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or vim.uv.cwd()
	return start and ((name ~= "" and "file:" or "cwd:") .. start) or nil, start
end

local function root_for_buffer(start)
	local root = vim.fs.root(start, ".git")
	return root and (vim.uv.fs_realpath(root) or vim.fs.normalize(root)) or nil
end

function M.update_root(buf)
	buf = normalize_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local state = cache(buf)
	local key, start = root_input(buf)
	if state.root_key == key then
		vim.b[buf].nvim_config_root = state.root
		return false
	end
	state.root_key = key
	state.root = start and root_for_buffer(start) or nil
	vim.b[buf].nvim_config_root = state.root
	return true
end

local function update_navic(buf)
	local label = ""
	local navic = package.loaded["nvim-navic"]
	if navic and navic.is_available(buf) then
		local data = navic.get_data(buf)
		local item = type(data) == "table" and data[#data] or nil
		label = item and ((item.icon or "") .. (item.name or "")) or ""
	end
	cache(buf).navic = label
end

local function update_python(buf)
	local label = ""
	local python = package.loaded["config.python"]
	local project = type(python) == "table"
			and type(python.root) == "function"
			and python.root(buf, vim.b[buf].nvim_config_root)
		or nil
	if project and type(python.venv_name) == "function" then
		local name = python.venv_name(project)
		label = name ~= "" and ("Py:" .. name) or ""
	end
	cache(buf).python = label
end

local function update_cmake(buf)
	local root = vim.b[buf].nvim_config_root
	local cmake = package.loaded["config.cmake"]
	local state = root and type(cmake) == "table" and type(cmake.status) == "function" and cmake.status(root) or nil
	if state and state.valid == false then
		cache(buf).cmake = "CMake:invalid"
		return
	end
	local name = state and (state.preset or (state.build_dir and vim.fs.basename(state.build_dir))) or nil
	cache(buf).cmake = name and ("CMake:" .. name) or ""
end

local function update_clangd(buf)
	cache(buf).clangd = clangd_policy.profile == "light" and "clangd:light" or ""
end

local function update_devcontainer(buf)
	local state = vim.b[buf].nvim_devcontainer_status or vim.g.nvim_devcontainer_status
	local label = ""
	if type(state) == "string" then
		label = state ~= "" and state or ""
	elseif type(state) == "table" and state.project then
		label = table.concat({ "Dev Container", state.project, state.network or "offline" }, " · ")
	end
	cache(buf).devcontainer = label
end

local function update_review(buf)
	local status = review.status()
	local label = ""
	if status and status.active then
		local entry = status.entry or {}
		label = table.concat({
			"REV " .. (status.mode_on and "ON" or "OFF"),
			tostring(status.scope_kind or "review") .. ":" .. tostring(status.scope_label or "unknown"),
			tostring(entry.layer or "history"),
			tostring(status.layout or "inline") .. "/" .. tostring(status.context or "hunks"),
			"comments:" .. (status.inline_comments and "on" or "off"),
			tostring(entry.side or "CURRENT"),
			tostring(entry.path or "<none>"),
		}, " · ")
	end
	cache(buf).review = label
end

local function diagnostic_counts(buf)
	local ok, counts = pcall(vim.diagnostic.count, buf)
	counts = ok and type(counts) == "table" and counts or {}
	return {
		error = counts[vim.diagnostic.severity.ERROR] or 0,
		warn = counts[vim.diagnostic.severity.WARN] or 0,
		info = counts[vim.diagnostic.severity.INFO] or 0,
		hint = counts[vim.diagnostic.severity.HINT] or 0,
	}
end

local function update_diagnostics(buf)
	cache(buf).diagnostics = diagnostic_counts(buf)
end

function M.refresh_buffer(buf)
	buf = normalize_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local state = cache(buf)
	local root_changed = M.update_root(buf)
	update_navic(buf)
	if not state.initialized or root_changed then
		update_python(buf)
		update_cmake(buf)
	end
	if not state.initialized then
		update_clangd(buf)
		update_devcontainer(buf)
		update_diagnostics(buf)
		state.initialized = true
	end
	update_review(buf)
end

function M.navic()
	return cached("navic")
end

function M.python()
	return cached("python")
end

function M.cmake()
	return cached("cmake")
end

function M.clangd()
	return cached("clangd")
end

function M.devcontainer()
	return cached("devcontainer")
end

function M.review()
	return cached("review")
end

-- Lualine calls diagnostic sources on every render. Returning this cached
-- table keeps that hot path O(1); DiagnosticChanged owns recomputation.
function M.diagnostics()
	local state = caches[vim.api.nvim_get_current_buf()]
	return state and state.diagnostics or EMPTY_DIAGNOSTICS
end

local function refresh_lualine()
	local lualine = package.loaded.lualine
	if type(lualine) == "table" and type(lualine.refresh) == "function" then
		lualine.refresh({ place = { "statusline" } })
	end
end

local function event_buffer(event)
	if type(event.buf) == "number" and event.buf ~= 0 then
		return event.buf
	end
	return vim.api.nvim_get_current_buf()
end

local function update_cached_buffers(callback)
	for buf in pairs(caches) do
		if vim.api.nvim_buf_is_valid(buf) then
			callback(buf)
		else
			caches[buf] = nil
			diagnostic_dirty[buf] = nil
		end
	end
end

local function queue_diagnostic_refresh(buf)
	if not caches[buf] then
		cache(buf)
	end
	diagnostic_dirty[buf] = true
	if diagnostic_refresh_pending then
		return
	end
	diagnostic_refresh_pending = true
	local generation = refresh_generation
	vim.schedule(function()
		if generation ~= refresh_generation then
			return
		end
		diagnostic_refresh_pending = false
		local dirty = diagnostic_dirty
		diagnostic_dirty = {}
		local updated = false
		for dirty_buf in pairs(dirty) do
			if caches[dirty_buf] and vim.api.nvim_buf_is_valid(dirty_buf) then
				update_diagnostics(dirty_buf)
				updated = true
			end
		end
		if updated then
			refresh_lualine()
		end
	end)
end

function M.setup_refresh()
	refresh_generation = refresh_generation + 1
	diagnostic_dirty = {}
	diagnostic_refresh_pending = false
	local group = vim.api.nvim_create_augroup("NvimConfigStatusline", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "BufFilePost", "DirChanged" }, {
		group = group,
		callback = function(event)
			M.refresh_buffer(event_buffer(event))
			refresh_lualine()
		end,
	})
	vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
		group = group,
		callback = function(event)
			local buf = event_buffer(event)
			if vim.api.nvim_buf_is_valid(buf) then
				update_navic(buf)
				update_python(buf)
			end
			refresh_lualine()
		end,
	})
	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(event)
			queue_diagnostic_refresh(event_buffer(event))
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		callback = function(event)
			local buf = event_buffer(event)
			if vim.api.nvim_buf_is_valid(buf) then
				update_navic(buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "NvimConfig*Changed",
		callback = function(event)
			if event.match == "NvimConfigPythonChanged" then
				update_cached_buffers(update_python)
			elseif event.match == "NvimConfigCMakeChanged" then
				update_cached_buffers(update_cmake)
			elseif event.match == "NvimConfigDevContainerChanged" then
				update_cached_buffers(update_devcontainer)
			elseif event.match == "NvimConfigReviewChanged" then
				update_cached_buffers(update_review)
			else
				M.refresh_buffer(event_buffer(event))
			end
			refresh_lualine()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			caches[event.buf] = nil
			diagnostic_dirty[event.buf] = nil
		end,
	})
	M.refresh_buffer(0)
end
return M
