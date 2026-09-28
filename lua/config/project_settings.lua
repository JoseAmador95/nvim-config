-- Approved project LSP settings from .neoconf.json and .vscode/settings.json.
--
-- trusted-workspace owns only the fingerprint approval. This adapter reads and
-- parses both files once per operation, then revalidates their complete
-- metadata identities immediately before any setting reaches an LSP client.
local M = {}

local authority_module = require("trusted_workspace")
local contracts = require("local_plugins.contracts")
local repo_module = require("config.repo")

local uv = vim.uv
local MAX_FILE_BYTES = 1024 * 1024
local SOURCE_ID = "project-lsp-settings"
local SOURCE_PRIORITY = 100
local FILES = { ".neoconf.json", ".vscode/settings.json" }
local NIL_DEFAULT = {}

local configured = {
	authority = authority_module,
	repo = repo_module,
	notify = vim.notify,
}
local command_registered = false
local warned = {}

local function copy(value)
	return vim.deepcopy(value)
end

local function active_profile()
	if configured.active ~= nil then
		return configured.active == true
	end
	return not vim.g.vscode and vim.env.NVIM_APPNAME ~= "nvimpager"
end

local function notify_once(message, level)
	if not warned[message] and type(configured.notify) == "function" then
		warned[message] = true
		configured.notify(message, level or vim.log.levels.WARN, { title = "Project settings" })
	end
end

local function notify(message, level)
	if type(configured.notify) == "function" then
		configured.notify(message, level or vim.log.levels.INFO, { title = "Project settings" })
	end
end

local IDENTITY_FIELDS = { "type", "dev", "ino", "size", "mode", "uid", "gid", "nlink" }

local function identity(info)
	if not info then
		return nil
	end
	local result = {}
	for _, field in ipairs(IDENTITY_FIELDS) do
		result[field] = info[field]
	end
	for _, field in ipairs({ "mtime", "ctime" }) do
		local timestamp = info[field]
		result[field] = timestamp and { sec = timestamp.sec, nsec = timestamp.nsec } or nil
	end
	return result
end

local function same_identity(left, right)
	if not left or not right then
		return false
	end
	for _, field in ipairs(IDENTITY_FIELDS) do
		if left[field] ~= right[field] then
			return false
		end
	end
	for _, field in ipairs({ "mtime", "ctime" }) do
		local left_time = left[field]
		local right_time = right[field]
		if not left_time or not right_time or left_time.sec ~= right_time.sec or left_time.nsec ~= right_time.nsec then
			return false
		end
	end
	return true
end

local function contained(root, path)
	root = vim.fs.normalize(root):gsub("/+$", "")
	path = vim.fs.normalize(path)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function missing_error(err)
	return tostring(err):find("ENOENT", 1, true) ~= nil
end

local function inspect_fixed_parent(root, relative)
	local parent_relative = vim.fs.dirname(relative)
	if parent_relative == "." then
		return false
	end
	local parent = vim.fs.joinpath(root, parent_relative)
	local info, err = uv.fs_lstat(parent)
	if not info then
		if err == nil or missing_error(err) then
			return false
		end
		return nil, "could not inspect " .. parent_relative .. ": " .. tostring(err)
	end
	if info.type ~= "directory" or uv.fs_realpath(parent) ~= vim.fs.normalize(parent) then
		return nil, parent_relative .. " must be a real directory without symlinks"
	end
	return info
end

