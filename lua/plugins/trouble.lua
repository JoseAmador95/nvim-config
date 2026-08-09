local function open_item(_, ctx)
	local item = ctx.item
	if not item then
		return
	end
	local path = item.filename or (item.buf and vim.api.nvim_buf_get_name(item.buf))
	if not path or path == "" then
		return
	end
	require("config.editor").open_file_in_tab(path, {
		lnum = item.pos and item.pos[1] or 1,
		col = item.pos and (item.pos[2] or 0) + 1 or 1,
	})
end

return {
	"folke/trouble.nvim",
	cmd = "Trouble",
	cond = function()
		return not vim.g.vscode
	end,
	keys = {
		{ "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", desc = "Diagnostics (Trouble)" },
		{
			"<leader>xd",
			"<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
			desc = "Buffer Diagnostics (Trouble)",
		},
		{
			"<leader>xq",
			"<cmd>Trouble qflist toggle<cr>",
			desc = "Quickfix List (Trouble)",
		},
		{
			"<leader>xl",
			"<cmd>Trouble loclist toggle<cr>",
			desc = "Location List (Trouble)",
		},
		{
			"<leader>xr",
			"<cmd>Trouble lsp_references toggle focus=false win.position=right<cr>",
			desc = "LSP References (Trouble)",
		},
	},
	opts = {
		keys = {
			["<cr>"] = open_item,
			["<2-leftmouse>"] = open_item,
			o = function(view, ctx)
				local item = ctx.item
				if not item then
					return
				end
				local path = item.filename or (item.buf and vim.api.nvim_buf_get_name(item.buf))
				if not path or path == "" then
					return
				end
				local position = vim.deepcopy(item.pos or { 1, 0 })
				view:close()
				vim.schedule(function()
					require("config.editor").open_file_in_tab(path, {
						lnum = position[1],
						col = (position[2] or 0) + 1,
					})
				end)
			end,
		},
		modes = {
			diagnostics = {
				auto_close = false,
				auto_preview = true,
			},
			lsp_definitions = { auto_jump = false },
			lsp_declarations = { auto_jump = false },
			lsp_implementations = { auto_jump = false },
			lsp_references = { auto_jump = false },
			lsp_type_definitions = { auto_jump = false },
		},
	},
}
