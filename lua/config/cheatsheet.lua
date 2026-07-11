-- :Cheatsheet — browse all keymaps (default) or user commands.
-- A reminder of what's bound when you forget. `<Tab>`-completes the argument.
--
-- In terminal Neovim it uses Telescope (fuzzy). In VSCode (vscode-neovim) the
-- Telescope/which-key floats don't render, so it opens a plain scratch buffer
-- instead — which VSCode shows as a normal editor tab.

local function open_scratch(lines, name)
	vim.cmd("new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	pcall(vim.api.nvim_buf_set_name, buf, name)
end

local function pretty_lhs(lhs)
	-- The resolved <leader> shows up as a literal leading space.
	lhs = lhs:gsub("^ ", "<leader>")
	return (lhs:gsub("\t", "<Tab>"))
end

local function keymaps_lines()
	local modes = { { "n", "Normal" }, { "x", "Visual" }, { "o", "Operator" }, { "i", "Insert" }, { "t", "Terminal" } }
	local lines = { "# Keymaps", "" }
	for _, m in ipairs(modes) do
		local rows = {}
		for _, km in ipairs(vim.api.nvim_get_keymap(m[1])) do
			if km.desc and km.desc ~= "" then
				rows[#rows + 1] = string.format("  %-16s %s", pretty_lhs(km.lhs or ""), km.desc)
			end
		end
		if #rows > 0 then
			table.sort(rows)
			lines[#lines + 1] = "## " .. m[2]
			vim.list_extend(lines, rows)
			lines[#lines + 1] = ""
		end
	end
	return lines
end

local function commands_lines()
	local names = {}
	for name in pairs(vim.api.nvim_get_commands({})) do
		names[#names + 1] = name
	end
	table.sort(names)
	local lines = { "# User commands", "" }
	for _, name in ipairs(names) do
		lines[#lines + 1] = "  :" .. name
	end
	return lines
end

vim.api.nvim_create_user_command("Cheatsheet", function(opts)
	local what = opts.args ~= "" and opts.args or "keymaps"
	if vim.g.vscode then
		if what == "commands" then
			open_scratch(commands_lines(), "Cheatsheet: commands")
		else
			open_scratch(keymaps_lines(), "Cheatsheet: keymaps")
		end
		return
	end
	if what == "commands" then
		Snacks.picker.commands()
	else
		Snacks.picker.keymaps()
	end
end, {
	nargs = "?",
	complete = function()
		return { "keymaps", "commands" }
	end,
	desc = "Browse keymaps (default) or user commands",
})
