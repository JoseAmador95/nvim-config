vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local statusline_source = table.concat(vim.fn.readfile(repo .. "/lua/config/statusline.lua"), "\n")
for _, module in ipairs({ "config.python", "config.terminal", "config.clangd", "config.cmake" }) do
	assert(
		not statusline_source:find(('require("%s")'):format(module), 1, true),
		"statusline imports " .. module .. " during module load"
	)
end

local review_status = {
	active = true,
	mode_on = false,
	scope_kind = "range",
	scope_label = "base..head",
	layout = "split",
	context = "full",
	inline_comments = false,
	entry = { path = "lua/example.lua", layer = "history", side = "OLD" },
}
local dependencies = {
	python = {
		root = function()
			return "/repo"
		end,
		venv_name = function()
			return ".venv"
		end,
	},
	cmake = {
		status = function()
			return { preset = "debug" }
		end,
	},
	clangd = {
		profile = function()
			return "light"
		end,
	},
	review = {
		status = function()
			return vim.deepcopy(review_status)
		end,
	},
	navic = {
		is_available = function()
			return true
		end,
		get_data = function()
			return { { icon = "F", name = "cached" } }
		end,
	},
}

package.loaded["config.python"] = dependencies.python
package.loaded["config.cmake"] = dependencies.cmake
package.loaded["config.clangd"] = dependencies.clangd
package.loaded["config.code_review"] = dependencies.review
package.loaded["nvim-navic"] = dependencies.navic
package.loaded["config.local_config"] = {
	plugin = function(name, defaults)
		assert(name == "clangd_compile_db")
		local result = vim.deepcopy(defaults)
		result.profile = "light"
		return result
	end,
}

local original_root = vim.fs.root
local original_realpath = vim.uv.fs_realpath
vim.fs.root = function()
	return "/repo"
end
vim.uv.fs_realpath = function(path)
	return path
end

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, "/repo/src/main.py")
vim.b[buf].nvim_devcontainer_status = { project = "api", network = "online" }
local statusline = require("config.statusline")
statusline.setup_refresh()

vim.fs.root = original_root
vim.uv.fs_realpath = original_realpath

local observed_events = {}
local observed_user_pattern
for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "NvimConfigStatusline" })) do
	observed_events[autocmd.event] = true
	if autocmd.event == "User" then
		observed_user_pattern = autocmd.pattern
	end
end
for _, event in ipairs({ "BufEnter", "DirChanged", "LspAttach", "LspDetach" }) do
	assert(observed_events[event], "statusline cache does not observe " .. event)
end
assert(observed_user_pattern == "NvimConfig*Changed", "statusline cache misses NvimConfig*Changed events")

local original_require = require
local original_system = vim.system
local original_fn_system = vim.fn.system
local original_fn_systemlist = vim.fn.systemlist
local original_find = vim.fs.find
local original_basename = vim.fs.basename
local original_stat = vim.uv.fs_stat
local original_access = vim.uv.fs_access
local original_lstat = vim.uv.fs_lstat

local function forbidden(operation)
	return function()
		error("statusline render attempted " .. operation)
	end
end

_G.require = forbidden("require")
vim.system = forbidden("vim.system")
vim.fn.system = forbidden("vim.fn.system")
vim.fn.systemlist = forbidden("vim.fn.systemlist")
vim.fs.root = forbidden("vim.fs.root")
vim.fs.find = forbidden("vim.fs.find")
vim.fs.basename = forbidden("vim.fs.basename")
vim.uv.fs_realpath = forbidden("uv.fs_realpath")
vim.uv.fs_stat = forbidden("uv.fs_stat")
vim.uv.fs_access = forbidden("uv.fs_access")
vim.uv.fs_lstat = forbidden("uv.fs_lstat")
for name, dependency in pairs(dependencies) do
	for method in pairs(dependency) do
		dependency[method] = forbidden(name .. "." .. method)
	end
end

local ok, err = xpcall(function()
	local expected = {
		navic = "Fcached",
		python = "Py:.venv",
		cmake = "CMake:debug",
		clangd = "clangd:light",
		devcontainer = "Dev Container · api · online",
		review = "REV OFF · range:base..head · history · split/full · comments:off · OLD · lua/example.lua",
	}
	for name, label in pairs(expected) do
		assert(statusline[name]() == label, name .. " statusline label changed")
	end
end, debug.traceback)

_G.require = original_require
vim.system = original_system
vim.fn.system = original_fn_system
vim.fn.systemlist = original_fn_systemlist
vim.fs.root = original_root
vim.fs.find = original_find
vim.fs.basename = original_basename
vim.uv.fs_realpath = original_realpath
vim.uv.fs_stat = original_stat
vim.uv.fs_access = original_access
vim.uv.fs_lstat = original_lstat

assert(ok, err)
print("statusline_performance_spec: cache-only render contracts passed")
vim.cmd("quitall!")
