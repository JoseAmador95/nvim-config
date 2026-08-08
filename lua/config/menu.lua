local actions = require("config.menu.actions")
local backend = require("config.menu.backend").default()
local catalog = require("config.menu.catalog")
local context = require("config.menu.context")

local M = {}

local function current_context()
	return context.new({
		filetype = vim.bo.filetype,
		mode = vim.fn.mode(),
	})
end

local function descriptors(menu_context)
	return catalog.build(menu_context, actions.run)
end

---The menu belongs only to full terminal Neovim, never VS Code or nvimpager.
---@return boolean
function M.enabled()
	local ok, pager = pcall(require, "config.pager")
	return not vim.g.vscode and not (ok and pager.active)
end

function M.open()
	if not M.enabled() then
		return
	end
	if backend:is_open() then
		backend:close()
		return
	end
	M.ensure_open()
end

function M.ensure_open()
	if not M.enabled() or backend:is_open() then
		return
	end
	backend:show(descriptors(current_context()), { border = true })
end

---Dismiss any displayed menu or recover stale menu.nvim state.
---@return boolean
function M.dismiss()
	if not M.enabled() then
		return false
	end
	return backend:close()
end

---Recover only stale state from an already-loaded menu.nvim instance.
---@return boolean
function M.recover_stale()
	if not M.enabled() then
		return false
	end
	return backend:recover_stale()
end

function M.open_context()
	if not M.enabled() then
		return
	end
	if backend:is_open() then
		backend:close()
		return
	end

	local menu_context = current_context()
	if not menu_context.visual then
		pcall(vim.cmd, "normal! \\<RightMouse>")
	end
	backend:show(descriptors(menu_context), { mouse = true, border = true })
end

function M.setup()
	if not M.enabled() then
		return
	end

	vim.keymap.set({ "n", "v" }, "<RightMouse>", M.open_context, { desc = "Open menu" })

	local group = vim.api.nvim_create_augroup("NvimConfigMenu", { clear = true })
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		desc = "Recover menu state after an external tab close",
		callback = function()
			M.recover_stale()
		end,
	})
end

return M
