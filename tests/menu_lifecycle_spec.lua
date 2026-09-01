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
				assert(package.loaded.action_palette == nil, "action-palette core loaded before first use")
				assert(package.loaded["config.action_palette"] == nil, "action palette catalog loaded before first use")
				assert(vim.fn.exists(":MenuOpen") == 2, "MenuOpen was not registered before first use")
				assert(
					vim.fn.maparg("<RightMouse>", "n") ~= "",
					"right-click mapping was not registered before first use"
				)
				assert(_G.NvimConfigCloseTab == nil, "obsolete global tabline close callback is present")
				require("lazy").load({ plugins = { "bufferline.nvim" } })
				local bridge = assert(_G.___bufferline_private, "installed bufferline click bridge is missing")
				assert(type(bridge.handle_close) == "function", "installed bufferline close bridge is missing")
				assert(type(bridge.handle_click) == "function", "installed bufferline mouse bridge is missing")

				local function close_through_bufferline(tabpage, button)
					if button then
						bridge.handle_click(tabpage, nil, button)
					else
						bridge.handle_close(tabpage)
					end
					assert(
						vim.wait(500, function()
							return not vim.api.nvim_tabpage_is_valid(tabpage)
						end, 5),
						"bufferline did not close the requested stable tab handle"
					)
				end

				vim.cmd("tabnew")
				vim.cmd("tabnew")
				local unopened_target = vim.api.nvim_get_current_tabpage()
				local tabs = require("config.tabs")
				local forwarded = {}
				local original_request = tabs.request_close
				tabs.request_close = function(tabpage)
					forwarded[#forwarded + 1] = tabpage
					return true
				end
				local bridge_ok, bridge_error = xpcall(function()
					bridge.handle_close(unopened_target)
					bridge.handle_click(unopened_target, nil, "m")
				end, debug.traceback)
				tabs.request_close = original_request
				assert(bridge_ok, bridge_error)
				assert(
					vim.deep_equal(forwarded, { unopened_target, unopened_target }),
					"installed bufferline changed or bypassed a configured stable-handle close callback"
				)
				assert(vim.api.nvim_tabpage_is_valid(unopened_target), "callback probe unexpectedly closed its tab")
				close_through_bufferline(unopened_target)
				assert(package.loaded["menu.state"] == nil, "ordinary tab close activated lazy menu.nvim")

				vim.cmd("tabnew")
				local context_target = vim.api.nvim_get_current_tabpage()
				bridge.handle_click(context_target, nil, "r")
				assert(vim.api.nvim_tabpage_is_valid(context_target), "right click closed its tab")
				local context_state = require("menu.state")
				local context_buf = assert(context_state.bufids[1], "right click did not open the context menu")
				assert(#vim.fn.win_findbuf(context_buf) > 0, "right-click context menu is not displayed")
				assert(require("config.menu").dismiss(), "right-click context menu did not dismiss")
				close_through_bufferline(context_target, "m")

				vim.cmd("tabnew")
				local target = vim.api.nvim_get_current_tabpage()
				require("config.menu").open_context()

				local state = require("menu.state")
				local menu_buf = assert(state.bufids[1], "mouse context menu did not create a buffer")
				assert(#vim.fn.win_findbuf(menu_buf) > 0, "mouse context menu is not displayed")
				local stale_callback = assert(left_mouse_mapping().callback, "menu.nvim did not install LeftMouse")

				close_through_bufferline(target, "m")
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
				close_through_bufferline(background_tab, "m")
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
