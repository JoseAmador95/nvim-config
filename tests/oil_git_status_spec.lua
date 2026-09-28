vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("oil_git_status_spec: " .. tostring(message))
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(package.loaded["oil-git-status"] == nil, "adapter loaded before OilEnter")
				package.loaded["oil-git-status.system"] = {
					system = function(_, _, callback)
						callback({ code = 1, stdout = "", stderr = "fixture" })
					end,
				}
				local buf = vim.api.nvim_create_buf(true, false)
				vim.api.nvim_buf_set_name(buf, "oil:///private/tmp/")
				vim.api.nvim_exec_autocmds("User", {
					pattern = "OilEnter",
					modeline = false,
					data = { buf = buf },
				})
				assert(type(package.loaded["oil-git-status"]) == "table", "first OilEnter did not load adapter")
				assert(vim.b[buf].oil_git_status_started == true, "replayed OilEnter missed its first buffer")
				vim.api.nvim_buf_delete(buf, { force = true })
			end, debug.traceback)
			if not ok then
				fail(err)
				return
			end
			print("oil_git_status_spec: lazy first-event activation passed")
			vim.cmd("quitall!")
		end)
	end,
})
