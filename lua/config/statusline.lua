local M = {}

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
	buf = buf or vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_is_valid(buf) then
		vim.b[buf].nvim_config_root = root_for_buffer(buf)
	end
end

local function root()
	return vim.b.nvim_config_root
end

function M.navic()
	local navic = package.loaded["nvim-navic"]
	if not navic or not navic.is_available(0) then
		return ""
	end
	local data = navic.get_data(0)
	local item = type(data) == "table" and data[#data] or nil
	return item and ((item.icon or "") .. (item.name or "")) or ""
end

function M.python()
	local project = require("config.python").root(0)
	if not project then
		return ""
	end
	local name = require("config.python").venv_name(project)
	return name ~= "" and ("Py:" .. name) or ""
end

function M.cmake()
	local state = root() and require("config.cmake").status(root()) or nil
	if not state then
		return ""
	end
	local name = state.preset or (state.build_dir and vim.fs.basename(state.build_dir))
	return name and ("CMake:" .. name) or ""
end

function M.clangd()
	if require("config.clangd").profile() == "light" then
		return "clangd:light"
	end
	return ""
end

function M.devpod()
	local state = vim.b.nvim_devpod_status or vim.g.nvim_devpod_status
	if type(state) == "string" then
		return state ~= "" and state or ""
	end
	if type(state) == "table" and state.provider and state.project then
		return table.concat({ "DevPod", state.provider, state.project }, " · ")
	end
	return ""
end

function M.review()
	local ok, review = pcall(require, "config.code_review")
	local status = ok and review.status() or nil
	if not status or not status.active then
		return ""
	end
	local entry = status.entry or {}
	return table.concat({
		"REV " .. (status.mode_on and "ON" or "OFF"),
		tostring(status.scope_kind or "review") .. ":" .. tostring(status.scope_label or "unknown"),
		tostring(entry.layer or "history"),
		tostring(status.layout or "inline") .. "/" .. tostring(status.context or "hunks"),
		"comments:" .. (status.inline_comments and "on" or "off"),
		tostring(entry.side or "CURRENT"),
		tostring(entry.path or "<none>"),
	}, " · ")
end

function M.setup_refresh()
	local group = vim.api.nvim_create_augroup("NvimConfigStatusline", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
		group = group,
		callback = function(event)
			M.update_root(event.buf)
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = {
			"NvimConfigPythonChanged",
			"NvimConfigCMakeChanged",
			"NvimConfigDevPodChanged",
			"NvimConfigReviewChanged",
		},
		callback = function()
			local ok, lualine = pcall(require, "lualine")
			if ok then
				lualine.refresh({ place = { "statusline" } })
			end
		end,
	})
	M.update_root(0)
end

return M
