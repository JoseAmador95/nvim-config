return {
	-- ASCII mermaid renderer (searleser97/mermaid-nvim). Diagrams are now viewed on
	-- demand via :DiagramShow / <leader>md (config.diagram), so this loads only on
	-- demand. mmdflux is managed explicitly by :NvimConfigToolsInstall instead of
	-- running an implicit plugin build. It no longer attaches on markdown buffers.
	"searleser97/mermaid-nvim",
	cmd = { "MermaidToggle", "MermaidToggleAll", "MermaidFloat", "MermaidRender", "MermaidClear" },
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		cmd = { "mmdflux" },
		preview_mode = "float",
	},
}
