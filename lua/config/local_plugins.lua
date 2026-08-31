-- Register repository-local product boundaries without involving Lazy or its
-- lockfile. The order is the extraction plan's canonical 17-product order.
local M = {}

local NAMES = {
	"native-review.nvim",
	"exact-editor.nvim",
	"devcontainer-editor.nvim",
	"tab-first.nvim",
	"terminal-lifecycle.nvim",
	"project-python.nvim",
	"action-palette.nvim",
	"diagram-view.nvim",
	"log-workbench.nvim",
	"repo-scratch.nvim",
	"coverage-workbench.nvim",
	"just-workbench.nvim",
	"clangd-compile-db.nvim",
	"trusted-workspace.nvim",
	"verified-tools.nvim",
	"treesitter-runtime.nvim",
	"theme-router.nvim",
}

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"), "Could not resolve local plugin harness")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
local local_root = vim.fs.joinpath(config_root, "local-plugins")
local shared_lua = vim.fs.joinpath(local_root, "_shared", "lua")
local configured = false

local function paths()
	local result = {}
	for index, name in ipairs(NAMES) do
		result[index] = vim.fs.joinpath(local_root, name)
	end
	return result
end

---Return the canonical local runtime names as a caller-owned copy.
---@return string[]
function M.names()
	return vim.deepcopy(NAMES)
end

---Return the canonical absolute runtime paths as a caller-owned copy.
---@return string[]
function M.paths()
	return paths()
end

---Return the non-runtime Lua library root that owns the shared value contracts.
---@return string
function M.shared_lua()
	return shared_lua
end

---Prepend every local runtime exactly once in canonical order.
---@return string[] paths
function M.setup()
	local configured_paths = paths()
	if not configured then
		package.path = table.concat({
			shared_lua .. "/?.lua",
			shared_lua .. "/?/init.lua",
			package.path,
		}, ";")
		for index = #configured_paths, 1, -1 do
			vim.opt.runtimepath:prepend(configured_paths[index])
		end
		configured = true
	end
	return vim.deepcopy(configured_paths)
end

return M
