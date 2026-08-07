-- Declarative version and installer manifest. Keep this module free of `vim`
-- dependencies so bootstrap, health, and tests can require it without causing
-- runtime side effects.

local M = {}

M.versions = {
	neovim = "0.12.4",
	stylua = "2.5.2",
	shellcheck = "0.11.0",
	actionlint = "1.7.12",
	claude_acp = "0.66.0",
	mmdflux = "2.6.0",
	plantuml_lsp = "v0.5.3",
}

M.installers = {
	mmdflux = { "cargo", "install", "mmdflux", "--version", M.versions.mmdflux, "--locked" },
	["plantuml-lsp"] = {
		"go",
		"install",
		"github.com/ptdewey/plantuml-lsp@" .. M.versions.plantuml_lsp,
	},
}

M.order = { "mmdflux", "plantuml-lsp" }
M.tools = {
	mmdflux = {
		executable = "mmdflux",
		version = M.versions.mmdflux,
		installer = "cargo",
		command = M.installers.mmdflux,
	},
	["plantuml-lsp"] = {
		executable = "plantuml-lsp",
		version = M.versions.plantuml_lsp,
		installer = "go",
		command = M.installers["plantuml-lsp"],
	},
}

return M
