local M = {}

local MODULES = {
	changes = "native_review.changes",
	controller = "native_review.controller",
	editor = "native_review.editor",
	export = "native_review.export",
	lsp = "native_review.lsp",
	mode = "native_review.mode",
	panel = "native_review.panel",
	presenter = "native_review.presenter",
	projection = "native_review.projection",
	scope = "native_review.scope",
	store = "native_review.store",
}

---Inject host services and load the standalone review runtime.
---@param opts table
---@return table
function M.setup(opts)
	require("native_review.dependencies").setup(opts or {})
	for name, module_name in pairs(MODULES) do
		M[name] = require(module_name)
	end
	return M
end

return M
