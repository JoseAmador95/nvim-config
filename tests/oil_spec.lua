vim.o.shadafile = "NONE"
vim.o.swapfile = false

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

local entry
local current_dir = "/tmp/oil-fixture/"
local directory = false
local select_calls = {}
local setup_options
local opened = {}

package.loaded.oil = {
	get_cursor_entry = function()
		return entry
	end,
	get_current_dir = function()
		return current_dir
	end,
	select = function(options)
		select_calls[#select_calls + 1] = options or false
	end,
	setup = function(options)
		setup_options = options
		return "configured"
	end,
}
package.loaded["oil.util"] = {
	is_directory = function()
		return directory
	end,
}
package.loaded["config.editor"] = {
	open_file_in_tab = function(path)
		opened[#opened + 1] = path
	end,
}

local adapter = require("config.oil")

local function reset()
	entry = { name = "fixture", parsed_name = "fixture" }
	current_dir = "/tmp/oil-fixture/"
	directory = false
	select_calls = {}
	opened = {}
end

test("setup injects the host selection callback without mutating caller opts", function()
	local original = { keymaps = { q = "actions.close" } }
	equal("configured", adapter.setup(original), "adapter did not return oil.setup result")
	equal(nil, original.keymaps["<CR>"], "adapter mutated caller options")
	equal("actions.close", setup_options.keymaps.q, "existing Oil keymap was lost")
	assert(type(setup_options.keymaps["<CR>"].callback) == "function", "host callback was not installed")
	equal(adapter.open_selection, setup_options.keymaps["<CR>"].callback, "Oil callback identity changed")
end)

test("directory and symlink-directory entries use Oil native navigation", function()
	reset()
	directory = true
	entry = { name = "directory", parsed_name = "renamed-directory", type = "directory" }
	assert(adapter.open_selection(), "directory selection was rejected")
	equal({ false }, select_calls, "directory selection did not use native Oil select")
	equal({}, opened, "directory selection was routed through the file opener")

	reset()
	directory = true
	entry = { name = "link", parsed_name = "renamed-link", type = "link" }
	assert(adapter.open_selection(), "symlink-directory selection was rejected")
	equal({ false }, select_calls, "symlink-directory did not use Oil's resolved directory check")
	equal({}, opened, "symlink-directory was routed through the file opener")
end)

test("remote Oil buffers retain native selection semantics", function()
	reset()
	current_dir = nil
	entry = { name = "remote.txt", parsed_name = "remote-renamed.txt", type = "file" }
	assert(adapter.open_selection(), "remote selection was rejected")
	equal({ false }, select_calls, "remote selection did not delegate to Oil")
	equal({}, opened, "remote selection was routed through a local path")
end)

test("local files route Oil's resolved buffer path through tab-first", function()
	reset()
	entry = { name = "old-name.lua", parsed_name = "new-name.lua", type = "file" }
	assert(adapter.open_selection(), "local file selection was rejected")
	equal(1, #select_calls, "local file did not call Oil exactly once")
	local options = select_calls[1]
	assert(
		type(options) == "table" and type(options.handle_buffer_callback) == "function",
		"Oil lifecycle callback missing"
	)
	equal({}, opened, "adapter opened a manually concatenated pre-rename path")

	local bufnr = vim.api.nvim_create_buf(true, false)
	local resolved = vim.fn.tempname() .. "-new-name.lua"
	vim.api.nvim_buf_set_name(bufnr, resolved)
	resolved = vim.api.nvim_buf_get_name(bufnr)
	options.handle_buffer_callback(bufnr)
	equal({ resolved }, opened, "adapter ignored Oil's resolved post-rename buffer path")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("missing entries are a no-op", function()
	reset()
	entry = nil
	assert(not adapter.open_selection(), "missing entry reported success")
	equal({}, select_calls, "missing entry called Oil")
	equal({}, opened, "missing entry opened a file")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("oil_spec: %d tests passed", count))
vim.cmd("quitall!")
