return {
	-- ASCII mermaid renderer (searleser97/mermaid-nvim). Diagrams are now viewed on
	-- demand via :DiagramShow / <leader>md (config.diagram), so this loads only on
	-- demand. It is kept mainly because its `build` installs/updates `mmdflux`, the
	-- backend config.diagram uses for mermaid SVG/ASCII (plus optional on-demand
	-- ASCII via its :Mermaid* commands). It no longer attaches on markdown buffers.
	"searleser97/mermaid-nvim",
	cmd = { "MermaidToggle", "MermaidToggleAll", "MermaidFloat", "MermaidRender", "MermaidClear" },
	cond = function()
		return not vim.g.vscode
	end,
	-- mmdflux is the backend: a self-contained binary that reads mermaid on stdin
	-- and prints Unicode/ASCII (or SVG). Installed via cargo; `build` keeps it in
	-- sync. There is no brew formula for it, so cargo is the install path. The
	-- `build` runs on install/update regardless of the (on-demand) load trigger.
	build = "cargo install mmdflux",
	opts = {
		cmd = { "mmdflux" },
		preview_mode = "float",
	},
}
