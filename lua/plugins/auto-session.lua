local state = {
	force_clear = false,
	clear_on_exit = false,
}

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

local function set_state(skip, force)
	if force then
		state.force_clear = true
		state.clear_on_exit = true
		return
	end

	if state.force_clear then
		return
	end

	state.clear_on_exit = skip
end

return {
	"rmagatti/auto-session",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		log_level = "error",
		auto_restore = true,
		auto_save = true,
		auto_create = true,
		auto_restore_last_session = false,
		show_auto_restore_notif = false,
		bypass_save_filetypes = { "neo-tree" },
		auto_delete_empty_sessions = true,
		pre_save_cmds = {
			function()
				if state.force_clear or should_skip_session_save() then
					state.clear_on_exit = true
					return false
				end

				return true
			end,
		},
	},
	config = function(_, opts)
		vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"
		require("auto-session").setup(opts)

		local group = vim.api.nvim_create_augroup("auto_session_user", { clear = true })
		local autosession = require("auto-session")

		local function is_restoring()
			if vim.g.SessionLoad then
				return true
			end
			return autosession.restore_in_progress
		end

		local function update_state()
			if is_restoring() then
				return
			end
			set_state(should_skip_session_save(), false)
		end

		local function delete_active_session()
			if vim.v.this_session and vim.v.this_session ~= "" then
				pcall(autosession.delete_session_file, vim.v.this_session, vim.fn.fnamemodify(vim.v.this_session, ":t"))
				return
			end
			pcall(autosession.delete_session)
		end

		vim.api.nvim_create_autocmd({
			"BufEnter",
			"BufDelete",
			"BufUnload",
			"BufWipeout",
			"BufWinEnter",
			"BufWinLeave",
			"WinClosed",
			"TabEnter",
			"TabClosed",
		}, {
			group = group,
			callback = function()
				vim.schedule(update_state)
			end,
		})

		vim.api.nvim_create_autocmd("QuitPre", {
			group = group,
			callback = function()
				if is_restoring() then
					return
				end

				if is_file_window(vim.api.nvim_get_current_win()) and count_file_windows() == 1 then
					set_state(true, true)
				end
			end,
		})

		vim.api.nvim_create_autocmd("VimEnter", {
			group = group,
			callback = update_state,
		})

		vim.api.nvim_create_autocmd("VimLeavePre", {
			group = group,
			callback = function()
				update_state()
				if state.clear_on_exit then
					delete_active_session()
				end
			end,
		})
	end,
}
