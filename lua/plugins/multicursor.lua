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

			local function notify(msg, level)
				vim.notify(msg, level or vim.log.levels.INFO, { title = "Multicursor" })
			end

			local function flash_jump(opts)
				local ok, flash = pcall(require, "flash")
				if not ok then
					notify("flash.nvim not available", vim.log.levels.WARN)
					return
				end
				flash.jump(opts)
			end

			local function add_cursor_at_match(match, state, select_range)
				if not match or not match.pos then
					return
				end

				local line = match.pos[1]
				local col = match.pos[2] + 1

				local end_line = line
				local end_col = col
				if match.end_pos then
					end_line = match.end_pos[1]
					end_col = match.end_pos[2] + 1
				end

				mc.action(function(ctx)
					local main = ctx:mainCursor()
					local cursor = ctx:addCursor()
					cursor:setPos({ line, col })
					if select_range and match.end_pos then
						cursor:setVisual({ line, col }, { end_line, end_col })
					end
					main:select()
				end)

				if state and state.restore then
					state:restore()
				end
			end

			local k = vim.keymap.set
			k({ "n", "x" }, "mc", mc.addCursorOperator, { desc = "Create cursor" })
			k({ "n" }, "mcc", mc.clearCursors, { desc = "Cancel/Clear all cursors" })
			k({ "n", "x" }, "mi", function()
				mc.feedkeys("i")
			end, { desc = "Start cursors on the left" })
			k({ "n", "x" }, "mI", function()
				mc.feedkeys("I")
			end, { desc = "Start cursors on the left edge" })
			k({ "n", "x" }, "ma", function()
				mc.feedkeys("a")
			end, { desc = "Start cursors on the right" })
			k({ "n", "x" }, "mA", function()
				mc.feedkeys("a")
			end, { desc = "Start cursors on the right" })
			k({ "n" }, "[mc", mc.prevCursor, { desc = "Goto prev cursor" })
			k({ "n" }, "]mc", mc.nextCursor, { desc = "Goto next cursor" })
			k({ "n" }, "<c-leftmouse>", mc.handleMouse, { desc = "Add cursor (mouse)" })
			k({ "n" }, "<c-leftdrag>", mc.handleMouseDrag, { desc = "Add cursor drag (mouse)" })
			k({ "n" }, "<c-leftrelease>", mc.handleMouseRelease, { desc = "Finalize cursor drag (mouse)" })
			k({ "n" }, "mcs", function()
				flash_jump({
					search = { multi_window = false },
					action = function(match, state)
						add_cursor_at_match(match, state, false)
					end,
				})
			end, { desc = "Create cursor using flash" })
			k({ "n" }, "mcw", function()
				flash_jump({
					pattern = [[\<\k\+\>]],
					search = { mode = "search", multi_window = false },
					jump = { pos = "range" },
					action = function(match, state)
						add_cursor_at_match(match, state, true)
					end,
				})
			end, { desc = "Create selection using flash" })
		end,
	},
}
