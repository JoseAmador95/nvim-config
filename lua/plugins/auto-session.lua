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

local exiting = false
local exit_flag_registered = false
local manual_save_active = false
local direct_save
local save_wrappers = setmetatable({}, { __mode = "k" })
local sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,localoptions"

local function notify_review_hook_failure(action, error_message)
	vim.notify(
		string.format("Could not %s code review for session: %s", action, tostring(error_message)),
		vim.log.levels.ERROR,
		{ title = "Session" }
	)
end

local function suspend_code_review_for_session()
	local loaded, code_review = pcall(require, "config.code_review")
	if not loaded or type(code_review) ~= "table" or type(code_review.suspend_for_session) ~= "function" then
		return true
	end

	local called, suspended, suspend_error = pcall(code_review.suspend_for_session)
	if not called or suspended ~= true then
		notify_review_hook_failure("suspend", called and suspend_error or suspended)
		return false
	end

	return true
end

local function restore_code_review_after_manual_save()
	local loaded, code_review = pcall(require, "config.code_review")
	if
		exiting
		or not loaded
		or type(code_review) ~= "table"
		or type(code_review.restore_after_session) ~= "function"
	then
		return
	end
	vim.schedule(function()
		if exiting then
			return
		end
		local restore_called, restored, restore_error = pcall(code_review.restore_after_session)
		if not restore_called or restored ~= true then
			notify_review_hook_failure("restore", restore_called and restore_error or restored)
		end
	end)
end

local function notify_log_hook_failure(action, error_message)
	vim.notify(
		string.format("Could not %s log following for session: %s", action, tostring(error_message)),
		vim.log.levels.ERROR,
		{ title = "Session" }
	)
end

local function suspend_log_follow_for_session()
	local log_watch = package.loaded["config.log_watch"]
	if type(log_watch) ~= "table" or type(log_watch.suspend_for_session) ~= "function" then
		return true
	end
	local called, suspended, suspend_error = pcall(log_watch.suspend_for_session)
	if not called or suspended ~= true then
		notify_log_hook_failure("suspend", called and suspend_error or suspended)
		return false
	end
	if exiting or type(log_watch.restore_after_session) ~= "function" then
		return true
	end
	vim.schedule(function()
		if exiting then
			return
		end
		local restore_called, restored, restore_error = pcall(log_watch.restore_after_session)
		if not restore_called or restored ~= true then
			notify_log_hook_failure("restore", restore_called and restore_error or restored)
		end
	end)
	return true
end

local function save_session_manually(session_name, save, save_opts)
	if not suspend_code_review_for_session() then
		return false
	end
	if not suspend_log_follow_for_session() then
		return false
	end
	if should_skip_session_save() then
		return false
	end
	manual_save_active = true
	local called, saved = pcall(save or direct_save or require("auto-session").save_session, session_name, save_opts)
	manual_save_active = false
	if not called or saved ~= true then
		notify_review_hook_failure("save", called and "auto-session declined to save" or saved)
		return false
	end
	restore_code_review_after_manual_save()
	return true
end

local function install_manual_save_wrapper(auto_session)
	local installed = save_wrappers[auto_session]
	if installed and auto_session.save_session == installed.wrapper then
		direct_save = installed.upstream
		return
	end
	local upstream_save = auto_session.save_session
	local wrapper = function(session_name, save_opts)
		if save_opts and save_opts.is_autosave then
			return upstream_save(session_name, save_opts)
		end
		return save_session_manually(session_name, upstream_save, save_opts)
	end
	direct_save = upstream_save
	save_wrappers[auto_session] = { upstream = upstream_save, wrapper = wrapper }
	auto_session.save_session = wrapper
end

return {
	"rmagatti/auto-session",
	lazy = false,
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{
			"<leader>Ss",
			function()
				return save_session_manually()
			end,
			desc = "Session save",
		},
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
		close_unsupported_windows = false,
		bypass_save_filetypes = { "oil", "snacks_dashboard" },
		auto_delete_empty_sessions = false,
		-- Use Snacks for the session picker (`:AutoSession search`) so session
		-- discovery matches the rest of the editor UI.
		session_lens = {
			picker = "snacks",
		},
		pre_save_cmds = {
			function()
				if not manual_save_active and not suspend_code_review_for_session() then
					return false
				end
				if not manual_save_active and not suspend_log_follow_for_session() then
					return false
				end
				return not should_skip_session_save()
			end,
		},
	},
	config = function(_, opts)
		-- Terminal lifecycle buffers are process views, not durable editor state.
		-- Omitting `terminal` prevents :mksession and auto-session from
		-- resurrecting an ephemeral process during restore.
		vim.o.sessionoptions = sessionoptions
		if not exit_flag_registered then
			local group = vim.api.nvim_create_augroup("NvimConfigAutoSession", { clear = true })
			vim.api.nvim_create_autocmd("VimLeavePre", {
				group = group,
				desc = "Keep suspended transient tabs closed while exiting",
				callback = function()
					exiting = true
				end,
			})
			exit_flag_registered = true
		end
		local auto_session = require("auto-session")
		install_manual_save_wrapper(auto_session)
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
