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
				assert(vim.fn.exists(":CloseTab") == 2, "full editor CloseTab command is missing")
				local close_map = vim.fn.maparg("<leader>q", "n", false, true)
				assert(close_map.rhs == "<cmd>CloseTab<cr>", "full editor close mapping bypasses CloseTab")
				local close_all_map = vim.fn.maparg("<leader>Q", "n", false, true)
				assert(close_all_map.rhs == "<cmd>CloseAll<cr>", "CloseAll mapping drifted")
				require("lazy").load({ plugins = { "bufferline.nvim" } })

				local original_visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
				local original_pmenu = vim.api.nvim_get_hl(0, { name = "PmenuSel", link = false })
				local selected_groups = {
					"BufferLineTabSelected",
					"BufferLineBufferSelected",
					"BufferLineSeparatorSelected",
					"BufferLineIndicatorSelected",
				}
				vim.api.nvim_set_hl(0, "Visual", { bg = 0x123456 })
				for _, group in ipairs(selected_groups) do
					vim.cmd("highlight clear " .. group)
				end
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_visual" })
				for _, group in ipairs(selected_groups) do
					assert(
						vim.api.nvim_get_hl(0, { name = group, link = false }).bg == 0x123456,
						group .. " did not repaint from Visual on ColorScheme"
					)
				end
				for _, group in ipairs({ "BufferLineTabSelected", "BufferLineBufferSelected" }) do
					local selected_label = vim.api.nvim_get_hl(0, { name = group, link = false })
					assert(selected_label.bold and not selected_label.italic, group .. " emphasis drifted")
				end
				assert(
					vim.api.nvim_get_hl(0, { name = "BufferLineIndicatorSelected", link = false }).fg
						== vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg,
					"selected tab indicator does not use DiagnosticInfo"
				)

				vim.api.nvim_set_hl(0, "Visual", {})
				vim.api.nvim_set_hl(0, "PmenuSel", { bg = 0x654321 })
				for _, group in ipairs(selected_groups) do
					vim.cmd("highlight clear " .. group)
				end
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_fallback" })
				assert(
					vim.api.nvim_get_hl(0, { name = "BufferLineTabSelected", link = false }).bg == 0x654321,
					"selected tab did not repaint from the PmenuSel fallback"
				)
				vim.api.nvim_set_hl(0, "Visual", original_visual)
				vim.api.nvim_set_hl(0, "PmenuSel", original_pmenu)
				vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "tabs_spec_restore" })

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
