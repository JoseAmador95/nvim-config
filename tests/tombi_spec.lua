vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local tombi = require("config.tombi")
local env = tombi.env()
assert(vim.deep_equal(env, { XDG_CONFIG_HOME = vim.fn.stdpath("config") }))

local settings = tombi.settings()
assert(settings.tombi.schema.strict == false, "Tombi strict mode must default off")
assert(vim.islist(settings.tombi.schema.catalog.paths), "Tombi catalog paths must be a JSON array")
assert(#settings.tombi.schema.catalog.paths == 0, "Tombi catalogs must require explicit opt-in")

local lines = vim.fn.readfile(repo .. "/tombi/config.toml")
assert(
	vim.deep_equal(lines, {
		"[schema]",
		"strict = false",
		"",
		"[schema.catalog]",
		"paths = []",
	}),
	"versioned Tombi CLI defaults drifted"
)

local formatting = require("plugins.formatting")[1].opts
assert(vim.deep_equal(formatting.formatters_by_ft.toml, { "tombi" }))
assert(vim.deep_equal(formatting.formatters.tombi.env, env))

print("tombi_spec: strict-off local schemas, explicit catalogs, and formatter routing verified")
