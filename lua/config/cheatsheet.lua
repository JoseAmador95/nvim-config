-- :Cheatsheet — browse all keymaps (default) or user commands via Telescope.
-- A reminder of what's bound when you forget. `<Tab>`-completes the argument.

vim.api.nvim_create_user_command("Cheatsheet", function(opts)
	local what = opts.args ~= "" and opts.args or "keymaps"
	if what == "commands" then
		vim.cmd("Telescope commands")
	else
		vim.cmd("Telescope keymaps")
	end
end, {
	nargs = "?",
	complete = function()
		return { "keymaps", "commands" }
	end,
	desc = "Browse keymaps (default) or user commands",
})
