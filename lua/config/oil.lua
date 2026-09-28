local editor = require("config.editor")
local oil = require("oil")
local oil_util = require("oil.util")

local M = {}

---Open local files through tab-first while retaining Oil's selection lifecycle.
---@return boolean
function M.open_selection()
	local entry = oil.get_cursor_entry()
	if not entry then
		return false
	end
	if oil_util.is_directory(entry) or not oil.get_current_dir() then
		oil.select()
		return true
	end
	oil.select({
		handle_buffer_callback = function(bufnr)
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path ~= "" then
				editor.open_file_in_tab(path)
			end
		end,
	})
	return true
end

---Configure Oil with the host-owned tab-opening callback.
---@param opts table
function M.setup(opts)
	opts = vim.deepcopy(opts or {})
	opts.keymaps = opts.keymaps or {}
	opts.keymaps["<CR>"] = {
		desc = "Open (files reuse a tab, dirs navigate in)",
		callback = M.open_selection,
	}
	return oil.setup(opts)
end

return M
