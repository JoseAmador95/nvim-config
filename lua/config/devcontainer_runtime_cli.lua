-- Strict command adapter for the headless Dev Container runtime helper.
local M = {}

local uv = vim.uv

local function canonical_directory(path)
	if type(path) ~= "string" or path == "" or path:find("[%c]") then
		return nil, "repository must be one control-free absolute path"
	end
	if path:sub(1, 1) ~= "/" or path:sub(1, 2) == "//" then
		return nil, "repository must be one control-free absolute path"
	end
	local normalized = vim.fs.normalize(path)
	local resolved = uv.fs_realpath(normalized)
	local stat = resolved and uv.fs_stat(resolved) or nil
	if not resolved or resolved ~= normalized or not stat or stat.type ~= "directory" then
		return nil, "repository must be one canonical existing directory"
	end
	return resolved
end

local function output_path(path, label)
	if type(path) ~= "string" or path == "" or path:find("[%c]") then
		return nil, label .. " returned an invalid path"
	end
	if path:sub(1, 1) ~= "/" or path:sub(1, 2) == "//" or vim.fs.normalize(path) ~= path then
		return nil, label .. " returned a non-canonical path"
	end
	return path
end

local function call(adapter, method, repo)
	local callback = adapter and adapter[method]
	if type(callback) ~= "function" then
		return nil, "Dev Container host adapter does not implement " .. method
	end
	local called, value, err = pcall(callback, repo)
	if not called then
		return nil, tostring(value)
	end
	return value, err
end

---Execute one strict headless helper command.
---@param argv string[]
---@param adapter table
---@return string|nil stdout
---@return string|nil error
function M.execute(argv, adapter)
	if type(argv) ~= "table" or #argv ~= 2 then
		return nil, "usage: prepare-up|preflight-record <canonical-repository>"
	end
	local command = argv[1]
	if command ~= "prepare-up" and command ~= "preflight-record" then
		return nil, "usage: prepare-up|preflight-record <canonical-repository>"
	end
	local repo, repo_err = canonical_directory(argv[2])
	if not repo then
		return nil, repo_err
	end
	if command == "preflight-record" then
		local ok, err = call(adapter, "preflight_record", repo)
		return ok and "" or nil, ok and nil or err
	end

	local runtime, runtime_err = call(adapter, "prepare_up", repo)
	if not runtime then
		return nil, runtime_err
	end
	if type(runtime) ~= "table" then
		return nil, "Dev Container host adapter returned an invalid runtime"
	end
	local cli, cli_err = output_path(runtime.cli_path, "certified Dev Containers CLI")
	if not cli then
		return nil, cli_err
	end
	local docker, docker_err = output_path(runtime.docker_path, "Docker-compatible engine")
	if not docker then
		return nil, docker_err
	end
	return cli .. "\t" .. docker .. "\n"
end

return M
