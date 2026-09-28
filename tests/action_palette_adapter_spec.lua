vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local local_config = require("config.local_config")
local original_plugin = local_config.plugin
local_config.plugin = function(name, defaults)
	if name == "action_palette" then
		return { target_default = "window", unavailable = "show" }
	end
	return original_plugin(name, defaults)
end

package.loaded["config.action_palette"] = nil
package.loaded.action_palette = nil
package.loaded["action_palette.schema"] = nil

local palette = require("config.action_palette")
assert(package.loaded.action_palette == nil, "adapter loaded the action-palette registry before first use")
assert(type(palette.setup) == "function", "adapter dropped the public setup contract")

local status = palette.status()
assert(status.configured == false and status.actions == 0 and status.sections == 0)
assert(
	status.config.target_default == "window" and status.config.unavailable == "show",
	"pre-use status ignored the effective host configuration"
)
assert(status.config.recent_limit == 5, "pre-use status ignored the default session recent limit")
assert(#vim.tbl_keys(palette.schema) > 0, "schema facade is not an iterable table")

local configured = palette.setup({ target_default = "buffer", unavailable = "hide" })
assert(configured == require("action_palette"), "setup no longer returns the core module")
assert(palette.status().config.target_default == "buffer", "setup did not configure the core registry")
assert(palette.teardown())

local recent = require("config.menu.recent")
local context = require("config.menu.context")
local function find_item(sections, id)
	for _, section in ipairs(sections) do
		for _, item in ipairs(section.items) do
			if item.id == id then
				return item
			end
		end
	end
end

local item = assert(find_item(palette.sections(context.capture(), "palette"), "edit.clear_search"))
assert(item.run(), "palette action was not dispatched")
assert(vim.deep_equal({ "edit.clear_search" }, recent.ids()), "host adapter did not record an executed palette event")
assert(palette.teardown())
assert(vim.deep_equal({}, recent.ids()), "palette teardown retained session MRU state")

local_config.plugin = original_plugin
print("action_palette_adapter_spec: lazy status, schema, and setup contracts verified")
vim.cmd("quitall!")
