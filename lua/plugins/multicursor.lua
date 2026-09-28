return {
	{
		"jake-stewart/multicursor.nvim",
		branch = "1.0",
		cond = function()
			return not vim.g.vscode
		end,
		event = "VeryLazy",
		config = function()
			local mc = require("multicursor-nvim")
			mc.setup()
			local multicursor = require("config.multicursor")

			local k = vim.keymap.set
			k({ "n", "x" }, "<leader>mc", mc.addCursorOperator, { desc = "Create cursor" })
			k({ "n" }, "<leader>mC", mc.clearCursors, { desc = "Cancel/Clear all cursors" })
			k({ "n", "x" }, "<leader>mi", function()
				mc.feedkeys("i")
			end, { desc = "Start cursors on the left" })
			k({ "n", "x" }, "<leader>mI", function()
				mc.feedkeys("I")
			end, { desc = "Start cursors on the left edge" })
			k({ "n", "x" }, "<leader>ma", function()
				mc.feedkeys("a")
			end, { desc = "Start cursors on the right" })
			k({ "n", "x" }, "<leader>mA", function()
				mc.feedkeys("A")
			end, { desc = "Start cursors on the right" })
			k({ "n" }, "<leader>m[", mc.prevCursor, { desc = "Goto prev cursor" })
			k({ "n" }, "<leader>m]", mc.nextCursor, { desc = "Goto next cursor" })
			k({ "n" }, "<c-leftmouse>", mc.handleMouse, { desc = "Add cursor (mouse)" })
			k({ "n" }, "<c-leftdrag>", mc.handleMouseDrag, { desc = "Add cursor drag (mouse)" })
			k({ "n" }, "<c-leftrelease>", mc.handleMouseRelease, { desc = "Finalize cursor drag (mouse)" })
			k({ "n" }, "<leader>ms", multicursor.flash_cursor, { desc = "Create cursor using flash" })
			k({ "n" }, "<leader>mw", multicursor.flash_word_selection, { desc = "Create selection using flash" })

			-- Poner un cursor en cada ocurrencia de la palabra/selección y editarlas
			-- a la vez (equivalente modal a Ctrl+Shift+L de VSCode).
			k({ "n", "x" }, "<leader>mM", mc.matchAllAddCursors, {
				desc = "Cursor en cada ocurrencia (editar todas)",
			})

			mc.addKeymapLayer(function(layer)
				layer({ "n", "x" }, "<C-o>", mc.jumpBackward, { desc = "Multicursor jump backward" })
				layer({ "n", "x" }, "<C-i>", mc.jumpForward, { desc = "Multicursor jump forward" })
				layer({ "n", "x" }, "s", function()
					mc.feedkeys("s")
				end, { desc = "Multicursor substitute" })
				layer({ "n", "x" }, "S", function()
					mc.feedkeys("S")
				end, { desc = "Multicursor change line or selection" })
			end)
		end,
	},
}
