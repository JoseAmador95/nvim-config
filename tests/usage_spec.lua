local equal = require("tests.helpers").equal
local child = MiniTest.new_child_neovim()
local root = vim.fn.getcwd()
local lazy = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local directory
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			directory = vim.fn.tempname()
			child.start({ "-u", "NONE", "-i", "NONE" })
			child.lua_func(function(repo, path)
				vim.opt.runtimepath:prepend(repo)
				require("config.local_plugins").setup()
				vim.g.mapleader = " "
				vim.o.swapfile = false
				require("config.usage").setup({ enabled = true }, path .. "/usage.sqlite3")
			end, root, directory)
		end,
		post_case = function()
			child.stop()
			vim.fn.delete(directory, "rf")
		end,
	},
})

local function uses(action, mode)
	return child.lua_func(function(id, m)
		for _, row in ipairs(assert(require("config.usage").report("all", 0))) do
			if row.action == id and row.mode == (m or "n") then
				return row.uses
			end
		end
	end, action, mode)
end

T["string mappings preserve counts registers remaps leader expansion and insert escape"] = function()
	child.lua([[
		local map = require("config.usage").mapper("fixture")
		map("n", "<leader>d", "dd")
		map("n", "<leader>x", "<leader>d", { remap = true, replace_keycodes = false })
		map("i", "jj", "<Esc>")
		vim.g.mapleader = ","
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {"one", "two", "three", "four"})
	]])
	child.type_keys('"a2 x')
	equal({ "three", "four" }, child.api.nvim_buf_get_lines(0, 0, -1, false))
	equal("one\ntwo\n", child.fn.getreg("a"))
	equal(1, uses("fixture:<leader>x"))
	equal(1, uses("fixture:<leader>d"))
	child.type_keys("i", "hello", "jj")
	equal("n", child.fn.mode())
	equal(1, uses("fixture:jj", "i"))
end

T["callbacks preserve expr results visual operator and buffer scope"] = function()
	child.lua([[
		local map = require("config.usage").mapper("fixture")
		map("i", "zz", function() return "<Left>" end, {expr = true})
		map("x", "Q", "U", {buffer = 0})
		map("o", "Z", "iw")
		vim.api.nvim_buf_set_lines(0, 0, -1, false, {"lower words"})
	]])
	child.type_keys("viwQ")
	equal("LOWER words", child.api.nvim_get_current_line())
	child.type_keys("0dZ")
	equal(" words", child.api.nvim_get_current_line())
	child.type_keys("A", "ab", "zz", "X", "<Esc>")
	equal(" wordsaXb", child.api.nvim_get_current_line())
	equal(1, uses("fixture:Q", "x"))
	equal(1, uses("fixture:Z", "o"))
	equal(1, uses("fixture:zz", "i"))
	child.cmd("enew!")
	equal(0, child.fn.maparg("Q", "x", false, true).buffer)
end

T["pause resume report reset and typed commands keep their boundaries"] = function()
	child.lua([[
		require("config.usage").mapper("fixture")("n", "<leader>z", function() end)
	]])
	equal(0, uses("fixture:<leader>z"))
	child.type_keys(" z")
	child.cmd("UsagePause")
	child.type_keys(" z")
	child.lua('require("config.usage").mapper("fixture")("n", "<leader>a", function() end)')
	child.cmd("UsageResume")
	child.type_keys(" z")
	equal(2, uses("fixture:<leader>z"))
	equal(0, uses("fixture:<leader>a"))
	child.cmd("let g:private_command_argument = 'not-recorded'")
	equal(2, child.lua_get('#require("config.usage").report("all", 0)'))
	child.cmd("UsageStats mapping 0")
	equal(false, child.bo.modifiable)
	child.type_keys("q")
	child.lua([[
		vim.ui.select = function(_, _, callback) callback("Reset") end
		vim.cmd.UsageReset()
	]])
	equal(0, uses("fixture:<leader>z"))
end