local function read_project_file(root, root_identity, relative)
	local path = vim.fs.joinpath(root, relative)
	local current_root = uv.fs_lstat(root)
	if not current_root or current_root.type ~= "directory" or not same_identity(root_identity, current_root) then
		return nil, "repository root identity changed while reading project settings"
	end
	local parent_info, parent_err = inspect_fixed_parent(root, relative)
	if parent_info == nil then
		return nil, parent_err
	end
	local parent_present = parent_info ~= false
	local parent_identity = parent_present and identity(parent_info) or nil
	local before, before_err = uv.fs_lstat(path)
	if not before then
		if before_err == nil or missing_error(before_err) then
			local root_after = uv.fs_lstat(root)
			local parent_after, after_err = inspect_fixed_parent(root, relative)
			if
				not root_after
				or not same_identity(root_identity, root_after)
				or (parent_present and (not parent_after or not same_identity(parent_identity, parent_after)))
				or (not parent_present and parent_after)
			then
				return nil,
					"repository hierarchy changed while checking " .. relative .. ": " .. tostring(
						after_err or "identity mismatch"
					)
			end
			return {
				name = relative,
				path = path,
				present = false,
				raw = "",
				parent_present = parent_present,
				parent_identity = parent_identity,
			}
		end
		return nil, "could not inspect " .. relative .. ": " .. tostring(before_err)
	end
	if before.type ~= "file" or before.nlink ~= 1 then
		return nil, relative .. " must be a single-link regular file"
	end
	if before.size > MAX_FILE_BYTES then
		return nil, relative .. " exceeds the 1 MiB limit"
	end
	local resolved = uv.fs_realpath(path)
	if not resolved or not contained(root, resolved) or vim.fs.normalize(resolved) ~= vim.fs.normalize(path) then
		return nil, relative .. " must use its fixed real path without symlinks"
	end
	local fd, open_err = uv.fs_open(path, "r", 0)
	if not fd then
		return nil, "could not open " .. relative .. ": " .. tostring(open_err)
	end
	local opened, opened_err = uv.fs_fstat(fd)
	if
		not opened
		or opened.type ~= "file"
		or opened.nlink ~= 1
		or opened.size > MAX_FILE_BYTES
		or not same_identity(before, opened)
	then
		pcall(uv.fs_close, fd)
		return nil,
			relative .. " changed or became unsafe while opening: " .. tostring(opened_err or "identity mismatch")
	end
	local raw, read_err = uv.fs_read(fd, opened.size, 0)
	local closed, close_err = uv.fs_close(fd)
	local after, after_err = uv.fs_lstat(path)
	local resolved_after = uv.fs_realpath(path)
	local root_after = uv.fs_lstat(root)
	local parent_after, parent_after_err = inspect_fixed_parent(root, relative)
	if not raw or #raw ~= opened.size then
		return nil, "could not read complete " .. relative .. ": " .. tostring(read_err or "short read")
	end
	if not closed then
		return nil, "could not close " .. relative .. ": " .. tostring(close_err)
	end
	if
		not after
		or after.type ~= "file"
		or after.nlink ~= 1
		or not same_identity(opened, after)
		or not resolved_after
		or not contained(root, resolved_after)
		or vim.fs.normalize(resolved_after) ~= vim.fs.normalize(path)
		or not root_after
		or not same_identity(root_identity, root_after)
		or (parent_present and (not parent_after or not same_identity(parent_identity, parent_after)))
		or (not parent_present and parent_after)
	then
		return nil,
			relative .. " changed or escaped while reading: " .. tostring(
				after_err or parent_after_err or "identity mismatch"
			)
	end
	return {
		name = relative,
		path = path,
		present = true,
		raw = raw,
		identity = identity(after),
		parent_present = parent_present,
		parent_identity = parent_identity,
	}
end

