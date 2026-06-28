return {
	"lewis6991/gitsigns.nvim",
	event = "BufReadPre",
	cond = function()
		return not vim.g.vscode
	end,

	config = function()
		require("gitsigns").setup({
			signs = {
				add = { text = "│", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
				change = { text = "│", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
				delete = { text = "_", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
				topdelete = { text = "‾", numhl = "GitSignsDeleteNr", linehl = "GitSignsDeleteLn" },
				changedelete = { text = "~", numhl = "GitSignsChangeNr", linehl = "GitSignsChangeLn" },
				untracked = { text = "┆", numhl = "GitSignsAddNr", linehl = "GitSignsAddLn" },
			},
			on_attach = function(bufnr)
				local gs = require("gitsigns")
				local function map(mode, lhs, rhs, desc)
					vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
				end

				-- Hunk navigation (]c/[c are taken by treesitter class motions).
				map("n", "]h", function()
					gs.nav_hunk("next")
				end, "Next hunk")
				map("n", "[h", function()
					gs.nav_hunk("prev")
				end, "Prev hunk")

				-- Hunk actions.
				map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
				map("n", "<leader>hr", gs.reset_hunk, "Reset hunk")
				map("v", "<leader>hs", function()
					gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
				end, "Stage hunk")
				map("v", "<leader>hr", function()
					gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
				end, "Reset hunk")
				map("n", "<leader>hS", gs.stage_buffer, "Stage buffer")
				map("n", "<leader>hR", gs.reset_buffer, "Reset buffer")
				map("n", "<leader>hp", gs.preview_hunk, "Preview hunk")
				map("n", "<leader>hb", function()
					gs.blame_line({ full = true })
				end, "Blame line")
				map("n", "<leader>hd", gs.diffthis, "Diff this")
				map("n", "<leader>htb", gs.toggle_current_line_blame, "Toggle line blame")
				map("n", "<leader>htd", gs.toggle_deleted, "Toggle deleted")
			end,
		})
	end,
}
