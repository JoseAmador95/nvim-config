vim.o.shadafile = "NONE"
vim.o.swapfile = false

local target = assert(vim.env.NVIM_CONFIG_HEX_FILE, "NVIM_CONFIG_HEX_FILE is missing")
local expected = assert(vim.env.NVIM_CONFIG_HEX_EXPECTED, "NVIM_CONFIG_HEX_EXPECTED is missing")
assert(expected == "binary" or expected == "text", "NVIM_CONFIG_HEX_EXPECTED must be binary or text")

local function same_path(left, right)
	local function canonical(path)
		return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
	end
	return canonical(left) == canonical(right)
end

local function fail(message)
	vim.api.nvim_err_writeln("hex_startup_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(same_path(vim.api.nvim_buf_get_name(0), target), "initial argument was not opened")
				assert(package.loaded.hex == nil, "unsafe upstream hex module was loaded")
				assert(package.loaded["hex.utils"] == nil, "unsafe upstream hex utilities were loaded")
				if expected == "binary" then
					assert(vim.b.hex == true, "initial binary argument was not marked as hex")
					assert(vim.bo.filetype == "xxd", "initial binary argument was not rendered as xxd")
					assert(
						(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""):match("^00000000:"),
						"initial binary argument has no xxd output"
					)
				else
					assert(vim.b.hex ~= true, "initial text argument was marked as hex")
					assert(vim.bo.filetype ~= "xxd", "initial text argument was rendered as xxd")
					assert(
						vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "plain text" }),
						"initial text argument contents changed"
					)
				end
			end, debug.traceback)
			if not ok then
				fail(err)
				return
			end
			print("hex_startup_spec: initial " .. expected .. " detection passed")
			vim.cmd("quitall!")
		end)
	end,
})