local function strip_jsonc_comments(raw)
	local output = {}
	local index = 1
	local state = "normal"
	local escaped = false
	while index <= #raw do
		local char = raw:sub(index, index)
		local next_char = raw:sub(index + 1, index + 1)
		if state == "string" then
			output[#output + 1] = char
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				state = "normal"
			end
		elseif state == "line-comment" then
			if char == "\n" or char == "\r" then
				output[#output + 1] = char
				state = "normal"
			else
				output[#output + 1] = " "
			end
		elseif state == "block-comment" then
			if char == "*" and next_char == "/" then
				output[#output + 1] = " "
				output[#output + 1] = " "
				index = index + 1
				state = "normal"
			elseif char == "\n" or char == "\r" then
				output[#output + 1] = char
			else
				output[#output + 1] = " "
			end
		elseif char == '"' then
			output[#output + 1] = char
			state = "string"
		elseif char == "/" and next_char == "/" then
			output[#output + 1] = " "
			output[#output + 1] = " "
			index = index + 1
			state = "line-comment"
		elseif char == "/" and next_char == "*" then
			output[#output + 1] = " "
			output[#output + 1] = " "
			index = index + 1
			state = "block-comment"
		else
			output[#output + 1] = char
		end
		index = index + 1
	end
	if state == "string" or state == "block-comment" then
		return nil, "unterminated JSONC " .. (state == "string" and "string" or "comment")
	end
	return table.concat(output)
end

local function strip_trailing_commas(raw)
	local output = {}
	local index = 1
	local in_string = false
	local escaped = false
	while index <= #raw do
		local char = raw:sub(index, index)
		if in_string then
			output[#output + 1] = char
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				in_string = false
			end
		elseif char == '"' then
			output[#output + 1] = char
			in_string = true
		elseif char == "," then
			local lookahead = index + 1
			while lookahead <= #raw and raw:sub(lookahead, lookahead):match("%s") do
				lookahead = lookahead + 1
			end
			local following = raw:sub(lookahead, lookahead)
			output[#output + 1] = (following == "}" or following == "]") and " " or char
		else
			output[#output + 1] = char
		end
		index = index + 1
	end
	return table.concat(output)
end

local function parse_jsonc(raw, label)
	local stripped, strip_err = strip_jsonc_comments(raw)
	if not stripped then
		return nil, label .. ": " .. strip_err
	end
	local ok, value = pcall(vim.json.decode, strip_trailing_commas(stripped))
	if not ok then
		return nil, label .. " is invalid JSONC: " .. tostring(value)
	end
	if type(value) ~= "table" or vim.islist(value) then
		return nil, label .. " root must be an object"
	end
	return value
end

local function dotted_assign(destination, key, value, label)
	local parts = vim.split(key, ".", { plain = true })
	for _, part in ipairs(parts) do
		if part == "" then
			return nil, label .. " contains an empty dotted-key segment: " .. key
		end
	end
	local current = destination
	for index = 1, #parts - 1 do
		local part = parts[index]
		if current[part] == nil then
			current[part] = {}
		elseif type(current[part]) ~= "table" or vim.islist(current[part]) then
			return nil, label .. " conflicts with " .. table.concat(parts, ".", 1, index)
		end
		current = current[part]
	end
	local leaf = parts[#parts]
	if current[leaf] ~= nil then
		return nil, label .. " contains a duplicate expanded key: " .. key
	end
	current[leaf] = copy(value)
	return true
end

local function expand_dotted(value, label)
	local expanded = {}
	local keys = vim.tbl_keys(value)
	table.sort(keys)
	for _, key in ipairs(keys) do
		if type(key) ~= "string" then
			return nil, label .. " keys must be strings"
		end
		local ok, err = dotted_assign(expanded, key, value[key], label)
		if not ok then
			return nil, err
		end
	end
	return expanded
end

local function expand_vscode(value)
	return expand_dotted(value, "VSCode settings")
end

local function expand_neoconf(value)
	local expanded, err = expand_dotted(value, "Neoconf settings")
	if not expanded then
		return nil, err
	end
	local lspconfig = expanded.lspconfig
	if type(lspconfig) ~= "table" or vim.islist(lspconfig) then
		return expanded
	end
	local servers = vim.tbl_keys(lspconfig)
	table.sort(servers)
	for _, server in ipairs(servers) do
		local settings = lspconfig[server]
		if type(settings) == "table" and not vim.islist(settings) then
			local server_settings, server_err = expand_dotted(settings, "Neoconf lspconfig." .. tostring(server))
			if not server_settings then
				return nil, server_err
			end
			lspconfig[server] = server_settings
		end
	end
	return expanded
end

local function combined_fingerprint(files)
	local parts = { "nvim-project-lsp-settings\0v1\0" }
	for _, item in ipairs(files) do
		parts[#parts + 1] = item.name
		parts[#parts + 1] = "\0"
		parts[#parts + 1] = item.present and "present\0" or "absent\0"
		parts[#parts + 1] = tostring(#item.raw)
		parts[#parts + 1] = "\0"
		parts[#parts + 1] = item.raw
		parts[#parts + 1] = "\0"
	end
	return vim.fn.sha256(table.concat(parts))
end

local function workspace_for(root)
	local workspace
	if vim.env.NVIM_DEVCONTAINER ~= "1" then
		workspace = { runtime = "host", root = root, repo_identity = root }
	else
		workspace = {
			runtime = vim.env.NVIM_EXACT_EDITOR_RUNTIME,
			root = vim.env.NVIM_EXACT_EDITOR_WORKSPACE_ROOT,
			repo_identity = vim.env.NVIM_EXACT_EDITOR_REPO_IDENTITY,
		}
		if workspace.runtime ~= "container" then
			return nil, "Dev Container project settings require the exact editor runtime metadata"
		end
	end
	local normalized, err = contracts.normalize_workspace_key(workspace)
	if not normalized then
		return nil, "project settings WorkspaceKey is invalid: " .. tostring(err)
	end
	if normalized.root ~= root then
		return nil, "project settings repository root does not match the exact editor WorkspaceKey"
	end
	return normalized
end

local function register_candidate(candidate)
	local _, err = configured.authority.register_source({
		id = SOURCE_ID,
		layer = "project",
		priority = SOURCE_PRIORITY,
		enabled = candidate.present,
		workspace = candidate.workspace,
		fingerprint = candidate.fingerprint,
		value = {},
	})
	return err == nil and true or nil, err
end

local function durable_approval(candidate)
	if type(configured.authority.has_approval) ~= "function" then
		return nil, "trusted-workspace durable approval API is unavailable"
	end
	return configured.authority.has_approval({
		workspace = candidate.workspace,
		source = SOURCE_ID,
		fingerprint = candidate.fingerprint,
	})
end

local function resolve_root(start)
	if not active_profile() then
		return nil, "project settings are disabled in this profile"
	end
	local root, err = configured.repo.root(start)
	if not root then
		return nil, err
	end
	root = uv.fs_realpath(root)
	local stat = root and uv.fs_lstat(root) or nil
	if not root or not stat or stat.type ~= "directory" then
		return nil, "repository root is not a real directory"
	end
	return vim.fs.normalize(root)
end

local function read_candidate(start)
	local root, root_err = resolve_root(start)
	if not root then
		return nil, root_err
	end
	local root_info = uv.fs_lstat(root)
	if not root_info or root_info.type ~= "directory" then
		return nil, "repository root is unavailable"
	end
	local root_identity = identity(root_info)
	local workspace, workspace_err = workspace_for(root)
	if not workspace then
		return nil, workspace_err
	end
	local files = {}
	for _, relative in ipairs(FILES) do
		local item, read_err = read_project_file(root, root_identity, relative)
		if not item then
			return nil, read_err
		end
		files[#files + 1] = item
	end
	local present = files[1].present or files[2].present
	local neoconf = {}
	local vscode = {}
	if files[1].present then
		local parsed, parse_err = parse_jsonc(files[1].raw, files[1].name)
		if not parsed then
			return nil, parse_err
		end
		neoconf, parse_err = expand_neoconf(parsed)
		if not neoconf then
			return nil, parse_err
		end
	end
	if files[2].present then
		local parsed, parse_err = parse_jsonc(files[2].raw, files[2].name)
		if not parsed then
			return nil, parse_err
		end
		vscode, parse_err = expand_vscode(parsed)
		if not vscode then
			return nil, parse_err
		end
	end
	return {
		root = root,
		root_identity = root_identity,
		workspace = workspace,
		present = present,
		fingerprint = combined_fingerprint(files),
		files = files,
		values = { vscode = vscode, neoconf = neoconf },
	}
end

local function revalidate_project_file(root, item)
	local parent_info, parent_err = inspect_fixed_parent(root, item.name)
	if parent_info == nil then
		return nil, parent_err
	end
	local parent_present = parent_info ~= false
	if parent_present ~= item.parent_present then
		return nil, item.name .. " parent presence changed"
	end
	if parent_present and not same_identity(item.parent_identity, parent_info) then
		return nil, item.name .. " parent identity changed"
	end

	local current, current_err = uv.fs_lstat(item.path)
	if not item.present then
		if current or (current_err ~= nil and not missing_error(current_err)) then
			return nil, item.name .. " presence changed"
		end
		local parent_after, parent_after_err = inspect_fixed_parent(root, item.name)
		local after, after_err = uv.fs_lstat(item.path)
		if
			after
			or (after_err ~= nil and not missing_error(after_err))
			or parent_after == nil
			or (parent_after ~= false) ~= item.parent_present
			or (item.parent_present and not same_identity(item.parent_identity, parent_after))
		then
			return nil, parent_after_err or (item.name .. " changed while its absence was revalidated")
		end
		return true
	end
	if
		not current
		or current.type ~= "file"
		or current.nlink ~= 1
		or current.size > MAX_FILE_BYTES
		or not same_identity(item.identity, current)
	then
		return nil, item.name .. " identity changed"
	end
	local resolved = uv.fs_realpath(item.path)
	if not resolved or not contained(root, resolved) or vim.fs.normalize(resolved) ~= vim.fs.normalize(item.path) then
		return nil, item.name .. " escaped its fixed path"
	end
	local after = uv.fs_lstat(item.path)
	local parent_after, parent_after_err = inspect_fixed_parent(root, item.name)
	if
		not after
		or not same_identity(item.identity, after)
		or parent_after == nil
		or (parent_after ~= false) ~= item.parent_present
		or (item.parent_present and not same_identity(item.parent_identity, parent_after))
	then
		return nil, parent_after_err or (item.name .. " changed while its identity was revalidated")
	end
	return true
end

local function global_value(key, default, file)
	local neoconf = configured.neoconf or package.loaded.neoconf
	if type(neoconf) ~= "table" or type(neoconf.get) ~= "function" then
		return copy(default), "neoconf public API is unavailable"
	end
	local ok, value = pcall(neoconf.get, key, copy(default), {
		file = file,
		["local"] = false,
		global = true,
	})
	if not ok then
		return copy(default), "neoconf global settings failed: " .. tostring(value)
	end
	if key:match("^lspconfig%.") and type(value) == "table" and not vim.islist(value) then
		local expanded, expand_err = expand_dotted(value, "global Neoconf " .. key)
		if not expanded then
			return copy(default), expand_err
		end
		value = expanded
	end
	return copy(value)
end

local function project_value(candidate, key)
	if key == "vscode" then
		return candidate.values.vscode
	end
	local server = key:match("^lspconfig%.(.+)$")
	if server then
		local lspconfig = candidate.values.neoconf.lspconfig
		if type(lspconfig) == "table" then
			return lspconfig[server]
		end
	end
	return nil
end

local function revalidate_candidate(candidate)
	local root_before = uv.fs_lstat(candidate.root)
	if
		not root_before
		or root_before.type ~= "directory"
		or not same_identity(candidate.root_identity, root_before)
	then
		return nil, "project settings changed during fingerprint validation"
	end
	local workspace = workspace_for(candidate.root)
	if not workspace or not vim.deep_equal(workspace, candidate.workspace) then
		return nil, "project settings changed during fingerprint validation"
	end
	for _, item in ipairs(candidate.files) do
		local valid = revalidate_project_file(candidate.root, item)
		if not valid then
			return nil, "project settings changed during fingerprint validation"
		end
	end
	local root_after = uv.fs_lstat(candidate.root)
	if not root_after or root_after.type ~= "directory" or not same_identity(candidate.root_identity, root_after) then
		return nil, "project settings changed during fingerprint validation"
	end
	return candidate
end

function M.snapshot(start)
	local candidate, candidate_err = read_candidate(start)
	if not candidate then
		return nil, candidate_err
	end
	local registered, register_err = register_candidate(candidate)
	if not registered then
		return nil, register_err
	end
	local current, current_err = revalidate_candidate(candidate)
	if not current then
		return nil, current_err
	end
	local approved = false
	if current.present then
		local approval_err
		approved, approval_err = durable_approval(current)
		if approved == nil then
			return nil, approval_err
		end
		current, current_err = revalidate_candidate(current)
		if not current then
			return nil, current_err
		end
	end
	return copy({
		root = current.root,
		workspace = current.workspace,
		present = current.present,
		fingerprint = current.fingerprint,
		approved = approved,
		values = approved and current.values or { vscode = {}, neoconf = {} },
	})
end

---Resolve multiple project settings through one candidate, approval lookup, and
---metadata revalidation. Every returned value is a caller-owned copy.
---@param defaults table<string, any>
---@param start string
---@return table<string, any> values
---@return string? error_message
function M.get_many(defaults, start)
	if type(defaults) ~= "table" then
		error("project setting defaults must be a table")
	end
	local keys = vim.tbl_keys(defaults)
	for _, key in ipairs(keys) do
		if type(key) ~= "string" or key == "" then
			error("project setting keys must be strings")
		end
	end
	table.sort(keys)
	local globals = {}
	local global_err
	for _, key in ipairs(keys) do
		local default = defaults[key] == NIL_DEFAULT and nil or defaults[key]
		local value, value_err = global_value(key, default, start)
		globals[key] = value
		global_err = global_err or value_err
	end

	local candidate, candidate_err = read_candidate(start)
	if not candidate then
		if candidate_err and not candidate_err:find("not inside a Git repository", 1, true) then
			notify_once(candidate_err)
		end
		return globals, candidate_err or global_err
	end
	local registered, register_err = register_candidate(candidate)
	if not registered then
		notify_once("could not register project settings fingerprint: " .. tostring(register_err))
		return globals, register_err
	end
	local current, current_err = revalidate_candidate(candidate)
	if not current then
		return globals, current_err
	end
	if not current.present then
		return globals, global_err
	end
	local approved, approval_err = durable_approval(current)
	if approved ~= true then
		return globals, approval_err or "project settings are not approved"
	end
	current, current_err = revalidate_candidate(current)
	if not current then
		return globals, current_err
	end
	local result = globals
	for _, key in ipairs(keys) do
		local project = project_value(current, key)
		if project ~= nil then
			if type(result[key]) == "table" and type(project) == "table" then
				result[key] = vim.tbl_deep_extend("force", {}, result[key], copy(project))
			else
				result[key] = copy(project)
			end
		end
	end
	return result, global_err
end

function M.get(key, default, start)
	local values, err = M.get_many({ [key] = default == nil and NIL_DEFAULT or default }, start)
	return values[key], err
end

function M.approve(start)
	local candidate, candidate_err = read_candidate(start)
	if not candidate then
		return nil, candidate_err
	end
	if not candidate.present then
		return nil, "no .neoconf.json or .vscode/settings.json exists in this repository"
	end
	local registered, register_err = register_candidate(candidate)
	if not registered then
		return nil, register_err
	end
	local approved, approval_err = configured.authority.approve({
		workspace = candidate.workspace,
		source = SOURCE_ID,
		fingerprint = candidate.fingerprint,
	})
	if not approved then
		return nil, approval_err
	end
	local current, current_err = revalidate_candidate(candidate)
	if not current then
		return nil, current_err
	end
	return copy({ root = current.root, fingerprint = current.fingerprint })
end

local function command_start()
	local name = vim.api.nvim_buf_get_name(0)
	return name ~= "" and name or (uv.cwd() or vim.fn.getcwd())
end

function M.setup(opts)
	opts = opts or {}
	configured = vim.tbl_extend("force", configured, opts)
	if active_profile() and opts.command ~= false and not command_registered then
		vim.api.nvim_create_user_command("NvimConfigTrustProjectSettings", function()
			local result, err = M.approve(command_start())
			if not result then
				notify_once("Project settings were not approved: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			notify(
				"Approved current project LSP settings fingerprint; restart existing LSP clients to apply it",
				vim.log.levels.INFO
			)
		end, { desc = "Approve current project .neoconf/.vscode LSP settings" })
		command_registered = true
	end
	return M
end

M.SOURCE_ID = SOURCE_ID
M.MAX_FILE_BYTES = MAX_FILE_BYTES

return M
