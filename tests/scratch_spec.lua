vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local branch = "refs/heads/feature/complete-name"
local oid = string.rep("a", 40)
local detached = false
package.loaded["config.repo"] = {
	git = function(_, arguments)
		if arguments[1] == "symbolic-ref" then
			if detached then
				return nil
			end
			return branch
		end
		if arguments[1] == "rev-parse" then
			return oid
		end
	end,
}

local host = require("config.scratch")
local branch_identity = assert(host._identity("/repo"))
assert(branch_identity.key.ref == branch)
assert(branch_identity.label == "feature/complete-name")
assert(branch_identity.legacy_ids[1] == vim.fn.sha256("/repo\0feature/complete-name"))

detached = true
local detached_identity = assert(host._identity("/repo"))
assert(detached_identity.key.ref == oid, "detached identity did not retain the full OID")
assert(detached_identity.label == "detached-" .. oid:sub(1, 12), "legacy detached label changed")

local original_command = vim.api.nvim_create_user_command
local original_keymap = vim.keymap.set
local scratch = require("repo_scratch")
local original_setup = scratch.setup
local commands = {}
local mappings = {}
vim.api.nvim_create_user_command = function(name)
	commands[name] = true
end
vim.keymap.set = function(mode, lhs)
	mappings[mode .. lhs] = true
end
scratch.setup = function()
	return true
end
host.setup()
scratch.setup = original_setup
vim.api.nvim_create_user_command = original_command
vim.keymap.set = original_keymap
assert(commands.Scratch, "host adapter did not retain :Scratch")
assert(mappings["n<leader>."], "host adapter did not retain the scratch mapping")

print("scratch_spec: full refs, full detached OIDs, and host surfaces passed")
vim.cmd("quitall!")
