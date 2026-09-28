vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local statusline_source = table.concat(vim.fn.readfile(repo .. "/lua/config/statusline.lua"), "\n")
local lualine_source = table.concat(vim.fn.readfile(repo .. "/lua/plugins/lualine.lua"), "\n")
for _, module in ipairs({ "config.python", "config.terminal", "config.clangd", "config.cmake" }) do
	assert(
		not statusline_source:find(('require("%s")'):format(module), 1, true),
		"statusline imports " .. module .. " during module load"
	)
end
assert(
	lualine_source:find("sources = { statusline.diagnostics }", 1, true),
	"lualine still uses a diagnostic source that scans during render"
)

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
local python_root_calls = {}
local cmake_state = { preset = "debug", valid = true }
local dependencies = {
	python = {
		root = function(buf, repository_root)
			python_root_calls[#python_root_calls + 1] = { buf = buf, repository_root = repository_root }
			return "/repo"
		end,
		venv_name = function()
			return ".venv"
		end,
	},
	cmake = {
		status = function()
			return vim.deepcopy(cmake_state)
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
local original_diagnostic_count = vim.diagnostic.count
local root_calls = 0
local diagnostic_count_calls = 0
local next_diagnostic_counts = {
	[vim.diagnostic.severity.ERROR] = 2,
	[vim.diagnostic.severity.WARN] = 1,
}
vim.fs.root = function()
	root_calls = root_calls + 1
	return "/repo"
end
vim.uv.fs_realpath = function(path)
	return path
end
vim.diagnostic.count = function(requested_buf)
	if requested_buf == nil or requested_buf == 0 then
		return {}
	end
	assert(vim.api.nvim_buf_is_valid(requested_buf), "diagnostic refresh used an invalid buffer")
	diagnostic_count_calls = diagnostic_count_calls + 1
	return vim.deepcopy(next_diagnostic_counts)
end

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, "/repo/src/main.py")
vim.b[buf].nvim_devcontainer_status = { project = "api", network = "online" }
local statusline = require("config.statusline")
statusline.setup_refresh()
assert(root_calls == 1, "initial statusline setup did not resolve one repository root")
assert(diagnostic_count_calls == 1, "initial statusline setup did not seed one diagnostic snapshot")
local python_root_call = python_root_calls[#python_root_calls]
assert(python_root_call.buf == buf, "statusline resolved Python for the wrong buffer")
assert(python_root_call.repository_root == "/repo", "statusline did not reuse its cached repository root")

cmake_state.valid = false
cmake_state.error = "compile database rejected"
vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
assert(statusline.cmake() == "CMake:invalid", "invalid CMake state was not visible")
cmake_state.valid = true
cmake_state.error = nil
vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
assert(statusline.cmake() == "CMake:debug", "valid CMake state did not recover its label")

vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf, modeline = false })
vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigReviewChanged", modeline = false })
assert(root_calls == 1, "stable buffer events repeated repository discovery")
assert(diagnostic_count_calls == 1, "non-diagnostic events rescanned diagnostics")

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
for _, event in ipairs({ "BufEnter", "BufFilePost", "DirChanged", "LspAttach", "LspDetach", "DiagnosticChanged" }) do
	assert(observed_events[event], "statusline cache does not observe " .. event)
end
assert(observed_user_pattern == "NvimConfig*Changed", "statusline cache misses NvimConfig*Changed events")

local original_schedule = vim.schedule
local scheduled = {}
local refresh_calls = 0
package.loaded.lualine = {
	refresh = function()
		refresh_calls = refresh_calls + 1
	end,
}
vim.schedule = function(callback)
	scheduled[#scheduled + 1] = callback
end
next_diagnostic_counts = {
	[vim.diagnostic.severity.ERROR] = 4,
	[vim.diagnostic.severity.INFO] = 3,
}
vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = buf, modeline = false, data = { diagnostics = {} } })
vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = buf, modeline = false, data = { diagnostics = {} } })
assert(#scheduled == 1, "DiagnosticChanged bursts were not coalesced")
assert(diagnostic_count_calls == 1, "DiagnosticChanged recomputed before its scheduled boundary")
scheduled[1]()
assert(diagnostic_count_calls == 2, "coalesced diagnostic refresh did not update exactly once")
assert(refresh_calls == 1, "coalesced diagnostic refresh repainted lualine more than once")
assert(
	vim.deep_equal(statusline.diagnostics(), { error = 4, warn = 0, info = 3, hint = 0 }),
	"cached diagnostic source did not publish normalized severity counts"
)

local doomed = vim.api.nvim_create_buf(false, true)
statusline.refresh_buffer(doomed)
local before_wipeout = diagnostic_count_calls
scheduled = {}
vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = doomed, modeline = false, data = { diagnostics = {} } })
assert(#scheduled == 1, "doomed-buffer diagnostic refresh was not scheduled")
vim.api.nvim_exec_autocmds("BufWipeout", { buffer = doomed, modeline = false })
scheduled[1]()
assert(diagnostic_count_calls == before_wipeout, "BufWipeout did not invalidate queued diagnostic work")
vim.api.nvim_buf_delete(doomed, { force = true })
vim.schedule = original_schedule

local original_require = require
local original_system = vim.system
local original_fn_system = vim.fn.system
local original_fn_systemlist = vim.fn.systemlist
local original_find = vim.fs.find
local original_basename = vim.fs.basename
local original_stat = vim.uv.fs_stat
local original_access = vim.uv.fs_access
local original_lstat = vim.uv.fs_lstat
local original_diagnostic_get = vim.diagnostic.get

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
vim.diagnostic.count = forbidden("vim.diagnostic.count")
vim.diagnostic.get = forbidden("vim.diagnostic.get")
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
		diagnostics = { error = 4, warn = 0, info = 3, hint = 0 },
	}
	for name, label in pairs(expected) do
		assert(vim.deep_equal(statusline[name](), label), name .. " statusline label changed")
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
vim.diagnostic.count = original_diagnostic_count
vim.diagnostic.get = original_diagnostic_get
package.loaded.lualine = nil

assert(ok, err)
print("statusline_performance_spec: cache-only render contracts passed")
vim.cmd("quitall!")
