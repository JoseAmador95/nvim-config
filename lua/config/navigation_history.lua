local M = {}

-- Ensure the shared runtime has the full-editor policies before exposing the
-- host command and picker surfaces.
require("config.tabs")
local runtime = require("tab_first")

function M.capture()
	return runtime.capture()
end

function M.record_transition(origin, destination)
	return runtime.record_transition(origin, destination)
end

function M.back(opts)
	return runtime.back(opts)
end

function M.forward(opts)
	return runtime.forward(opts)
end

function M.select()
	runtime.prepare_history()
	local snapshot = runtime.history_snapshot()
	if #snapshot.entries == 0 then
		vim.notify("Navigation history is empty", vim.log.levels.INFO, { title = "Navigation" })
		return
	end

	local choices = {}
	for index = #snapshot.entries, 1, -1 do
		local entry = snapshot.entries[index]
		choices[#choices + 1] = {
			index = index,
			label = string.format(
				"%s%s:%d:%d",
				index == snapshot.index and "● " or "  ",
				vim.fn.fnamemodify(entry.path, ":~:."),
				entry.lnum,
				entry.col
			),
		}
	end
	vim.ui.select(choices, {
		prompt = "Navigation history",
		format_item = function(choice)
			return choice.label
		end,
	}, function(choice)
		if choice then
			runtime.restore_history(choice.index)
		end
	end)
end

function M.snapshot()
	return runtime.history_snapshot()
end

function M.reset()
	runtime.history_reset()
end

function M.setup()
	vim.api.nvim_create_user_command("NavigationBack", function()
		M.back()
	end, { desc = "Go back in semantic navigation history", force = true })
	vim.api.nvim_create_user_command("NavigationForward", function()
		M.forward()
	end, { desc = "Go forward in semantic navigation history", force = true })
	vim.api.nvim_create_user_command("NavigationHistory", M.select, {
		desc = "Show semantic navigation history",
		force = true,
	})
	vim.keymap.set("n", "<C-o>", M.back, { silent = true, desc = "Navigation back" })
	vim.keymap.set("n", "<C-i>", M.forward, { silent = true, desc = "Navigation forward" })
	vim.keymap.set("n", "<leader>nh", M.select, { silent = true, desc = "Show navigation history" })
end

return M
