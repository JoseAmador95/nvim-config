-- Loaded with --cmd before init.lua. Extend argv here; the VimEnter assertions
-- then prove there is no delayed configuration-level lifecycle replay.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local existing_path = vim.fn.tempname() .. ".md"
local new_path = vim.fn.tempname() .. ".md"
assert(vim.fn.writefile({ "# second argument", "", "startup fixture" }, existing_path) == 0)
vim.fn.delete(new_path)
vim.cmd.argadd({ args = { existing_path, new_path } })

local filetype_events = {}
local observer = vim.api.nvim_create_augroup("StartupSpecObserver", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
	group = observer,
	callback = function(args)
		filetype_events[args.buf] = (filetype_events[args.buf] or 0) + 1
	end,
})

local function cleanup()
	vim.fn.delete(existing_path)
	vim.fn.delete(new_path)
end

local function fail(message)
	cleanup()
	vim.api.nvim_err_writeln("startup_spec: " .. message)
	vim.cmd("cquit")
end

local function same_path(left, right)
	local function canonical(path)
		return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
	end
	return canonical(left) == canonical(right)
end

local function assert_markdown_argument(label)
	local buf = vim.api.nvim_get_current_buf()
	assert(vim.bo[buf].filetype == "markdown", label .. " did not detect markdown")
	assert(
		filetype_events[buf] == 1,
		string.format("%s emitted FileType %d times (expected 1)", label, filetype_events[buf] or 0)
	)
	assert(require("render-markdown.core.manager").attached(buf), label .. " did not attach render-markdown")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(#vim.fn.argv() == 3, "startup fixture did not create a three-file argument list")
				assert_markdown_argument("first existing argv buffer")
				assert(package.loaded.gitsigns, "BufReadPre plugin did not load for the first argv buffer")
				assert(package.loaded["todo-comments"], "BufReadPost plugin did not load for the first argv buffer")

				vim.cmd("next")
				assert(
					same_path(vim.api.nvim_buf_get_name(0), existing_path),
					"second argv buffer was not selected: " .. vim.api.nvim_buf_get_name(0)
				)
				assert_markdown_argument("second existing argv buffer")

				vim.cmd("next")
				assert(
					same_path(vim.api.nvim_buf_get_name(0), new_path),
					"new argv buffer was not selected: " .. vim.api.nvim_buf_get_name(0)
				)
				assert(vim.fn.filereadable(new_path) == 0, "new argv fixture unexpectedly exists on disk")
				assert_markdown_argument("new argv buffer")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end

			cleanup()
			print("startup_spec: 3 tests passed")
			vim.cmd("quitall!")
		end)
	end,
})
