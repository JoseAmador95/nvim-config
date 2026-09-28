vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

package.loaded["config.pager"] = { active = false }
local opened = {}
package.loaded["config.editor"] = {
	open_file_in_tab = function(path, options)
		opened[#opened + 1] = { path = path, options = options }
	end,
}

local snacks = require("plugins.snacks")
local open_in_tab = snacks.opts.picker.actions.open_in_tab

local function picker()
	return {
		closed = 0,
		close = function(self)
			self.closed = self.closed + 1
		end,
	}
end

local function reset_editor()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.bo[bufnr].modified = false
		end
	end
	pcall(vim.cmd, "silent! tabonly!")
	pcall(vim.cmd, "silent! only!")
	vim.cmd("enew!")
	opened = {}
end

test("generic Snacks scratch state is isolated from repo-scratch leases", function()
	local generic = snacks.opts.scratch.root
	local leased = vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "scratch")
	equal(vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "snacks-scratch"), generic, "generic scratch root")
	assert(generic ~= leased, "generic Snacks scratch shares repo-scratch lease state")
end)

test("review choices keep their native callback and hide only their own text filter", function()
	local select = snacks.opts.picker.sources.select
	local options = select.kinds.native_review
	assert(select.confirm == false, "global file confirm would replace the select callback")
	assert(select.focus == nil and select.layout == nil, "review options leaked into ordinary selectors")
	equal("list", options.focus, "review menu did not focus its list")
	equal({ "input", "preview" }, options.layout.hidden, "review menu exposed a filter")
	assert(options.matcher.sort_empty == false, "review menu could reorder its numbered choices")
	for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "R", "<Insert>", "/", "<a-w>", "<Tab>", "<S-Tab>" }) do
		equal("review_noop", options.win.list.keys[key], "review key entered a text input: " .. key)
	end
	assert(options.actions.focus_input == options.actions.review_noop)
	assert(options.actions.toggle_focus == options.actions.review_noop)
	assert(options.actions.cycle_win == options.actions.review_noop)
end)

test("short review menus confirm digits and long menus preserve native counts", function()
	local options = snacks.opts.picker.sources.select.kinds.native_review
	local buf = vim.api.nvim_create_buf(false, true)
	local instance = {
		count = function()
			return 5
		end,
		list = {
			win = { buf = buf },
			count = function()
				return 5
			end,
		},
	}
	local moved, confirmed
	instance.list.move = function(_, row, absolute)
		assert(absolute)
		moved = row
	end
	instance.action = function(_, action)
		assert(action == "confirm")
		confirmed = (confirmed or 0) + 1
	end
	options.on_show(instance)
	local mappings = {}
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		mappings[mapping.lhs] = mapping
	end
	mappings["3"].callback()
	assert(moved == 3 and confirmed == 1, "number did not confirm its exact choice")
	mappings["9"].callback()
	assert(moved == 3 and confirmed == 1, "out-of-range number confirmed another choice")
	options.actions[options.win.list.keys["<CR>"]](instance)
	assert(moved == 3 and confirmed == 2, "Enter did not confirm the current selection")
	vim.api.nvim_buf_delete(buf, { force = true })

	buf = vim.api.nvim_create_buf(false, true)
	instance.list.win.buf = buf
	instance.count = function()
		return 12
	end
	options.on_show(instance)
	equal({}, vim.api.nvim_buf_get_keymap(buf, "n"), "long list consumed native number counts")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("unnamed buffer picker items focus their buffer instead of opening the label", function()
	reset_editor()
	local bufnr = vim.api.nvim_create_buf(true, false)
	local instance = picker()
	open_in_tab(instance, { buf = bufnr, file = "[No Name]" })
	equal(1, instance.closed, "picker was not closed")
	equal(bufnr, vim.api.nvim_get_current_buf(), "unnamed item did not focus its exact buffer")
	equal({}, opened, "unnamed item label was treated as a filesystem path")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("special buffer picker items focus the existing tab and window", function()
	reset_editor()
	local origin = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	local target_tab = vim.api.nvim_get_current_tabpage()
	local target_win = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_get_current_buf()
	vim.bo[bufnr].buftype = "nofile"
	vim.api.nvim_buf_set_name(bufnr, "snacks-special://fixture")
	vim.api.nvim_set_current_tabpage(origin)

	local instance = picker()
	open_in_tab(instance, { buf = bufnr, file = "Special fixture" })
	equal(target_tab, vim.api.nvim_get_current_tabpage(), "special buffer did not focus its existing tab")
	equal(target_win, vim.api.nvim_get_current_win(), "special buffer did not focus its existing window")
	equal({}, opened, "special buffer label was treated as a filesystem path")
	vim.bo[bufnr].modified = false
	vim.cmd("tabclose")
end)

test("regular file buffers retain tab-first path and cursor routing", function()
	reset_editor()
	local bufnr = vim.api.nvim_create_buf(true, false)
	local path = vim.fn.tempname() .. "-picker.lua"
	vim.api.nvim_buf_set_name(bufnr, path)
	path = vim.api.nvim_buf_get_name(bufnr)
	local instance = picker()
	open_in_tab(instance, { buf = bufnr, file = path, pos = { 8, 3 } })
	equal(1, instance.closed, "picker was not closed")
	equal({ { path = path, options = { lnum = 8, col = 4 } } }, opened, "regular file bypassed tab-first routing")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("snacks_spec: %d tests passed", count))
vim.cmd("quitall!")
