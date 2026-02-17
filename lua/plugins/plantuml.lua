return {
	"aklt/plantuml-syntax",
	cond = function()
		return not vim.g.vscode
	end,
	ft = { "plantuml" },
	init = function()
		vim.g.plantuml_set_makeprg = 0
		vim.filetype.add({
			extension = {
				pu = "plantuml",
				puml = "plantuml",
				uml = "plantuml",
				iuml = "plantuml",
				plantuml = "plantuml",
			},
		})
	end,
}
