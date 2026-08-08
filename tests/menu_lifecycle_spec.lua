vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("menu_lifecycle_spec: " .. message)
	vim.cmd("cquit")
end

local function left_mouse_mapping()
	local mapping = vim.fn.maparg("<LeftMouse>", "n", false, true)
	return type(mapping) == "table" and mapping or {}
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(left_mouse_mapping().lhs == nil, "fixture started with a global LeftMouse mapping")
				assert(package.loaded["menu.state"] == nil, "menu.nvim state loaded before first use")

				vim.cmd("tabnew")
				vim.cmd("tabnew")
				local unopened_target = vim.api.nvim_get_current_tabpage()
				assert(require("config.tabs").close(unopened_target), "ordinary current tab did not close")
				assert(package.loaded["menu.state"] == nil, "ordinary tab close activated lazy menu.nvim")

				vim.cmd("tabnew")
				local target = vim.api.nvim_get_current_tabpage()
				require("config.menu").open_context()

				local state = require("menu.state")
				local menu_buf = assert(state.bufids[1], "mouse context menu did not create a buffer")
				assert(#vim.fn.win_findbuf(menu_buf) > 0, "mouse context menu is not displayed")
				local stale_callback = assert(left_mouse_mapping().callback, "menu.nvim did not install LeftMouse")

				assert(require("config.tabs").close(target), "current tab did not close")
				assert(not vim.api.nvim_tabpage_is_valid(target), "target tab remains valid")
				assert(not vim.api.nvim_buf_is_valid(menu_buf), "dismiss left the menu buffer valid")
				assert(#state.bufids == 0, "dismiss left stale menu buffer ids")
				assert(left_mouse_mapping().lhs == nil, "dismiss left menu.nvim's global LeftMouse mapping")
				assert(pcall(stale_callback), "the former LeftMouse callback still raises E813")

				require("config.menu").open_context()
				local hidden_buf = assert(state.bufids[1], "recovery menu did not create a buffer")
				local hidden_win = assert(vim.fn.bufwinid(hidden_buf) > 0 and vim.fn.bufwinid(hidden_buf))
				vim.api.nvim_win_close(hidden_win, true)
				assert(#vim.fn.win_findbuf(hidden_buf) == 0, "recovery fixture menu remains displayed")
				assert(require("config.menu").dismiss(), "stale menu dismiss reported failure")
				assert(not vim.api.nvim_buf_is_valid(hidden_buf), "stale menu buffer was not deleted")
				assert(#state.bufids == 0, "stale recovery retained buffer ids")
				assert(left_mouse_mapping().lhs == nil, "stale recovery retained the owned LeftMouse mapping")

				vim.cmd("tabnew")
				local raw_target = vim.api.nvim_get_current_tabpage()
				require("config.menu").open_context()
				local raw_buf = assert(state.bufids[1], "raw tabclose menu did not create a buffer")
				local raw_callback = assert(left_mouse_mapping().callback, "raw tabclose menu has no LeftMouse")
				vim.cmd("tabclose")
				assert(not vim.api.nvim_tabpage_is_valid(raw_target), "raw tabclose left its target valid")
				assert(not vim.api.nvim_buf_is_valid(raw_buf), "TabClosed recovery left the raw menu buffer valid")
				assert(#state.bufids == 0, "TabClosed recovery retained stale buffer ids")
				assert(left_mouse_mapping().lhs == nil, "TabClosed recovery retained the owned LeftMouse mapping")
				assert(pcall(raw_callback), "the raw-tabclose LeftMouse callback still raises E813")

				vim.cmd("tabnew")
				local preserved_tab = vim.api.nvim_get_current_tabpage()
				require("config.menu").open_context()
				local preserved_buf = assert(state.bufids[1], "preservation menu did not create a buffer")
				local background_tab = vim.api.nvim_list_tabpages()[1]
				assert(background_tab ~= preserved_tab, "preservation fixture has no background tab")
				vim.cmd("tabclose 1")
				assert(vim.api.nvim_tabpage_is_valid(preserved_tab), "non-current close removed the current tab")
				assert(vim.api.nvim_buf_is_valid(preserved_buf), "non-current close deleted the displayed menu")
				assert(#vim.fn.win_findbuf(preserved_buf) > 0, "non-current close hid the displayed menu")
				assert(left_mouse_mapping().callback ~= nil, "non-current close removed the active mouse mapping")
				assert(require("config.menu").dismiss(), "preserved menu did not dismiss cleanly")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			print("menu_lifecycle_spec: tab close and stale mouse-menu recovery passed")
			vim.cmd("quitall!")
		end)
	end,
})