T["palette counts dispatched actions without counting context or cancellation"] = function()
	child.lua([[
		local palette = require("config.action_palette")
		local context = require("config.menu.context")
		local function find(surface, id)
			for _, section in ipairs(palette.sections(context.capture(), surface)) do
				for _, item in ipairs(section.items) do
					if item.id == id then return item end
				end
			end
		end
		assert(find("palette", "edit.clear_search").run())
		local item = find("context", "edit.clear_search")
		if item then assert(item.run()) end
		vim.ui.select = function(_, _, callback) callback("Cancel") end
		assert(find("palette", "file.close_all").run())
	]])
	equal(1, uses("edit.clear_search", "-"))
	equal(0, uses("file.close_all", "-"))
	child.cmd("UsageStats palette 0")
	equal(false, child.bo.modifiable)
end

T["macro replays and command-line mappings count only the declared action"] = function()
	child.lua([[
		local map = require("config.usage").mapper("fixture")
		map("n", "<leader>z", function() vim.g.calls = (vim.g.calls or 0) + 1 end)
		map("c", "<C-g>", "<End>")
	]])
	child.type_keys("qa zq", "@a")
	equal(2, child.g.calls)
	equal(2, uses("fixture:<leader>z"))
	child.type_keys(":let g:private_argument = 'secret'", "<C-g>", "<CR>")
	equal("secret", child.g.private_argument)
	equal(1, uses("fixture:<C-g>", "c"))
	equal(2, child.lua_get('#require("config.usage").report("all", 0)'))
end

T["native Lazy keys count first and subsequent invocations once"] = function()
	child.lua_func(function(lazy_path, path)
		vim.opt.runtimepath:prepend(lazy_path)
		local spec = require("config.usage").spec({
			name = "usage-fixture",
			dir = path,
			keys = {
				{
					"<leader>t",
					function()
						vim.g.invocations = (vim.g.invocations or 0) + 1
					end,
				},
				{ "Z", "iw", mode = "o" },
			},
		}, "lazy-fixture")
		require("lazy").setup({ spec }, {
			root = path .. "/plugins",
			lockfile = path .. "/lazy-lock.json",
			install = { missing = false },
			checker = { enabled = false },
			change_detection = { enabled = false },
			readme = { enabled = false },
			performance = { rtp = { reset = false } },
		})
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one two three" })
	end, lazy, directory)
	child.type_keys("dZ")
	equal(" two three", child.api.nvim_get_current_line())
	child.type_keys(" t", " t")
	equal(2, child.g.invocations)
	equal(2, uses("lazy-fixture:<leader>t"))
	equal(1, uses("lazy-fixture:Z", "o"))
end

T["a missing sqlite3 CLI is reported on demand, never at startup"] = function()
	child.restart({ "-u", "NONE", "-i", "NONE" })
	local result = child.lua_func(function(repo, path)
		vim.opt.runtimepath:prepend(repo)
		require("config.local_plugins").setup()
		local notifications = {}
		vim.notify = function(message)
			notifications[#notifications + 1] = message
		end
		local exepath = vim.fn.exepath
		vim.fn.exepath = function(name)
			if name == "sqlite3" then
				return ""
			end
			return exepath(name)
		end
		local usage = require("config.usage")
		usage.setup({ enabled = true }, path .. "/usage.sqlite3")
		local startup = #notifications
		local status = usage.status()
		local _, report_err = usage.report("all", 0)
		vim.cmd("UsageResume")
		return { startup = startup, status = status, report_err = report_err, notifications = notifications }
	end, root, directory)
	equal(0, result.startup, "startup notified about the missing sqlite3 CLI")
	assert(result.status.enabled and not result.status.collecting, vim.inspect(result.status))
	assert(result.status.error:find("sqlite3", 1, true), vim.inspect(result.status))
	assert(result.report_err:find("collection is inactive: install the host sqlite3", 1, true), result.report_err)
	equal(1, #result.notifications, ":UsageResume did not report the missing CLI")
	assert(result.notifications[1]:find("sqlite3", 1, true), result.notifications[1])
end

T["terminal escape preserves the configured jj behaviour"] = function()
	child.lua([[
		require("config.usage").mapper("fixture")("t", "jj", "<C-\\><C-n>")
		vim.fn.jobstart({"cat"}, {term = true})
		vim.cmd.startinsert()
	]])
	child.type_keys("jj")
	equal("n", child.fn.mode())
	equal(1, uses("fixture:jj", "t"))
end

return T
