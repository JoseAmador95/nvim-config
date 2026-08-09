local M = {}

local states = {}

local function canonical(path)
	if not path then
		return nil
	end
	local absolute = vim.fn.fnamemodify(tostring(path), ":p")
	return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

function M.sync(cmake)
	local config = cmake.get_config and cmake.get_config() or nil
	local root = config and canonical(config.cwd) or nil
	local build = cmake.get_build_directory and canonical(cmake.get_build_directory()) or nil
	if not root or not build then
		return false, "CMake root or build directory is unavailable"
	end
	local ok, err = require("config.clangd").set_cmake(root, build)
	states[root] = {
		build_dir = build,
		preset = cmake.get_configure_preset and cmake.get_configure_preset() or nil,
		valid = ok,
	}
	vim.api.nvim_exec_autocmds("User", { pattern = "NvimConfigCMakeChanged", modeline = false })
	return ok, err
end

function M.setup(cmake)
	if cmake._nvim_config_generate_wrapped then
		return
	end
	cmake._nvim_config_generate_wrapped = true
	local generate = cmake.generate
	cmake.generate = function(options, callback)
		return generate(options, function(result)
			if result and type(result.is_ok) == "function" and result:is_ok() then
				M.sync(cmake)
			end
			if callback then
				callback(result)
			end
		end)
	end
end

function M.status(root)
	root = canonical(root)
	return root and states[root] or nil
end

M._states = states

return M
