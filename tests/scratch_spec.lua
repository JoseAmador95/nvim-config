vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "repo_scratch")
		return vim.deepcopy(defaults)
	end,
}

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

local original_open = scratch.open
local original_prune = scratch.prune
local original_renew = scratch.renew
local original_release = scratch.release
local original_save = scratch.save
local original_teardown = scratch.teardown
local original_notify = vim.notify
local original_snacks = package.loaded.snacks
local notifications = {}
local renewals = 0
local releases = 0
local saves = 0
local timers = {}
local handle = {
	path = vim.fn.tempname() .. ".md",
	lease_path = vim.fn.tempname() .. ".lease",
	lease_token = string.rep("b", 64),
	revision = string.rep("c", 64),
	key = { repo_identity = "/repo", ref = branch },
}

scratch.setup = function()
	return true
end
scratch.prune = function()
	return {}
end
scratch.open = function()
	return vim.deepcopy(handle)
end
scratch.renew = function()
	renewals = renewals + 1
	return nil, "scratch lease was lost"
end
scratch.release = function()
	releases = releases + 1
	return true
end
scratch.save = function()
	saves = saves + 1
	return vim.deepcopy(handle)
end
scratch.teardown = function()
	return true
end
vim.notify = function(message)
	notifications[#notifications + 1] = tostring(message)
end
package.loaded.snacks = {
	scratch = {
		open = function(options)
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(buf, options.file)
			vim.bo[buf].buftype = "acwrite"
			vim.api.nvim_set_current_buf(buf)
			return { buf = buf }
		end,
	},
}
package.loaded["config.repo"].current_root = function()
	return "/repo"
end

local function new_timer()
	local timer = { stopped = false, closed = false }
	function timer:start(timeout, repeat_interval, callback)
		self.timeout = timeout
		self.repeat_interval = repeat_interval
		self.callback = callback
		timers[#timers + 1] = self
		return 0
	end
	function timer:stop()
		self.stopped = true
	end
	function timer:is_closing()
		return self.closed
	end
	function timer:close()
		self.closed = true
	end
	return timer
end

assert(host.setup({
	state_root = vim.fn.tempname(),
	new_timer = new_timer,
	schedule = function(callback)
		callback()
	end,
}))
local win = assert(host.open())
local buf = assert(win.buf)
assert(#timers == 1, "host did not start one lease heartbeat")
assert(timers[1].timeout == 100000 and timers[1].repeat_interval == 100000, "heartbeat is not lease/3")
assert(host.status().buffers[1].lease_lost == false)
timers[1].callback()
assert(renewals == 1, "heartbeat did not renew the lease")
local lost = host.status().buffers[1]
assert(lost.lease_lost and lost.error:find("lease was lost", 1, true), "lease loss is missing from status")
assert(timers[1].stopped and timers[1].closed, "lease-loss heartbeat kept running")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "must not save" })
vim.bo[buf].modified = true
vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf, modeline = false })
assert(saves == 0, "lease-lost buffer reached repo_scratch.save")
assert(notifications[#notifications]:find("lease-lost", 1, true), "blocked save did not report lease loss")
vim.api.nvim_buf_delete(buf, { force = true })
assert(releases == 1, "buffer deletion did not release the scratch handle")
assert(#host.status().buffers == 0, "deleted scratch retained a heartbeat status")
assert(host.teardown())

scratch.open = original_open
scratch.prune = original_prune
scratch.renew = original_renew
scratch.release = original_release
scratch.save = original_save
scratch.teardown = original_teardown
vim.notify = original_notify
package.loaded.snacks = original_snacks

print("scratch_spec: full refs, host surfaces, and lease-loss blocking passed")
vim.cmd("quitall!")
