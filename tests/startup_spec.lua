-- Loaded with --cmd, before init.lua, so its VimEnter callback runs before the
-- argv recovery callback registered by the configuration.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local filetype_events = 0

local function fail(message)
	vim.api.nvim_err_writeln("startup_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		local observer = vim.api.nvim_create_augroup("StartupSpecObserver", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			group = observer,
			callback = function()
				filetype_events = filetype_events + 1
			end,
		})
		vim.api.nvim_exec_autocmds("FileType", {
			buffer = vim.api.nvim_get_current_buf(),
			group = observer,
			modeline = false,
		})

		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(
					filetype_events == 1,
					string.format("FileType observer ran %d times (expected 1)", filetype_events)
				)
				assert(vim.b.lazy_argv_recovered == true, "argv buffer was not marked as recovered")

				local plugins = require("lazy.core.config").plugins
				assert(plugins["gitsigns.nvim"]._.loaded, "BufReadPre plugin did not load for argv buffer")
				assert(plugins["todo-comments.nvim"]._.loaded, "BufReadPost plugin did not load for argv buffer")
				assert(plugins["render-markdown.nvim"]._.loaded, "Markdown ft plugin did not load for argv buffer")
				assert(
					require("render-markdown.core.manager").attached(vim.api.nvim_get_current_buf()),
					"render-markdown did not attach to the argv buffer"
				)
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			print("startup_spec: 1 test passed")
			vim.cmd("quitall!")
		end)
	end,
})
