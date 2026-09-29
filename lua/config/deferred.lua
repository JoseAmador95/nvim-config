-- Audited activation boundary for modules that must remain absent at startup.
-- Keep every deferred require here so feature modules never hide imports inside
-- callbacks. Adding a name is an architectural change and must extend the load
-- contract tests.
local M = {}

local allowed = {
	["action_palette"] = true,
	["clangd_compile_db"] = true,
	["config.action_palette"] = true,
	["config.clangd"] = true,
	["config.jqx"] = true,
	["config.log_patterns"] = true,
	["config.log_watch"] = true,
	["config.menu"] = true,
	["config.native_review"] = true,
	["config.python"] = true,
	["config.tool_bootstrap"] = true,
	["coverage_workbench"] = true,
	["devcontainer_editor"] = true,
	["diagram_view"] = true,
	["exact_editor"] = true,
	["ibl"] = true,
	["ibl.hooks"] = true,
	["just_workbench"] = true,
	["log_workbench.matches"] = true,
	["md-render"] = true,
	["md-render.image"] = true,
	["md-render.wrap"] = true,
	["nvim-jqx.config"] = true,
	["oil-git-status"] = true,
	["project_python"] = true,
	["repo_scratch"] = true,
	["terminal_lifecycle"] = true,
	["verified_tools.markdown_preview"] = true,
}

function M.load(name)
	if not allowed[name] then
		error("module is not registered for deferred loading: " .. tostring(name), 2)
	end
	return require(name)
end

function M.try(name)
	return pcall(M.load, name)
end

return M
