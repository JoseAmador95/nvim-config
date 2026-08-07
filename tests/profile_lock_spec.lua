vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function read_file(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

local function fail(message)
	vim.api.nvim_err_writeln("profile_lock_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(vim.g.nvim_config_initialized == true, "init.lua did not complete")
				local repo_root = assert(vim.env.NVIM_CONFIG_ROOT, "NVIM_CONFIG_ROOT is missing")
				local lock = vim.json.decode(read_file(vim.fs.joinpath(repo_root, "lazy-lock.json")))
				local checked = 0
				local errors = {}

				for _, plugin in pairs(require("lazy").plugins()) do
					if type(plugin.url) == "string" and plugin.url ~= "" then
						checked = checked + 1
						local expected = lock[plugin.name] and lock[plugin.name].commit
						local stat = vim.uv.fs_stat(plugin.dir)
						if not expected then
							errors[#errors + 1] = plugin.name .. " is active but absent from lazy-lock.json"
						elseif not stat or stat.type ~= "directory" then
							errors[#errors + 1] = plugin.name
								.. " is missing or not a directory at "
								.. tostring(plugin.dir)
						else
							local result = vim.system({ "git", "-C", plugin.dir, "rev-parse", "HEAD" }, { text = true })
								:wait(10000)
							local actual = vim.trim(result.stdout or "")
							if result.code ~= 0 then
								errors[#errors + 1] = plugin.name .. " is not a readable Git checkout"
							elseif actual ~= expected then
								errors[#errors + 1] = ("%s: lock=%s checkout=%s"):format(plugin.name, expected, actual)
							end
						end
					end
				end

				assert(checked > 0, "profile exposed no remote plugins")
				assert(#errors == 0, "profile lock mismatch:\n  - " .. table.concat(errors, "\n  - "))
				print(("profile_lock_spec: %d active plugin checkouts match lazy-lock.json"):format(checked))
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end
			vim.cmd("quitall!")
		end)
	end,
})
