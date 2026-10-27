local T = MiniTest.new_set()
vim.o.shadafile = "NONE"
vim.o.swapfile = false

T["oil git status"] = function()
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
end
return T
