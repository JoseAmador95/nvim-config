-- Library-only dependency: the reviewer runs its diff module in a worker.
return {
	"CoreyKaylor/diffbandit.nvim",
	version = "v0.3.0",
	lazy = true,
	module = false,
	cond = function()
		return not vim.g.vscode
	end,
}
