local M = {}

local review = require("config.code_review")
local clangd_policy = require("config.local_config").plugin("clangd_compile_db", {
	profile = "full",
})

local caches = {}

local function normalize_buffer(buf)
	if not buf or buf == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return buf
end

local function cache(buf)
	local state = caches[buf]
	if not state then
		state = {}
		caches[buf] = state
	end
	return state
end

local function cached(name)
	local state = caches[vim.api.nvim_get_current_buf()]
	return state and state[name] or ""
end

local function root_for_buffer(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	local start = name ~= "" and name or vim.uv.cwd()
	if not start then
		return nil
	end
	local root = vim.fs.root(start, ".git")
	return root and (vim.uv.fs_realpath(root) or vim.fs.normalize(root)) or nil
end

function M.update_root(buf)
	buf = normalize_buffer(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.b[buf].nvim_config_root = root_for_buffer(buf)
	end
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
	local project = type(python) == "table" and type(python.root) == "function" and python.root(buf) or nil
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

function M.refresh_buffer(buf)
	buf = normalize_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	M.update_root(buf)
	update_navic(buf)
	update_python(buf)
	update_cmake(buf)
	update_clangd(buf)
	update_devcontainer(buf)
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

function M.setup_refresh()
	local group = vim.api.nvim_create_augroup("NvimConfigStatusline", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
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
			M.refresh_buffer(event_buffer(event))
			refresh_lualine()
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			caches[event.buf] = nil
		end,
	})
	M.refresh_buffer(0)
end
return M
