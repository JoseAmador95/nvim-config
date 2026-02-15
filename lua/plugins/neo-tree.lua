local state = {
	prev_tab = nil,
	neo_tree_tab = nil,
}

local function is_valid_tab(tab)
	return tab and vim.api.nvim_tabpage_is_valid(tab)
end

local function tab_has_neotree(tab)
	if not is_valid_tab(tab) then
		return false, nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "neo-tree" then
			return true, win
		end
	end
	return false, nil
end

local function find_neotree_tab()
	if is_valid_tab(state.neo_tree_tab) then
		local ok, win = tab_has_neotree(state.neo_tree_tab)
		if ok then
			return state.neo_tree_tab, win
		end
	end

	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		local ok, win = tab_has_neotree(tab)
		if ok then
			return tab, win
		end
	end

	return nil, nil
end

local function find_first_non_neotree_tab()
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if not tab_has_neotree(tab) then
			return tab
		end
	end
	return nil
end

local function open_neotree_tab()
	local current_tab = vim.api.nvim_get_current_tabpage()
	local in_neotree = tab_has_neotree(current_tab)
	if in_neotree then
		if is_valid_tab(state.prev_tab) and not tab_has_neotree(state.prev_tab) then
			vim.api.nvim_set_current_tabpage(state.prev_tab)
			return
		end

		local fallback = find_first_non_neotree_tab()
		if fallback and is_valid_tab(fallback) then
			vim.api.nvim_set_current_tabpage(fallback)
		else
			vim.cmd("tabnew")
		end
		return
	end

	state.prev_tab = current_tab

	local tab, win = find_neotree_tab()
	if tab then
		state.neo_tree_tab = tab
		vim.api.nvim_set_current_tabpage(tab)
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
	else
		vim.cmd("tabnew")
		require("neo-tree.command").execute({
			action = "show",
			source = "filesystem",
			position = "current",
		})
		state.neo_tree_tab = vim.api.nvim_get_current_tabpage()
	end

	vim.cmd("tabmove 0")
end

return {
	{
		"nvim-neo-tree/neo-tree.nvim",
		branch = "v3.x",
		cond = function()
			return not vim.g.vscode
		end,
		cmd = { "Neotree" },
		dependencies = {
			"nvim-lua/plenary.nvim",
			"MunifTanjim/nui.nvim",
			"nvim-tree/nvim-web-devicons",
		},
		keys = {
			{
				"<leader>e",
				open_neotree_tab,
				desc = "Open file explorer tab",
			},
		},
		opts = {
			close_if_last_window = false,
			enable_git_status = true,
			enable_diagnostics = true,
			default_component_configs = {
				indent = {
					with_expanders = true,
				},
			},
			window = {
				position = "current",
				width = 30,
			},
			filesystem = {
				follow_current_file = {
					enabled = true,
				},
				filtered_items = {
					hide_dotfiles = false,
					hide_gitignored = false,
				},
				window = {
					mappings = {
						["<C-t>"] = "navigate_up",
						["?"] = "show_help",
						["l"] = "open_tabnew",
						["L"] = "open_vsplit",
						["h"] = "close_node",
						["H"] = "close_all_nodes",
						["<CR>"] = "open_tabnew",
					},
				},
			},
		},
	},
}
