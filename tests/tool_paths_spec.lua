vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local environment_names = {
	"NVIM_APPNAME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"NVIM_CONFIG_PRIMARY_DATA_ROOT",
	"NVIM_CONFIG_PRIMARY_STATE_ROOT",
	"NVIM_CONFIG_TOOLS_ROOT",
	"NVIM_CONFIG_MASON_ROOT",
}
local original = {}
for _, name in ipairs(environment_names) do
	original[name] = vim.env[name] or false
end

-- TMPDIR may contain a doubled separator (for example when the host value
-- already ends in `/`). Production paths are normalized, so normalize the
-- fixture before comparing exact strings as well.
local root = vim.fs.normalize(vim.fn.tempname())
assert(vim.fn.mkdir(root, "p") == 1)
vim.env.XDG_DATA_HOME = root .. "/data"
vim.env.XDG_STATE_HOME = root .. "/state"
vim.env.NVIM_CONFIG_PRIMARY_DATA_ROOT = nil
vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT = nil
vim.env.NVIM_CONFIG_TOOLS_ROOT = nil
vim.env.NVIM_CONFIG_MASON_ROOT = nil
package.loaded["config.tool_paths"] = nil
local paths = require("config.tool_paths")

test("primary roots are shared with the pager profile", function()
	vim.env.NVIM_APPNAME = "nvimpager"
	assert(paths.primary_data_root() == root .. "/data/nvim")
	assert(paths.primary_state_root() == root .. "/state/nvim")
	assert(paths.managed_root() == root .. "/data/nvim/nvim-tools")
	assert(paths.mason_root() == root .. "/data/nvim/mason")
	vim.env.NVIM_APPNAME = "nvim"
	assert(paths.primary_data_root() == root .. "/data/nvim")
end)

test("PATH order puts verified shims before every local, host, and managed path", function()
	local managed = paths.managed_bin()
	local mason = paths.mason_bin()
	local segments = paths.compose_segments(
		{ root .. "/local-a", root .. "/local-b", root .. "/local-a" },
		table.concat({
			"/usr/bin",
			managed,
			"/opt/bin",
			mason,
			"/usr/bin",
		}, ":")
	)
	assert(segments[1] == paths.verified_shim_bin())
	assert(segments[2] == root .. "/local-a")
	assert(segments[3] == root .. "/local-b")
	assert(segments[4] == vim.fs.normalize(vim.fn.expand("~/.local/bin")))
	assert(segments[5] == "/usr/bin")
	assert(segments[6] == "/opt/bin")
	assert(segments[7] == managed)
	assert(segments[8] == mason)
	assert(#segments == 8, "PATH segments were not exactly deduplicated")
end)

test("an explicit local override remains after verified shims but before managed roots", function()
	local managed = paths.managed_bin()
	local segments = paths.compose_segments({ managed, root .. "/custom" }, managed .. ":/usr/bin")
	assert(segments[1] == paths.verified_shim_bin())
	assert(segments[2] == managed)
	assert(segments[3] == root .. "/custom")
	local occurrences = 0
	for _, segment in ipairs(segments) do
		if segment == managed then
			occurrences = occurrences + 1
		end
	end
	assert(occurrences == 1)
end)

test("external executable probes ignore verified shims, managed, and Mason binaries", function()
	local external_bin = root .. "/external/bin"
	assert(vim.fn.mkdir(external_bin, "p") == 1)
	assert(vim.fn.mkdir(paths.managed_bin(), "p") == 1)
	assert(vim.fn.mkdir(paths.mason_bin(), "p") == 1)
	assert(vim.fn.mkdir(paths.verified_shim_bin(), "p") == 1)
	for _, directory in ipairs({ external_bin, paths.verified_shim_bin(), paths.managed_bin(), paths.mason_bin() }) do
		local executable = directory .. "/probe-tool"
		assert(vim.fn.writefile({ "#!/bin/sh", "exit 0" }, executable) == 0)
		assert(vim.fn.setfperm(executable, "rwxr-xr-x") == 1)
	end
	assert(paths.is_managed_path(paths.managed_bin() .. "/probe-tool"))
	assert(paths.is_mason_path(paths.mason_bin() .. "/probe-tool"))
	assert(paths.is_verified_shim_path(paths.verified_shim_bin() .. "/probe-tool"))
	assert(
		paths.external_executable("probe-tool", paths.managed_bin() .. ":" .. external_bin .. ":" .. paths.mason_bin())
			== external_bin .. "/probe-tool"
	)
	assert(paths.external_executable("probe-tool", paths.managed_bin() .. ":" .. paths.mason_bin()) == nil)
	assert(paths.external_executable("probe-tool", paths.verified_shim_bin()) == nil)
	assert(vim.deep_equal(paths.external_candidates("probe-tool", external_bin .. ":" .. external_bin), {
		external_bin .. "/probe-tool",
	}))
end)

for _, name in ipairs(environment_names) do
	vim.env[name] = original[name] or nil
end
vim.fn.delete(root, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tool_paths_spec: %d tests passed", count))
vim.cmd("quitall!")
