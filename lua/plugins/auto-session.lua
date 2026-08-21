local function is_file_buffer(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local name = vim.api.nvim_buf_get_name(buf)
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	return buftype == "" and name ~= ""
end

local function is_file_window(win)
	return is_file_buffer(vim.api.nvim_win_get_buf(win))
end

local function count_file_windows()
	local count = 0
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if is_file_window(win) then
			count = count + 1
		end
	end
	return count
end

local function should_skip_session_save()
	return count_file_windows() == 0
end

return {
	"rmagatti/auto-session",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>Ss", "<cmd>AutoSession save<cr>", desc = "Session save" },
		{ "<leader>Sr", "<cmd>AutoSession restore<cr>", desc = "Session restore current project" },
		{ "<leader>Sp", "<cmd>AutoSession search<cr>", desc = "Session search and restore" },
		{ "<leader>Sd", "<cmd>AutoSession deletePicker<cr>", desc = "Session delete" },
	},
	opts = {
		log_level = "error",
		auto_restore = false,
		auto_save = true,
		auto_create = true,
		auto_restore_last_session = false,
		show_auto_restore_notif = false,
		bypass_save_filetypes = { "oil", "snacks_dashboard" },
		auto_delete_empty_sessions = false,
		-- Use Snacks for the session picker (`:AutoSession search`) so session
		-- discovery matches the rest of the editor UI.
		session_lens = {
			picker = "snacks",
		},
		pre_save_cmds = {
			function()
				return not should_skip_session_save()
			end,
		},
	},
	config = function(_, opts)
		vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"
		local auto_session = require("auto-session")
		auto_session.setup(opts)
		if vim.env.NVIM_TMUX_REFRESH_RESTORE == "1" then
			vim.env.NVIM_TMUX_REFRESH_RESTORE = nil
			vim.api.nvim_create_autocmd("VimEnter", {
				once = true,
				callback = function()
					local ok, restored = pcall(auto_session.restore_session, nil, { show_message = false })
					if not ok or restored ~= true then
						local detail = not ok and tostring(restored) or "auto-session declined to restore"
						vim.notify("Could not restore refreshed dev session: " .. detail, vim.log.levels.ERROR)
					end
				end,
			})
		end
	end,
}
