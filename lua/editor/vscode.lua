local usage_map = require("config.usage").mapper("editor.vscode")
local vscode = require("vscode")

local function call(action, opts)
	return function()
		vscode.call(action, opts)
	end
end

usage_map("n", "<leader>q", call("workbench.action.closeActiveEditor"), {
	noremap = true,
	silent = true,
	desc = "Close editor",
})

usage_map("n", "<leader>Q", call("workbench.action.revertAndCloseActiveEditor"), {
	noremap = true,
	silent = true,
	desc = "Revert and close editor",
})

usage_map("n", "<leader>w", call("workbench.action.files.save"), {
	noremap = true,
	silent = true,
	desc = "Save",
})

usage_map("n", "<leader>x", function()
	vscode.call("workbench.action.files.save")
	vscode.call("workbench.action.closeActiveEditor")
end, {
	noremap = true,
	silent = true,
	desc = "Save and close editor",
})

usage_map("n", "<leader>t", call("workbench.action.terminal.toggleTerminal"), {
	noremap = true,
	silent = true,
	desc = "Toggle terminal panel",
})

usage_map("n", "<leader>e", call("workbench.view.explorer"), {
	noremap = true,
	silent = true,
	desc = "Explorer",
})

usage_map("n", "<leader>ff", call("workbench.action.quickOpen"), {
	noremap = true,
	silent = true,
	desc = "Find files",
})

usage_map("n", "<leader>fg", call("workbench.action.findInFiles"), {
	noremap = true,
	silent = true,
	desc = "Find in files",
})

usage_map("n", "<leader>j", call("workbench.action.previousEditor"), {
	noremap = true,
	silent = true,
	desc = "Previous editor",
})

usage_map("n", "<leader>k", call("workbench.action.nextEditor"), {
	noremap = true,
	silent = true,
	desc = "Next editor",
})

usage_map("n", "<leader>ld", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics hover",
})

usage_map("n", "]d", call("editor.action.marker.next"), {
	noremap = true,
	silent = true,
	desc = "Next diagnostic",
})

usage_map("n", "[d", call("editor.action.marker.prev"), {
	noremap = true,
	silent = true,
	desc = "Prev diagnostic",
})

usage_map("n", "<leader>ll", call("workbench.actions.view.problems"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics list",
})

usage_map("n", "<leader>lc", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics hover",
})

usage_map("n", "<leader>lq", call("workbench.actions.view.problems"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics list",
})

usage_map("n", "gd", call("editor.action.revealDefinition"), {
	noremap = true,
	silent = true,
	desc = "Go to definition",
})

usage_map("n", "gD", call("editor.action.revealDeclaration"), {
	noremap = true,
	silent = true,
	desc = "Go to declaration",
})

usage_map("n", "gi", call("editor.action.goToImplementation"), {
	noremap = true,
	silent = true,
	desc = "Go to implementation",
})

usage_map("n", "gr", call("editor.action.referenceSearch.trigger"), {
	noremap = true,
	silent = true,
	desc = "References",
})

usage_map("n", "<leader>.", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Hover symbol documentation",
})

usage_map("n", "<C-k>", call("editor.action.triggerParameterHints"), {
	noremap = true,
	silent = true,
	desc = "Signature help",
})

usage_map("n", "<leader>lr", call("editor.action.rename"), {
	noremap = true,
	silent = true,
	desc = "Rename",
})
