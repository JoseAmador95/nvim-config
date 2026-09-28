vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")
vim.g.mapleader = " "

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

local feedkeys = {}
local layer_factory
local mc = {
	setup = function() end,
	addCursorOperator = function() end,
	clearCursors = function() end,
	prevCursor = function() end,
	nextCursor = function() end,
	handleMouse = function() end,
	handleMouseDrag = function() end,
	handleMouseRelease = function() end,
	matchAllAddCursors = function() end,
	jumpBackward = function() end,
	jumpForward = function() end,
	feedkeys = function(keys)
		feedkeys[#feedkeys + 1] = keys
	end,
	addKeymapLayer = function(callback)
		layer_factory = callback
	end,
}
package.loaded["multicursor-nvim"] = mc
package.loaded["config.multicursor"] = {
	flash_cursor = function() end,
	flash_word_selection = function() end,
}

local persistent = {}
local original_set = vim.keymap.set
vim.keymap.set = function(modes, lhs, rhs, options)
	persistent[#persistent + 1] = { modes = modes, lhs = lhs, rhs = rhs, options = options }
end
local spec = require("plugins.multicursor")[1]
spec.config()
vim.keymap.set = original_set

local function persistent_lhs()
	local result = {}
	for _, mapping in ipairs(persistent) do
		result[#result + 1] = mapping.lhs
	end
	table.sort(result)
	return result
end

test("persistent multicursor keys use the explicit host leader namespace", function()
	local expected = {
		"<c-leftdrag>",
		"<c-leftmouse>",
		"<c-leftrelease>",
		"<leader>mA",
		"<leader>mC",
		"<leader>mI",
		"<leader>mM",
		"<leader>ma",
		"<leader>mc",
		"<leader>mi",
		"<leader>ms",
		"<leader>mw",
		"<leader>m[",
		"<leader>m]",
	}
	table.sort(expected)
	equal(expected, persistent_lhs(), "persistent multicursor key set changed")
	for _, mapping in ipairs(persistent) do
		assert(not mapping.lhs:match("^m"), "persistent mapping stole native m{mark}: " .. mapping.lhs)
	end
	assert(type(layer_factory) == "function", "active-cursor keymap layer was not registered")
end)

test("active layer owns only history Flash and surround collision keys", function()
	local layer = {}
	layer_factory(function(modes, lhs, rhs, options)
		layer[#layer + 1] = { modes = modes, lhs = lhs, rhs = rhs, options = options }
	end)
	equal(4, #layer, "active layer has unexpected mappings")
	equal(
		{ "<C-o>", "<C-i>", "s", "S" },
		vim.tbl_map(function(mapping)
			return mapping.lhs
		end, layer),
		"active layer key set changed"
	)
	for _, mapping in ipairs(layer) do
		equal({ "n", "x" }, mapping.modes, mapping.lhs .. " is not scoped to normal and visual modes")
	end
	layer[3].rhs()
	layer[4].rhs()
	equal({ "s", "S" }, feedkeys, "substitute keys were not replayed through multicursor")
end)

test("removing the active layer reveals history Flash and surround again", function()
	local bufnr = vim.api.nvim_get_current_buf()
	local globals = {
		{ "n", "<C-o>", function() end, "Navigation back" },
		{ "n", "<C-i>", function() end, "Navigation forward" },
		{ "n", "s", function() end, "Flash" },
		{ "x", "s", function() end, "Flash" },
		{ "n", "S", function() end, "Flash Treesitter" },
		{ "x", "S", function() end, "nvim-surround visual" },
	}
	for _, mapping in ipairs(globals) do
		original_set(mapping[1], mapping[2], mapping[3], { desc = mapping[4] })
	end

	local active = {}
	layer_factory(function(modes, lhs, rhs, options)
		original_set(modes, lhs, rhs, vim.tbl_extend("force", {}, options, { buffer = bufnr }))
		active[#active + 1] = { modes = modes, lhs = lhs }
	end)
	equal("Multicursor jump backward", vim.fn.maparg("<C-o>", "n", false, true).desc, "active layer missed C-o")
	equal("Multicursor jump forward", vim.fn.maparg("<C-i>", "n", false, true).desc, "active layer missed C-i")
	equal("Multicursor substitute", vim.fn.maparg("s", "x", false, true).desc, "active layer missed visual s")
	equal(
		"Multicursor change line or selection",
		vim.fn.maparg("S", "x", false, true).desc,
		"active layer missed visual S"
	)

	for _, mapping in ipairs(active) do
		for _, mode in ipairs(mapping.modes) do
			vim.keymap.del(mode, mapping.lhs, { buffer = bufnr })
		end
	end
	equal("Navigation back", vim.fn.maparg("<C-o>", "n", false, true).desc, "history back did not return")
	equal("Navigation forward", vim.fn.maparg("<C-i>", "n", false, true).desc, "history forward did not return")
	equal("Flash", vim.fn.maparg("s", "n", false, true).desc, "normal Flash did not return")
	equal("Flash", vim.fn.maparg("s", "x", false, true).desc, "visual Flash did not return")
	equal("Flash Treesitter", vim.fn.maparg("S", "n", false, true).desc, "normal Flash Treesitter did not return")
	equal("nvim-surround visual", vim.fn.maparg("S", "x", false, true).desc, "visual surround did not return")

	for _, mapping in ipairs(globals) do
		pcall(vim.keymap.del, mapping[1], mapping[2])
	end
end)

test("Flash leaves visual S to nvim-surround", function()
	local flash = require("plugins.flash")
	local by_lhs = {}
	for _, mapping in ipairs(flash.keys) do
		by_lhs[mapping[1]] = mapping
	end
	equal({ "n", "x", "o" }, by_lhs.s.mode, "Flash s lost a supported mode")
	equal({ "n", "o" }, by_lhs.S.mode, "Flash S still claims visual mode")
end)

test("which-key labels the shared leader-m namespace", function()
	local group
	for _, entry in ipairs(require("plugins.which-key").opts.spec) do
		if entry[1] == "<leader>m" then
			group = entry.group
		end
	end
	equal("markdown/multicursor", group, "which-key still labels leader-m as markdown only")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("multicursor_spec: %d tests passed", count))
vim.cmd("quitall!")
