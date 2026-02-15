local vscode = require("vscode")

local function call(action, opts)
	return function()
		vscode.call(action, opts)
	end
end

vim.keymap.set("n", "<leader>q", call("workbench.action.closeActiveEditor"), {
	noremap = true,
	silent = true,
	desc = "Close editor",
})

vim.keymap.set("n", "<leader>Q", call("workbench.action.revertAndCloseActiveEditor"), {
	noremap = true,
	silent = true,
	desc = "Revert and close editor",
})

vim.keymap.set("n", "<leader>w", call("workbench.action.files.save"), {
	noremap = true,
	silent = true,
	desc = "Save",
})

vim.keymap.set("n", "<leader>x", function()
	vscode.call("workbench.action.files.save")
	vscode.call("workbench.action.closeActiveEditor")
end, {
	noremap = true,
	silent = true,
	desc = "Save and close editor",
})

vim.keymap.set("n", "<leader>t", call("workbench.action.terminal.toggleTerminal"), {
	noremap = true,
	silent = true,
	desc = "Toggle terminal panel",
})

vim.keymap.set("n", "<leader>e", call("workbench.view.explorer"), {
	noremap = true,
	silent = true,
	desc = "Explorer",
})

vim.keymap.set("n", "J", call("workbench.action.previousEditor"), {
	noremap = true,
	silent = true,
	desc = "Previous editor",
})

vim.keymap.set("n", "K", call("workbench.action.nextEditor"), {
	noremap = true,
	silent = true,
	desc = "Next editor",
})

vim.keymap.set("n", "<leader>ld", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics hover",
})

vim.keymap.set("n", "]d", call("editor.action.marker.next"), {
	noremap = true,
	silent = true,
	desc = "Next diagnostic",
})

vim.keymap.set("n", "[d", call("editor.action.marker.prev"), {
	noremap = true,
	silent = true,
	desc = "Prev diagnostic",
})

vim.keymap.set("n", "<leader>ll", call("workbench.actions.view.problems"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics list",
})

vim.keymap.set("n", "<leader>lc", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics hover",
})

vim.keymap.set("n", "<leader>lq", call("workbench.actions.view.problems"), {
	noremap = true,
	silent = true,
	desc = "Diagnostics list",
})

vim.keymap.set("n", "gd", call("editor.action.revealDefinition"), {
	noremap = true,
	silent = true,
	desc = "Go to definition",
})

vim.keymap.set("n", "gD", call("editor.action.revealDeclaration"), {
	noremap = true,
	silent = true,
	desc = "Go to declaration",
})

vim.keymap.set("n", "gi", call("editor.action.goToImplementation"), {
	noremap = true,
	silent = true,
	desc = "Go to implementation",
})

vim.keymap.set("n", "gr", call("editor.action.referenceSearch.trigger"), {
	noremap = true,
	silent = true,
	desc = "References",
})

vim.keymap.set("n", "<leader>.", call("editor.action.showHover"), {
	noremap = true,
	silent = true,
	desc = "Hover symbol documentation",
})

vim.keymap.set("n", "<C-k>", call("editor.action.triggerParameterHints"), {
	noremap = true,
	silent = true,
	desc = "Signature help",
})

vim.keymap.set("n", "<leader>rn", call("editor.action.rename"), {
	noremap = true,
	silent = true,
	desc = "Rename",
})
