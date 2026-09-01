-- Pure value normalization shared by repository-local plugins. This module
-- intentionally has no Neovim dependency and performs no I/O.
local M = {}

local function is_integer(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

local function exact_keys(value, allowed, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, label .. " contains an unknown field: " .. tostring(key)
		end
	end
	return true
end

local function string_field(value, label, absolute)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	if absolute and value:sub(1, 1) ~= "/" then
		return nil, label .. " must be an absolute path"
	end
	return value
end

local function copy_value(value, label, active)
	local kind = type(value)
	if kind == "nil" or kind == "string" or kind == "boolean" then
		return value
	end
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, label .. " contains a non-finite number"
		end
		return value
	end
	if kind ~= "table" then
		return nil, label .. " contains an unsupported " .. kind
	end
	if active[value] then
		return nil, label .. " contains a cycle"
	end

	active[value] = true
	local result = {}
	for key, child in pairs(value) do
		local key_kind = type(key)
		if key_kind ~= "string" and (key_kind ~= "number" or not is_integer(key)) then
			active[value] = nil
			return nil, label .. " contains an unsupported table key"
		end
		local copied, copy_err = copy_value(child, label .. "." .. tostring(key), active)
		if copy_err then
			active[value] = nil
			return nil, copy_err
		end
		result[key] = copied
	end
	active[value] = nil
	return result
end

local function copy_table(value, label)
	if type(value) ~= "table" then
		return nil, label .. " must be a table"
	end
	return copy_value(value, label, {})
end

local function dense_list(value, label, minimum)
	if type(value) ~= "table" then
		return nil, label .. " must be a list"
	end
	local count = 0
	local maximum = 0
	for key in pairs(value) do
		if not is_integer(key) or key < 1 then
			return nil, label .. " must be a dense list"
		end
		count = count + 1
		maximum = math.max(maximum, key)
	end
	if count ~= maximum or count < minimum then
		return nil, label .. " must be a dense list with at least " .. minimum .. " item(s)"
	end
	return true
end

function M.normalize_workspace_key(value)
	local ok, err = exact_keys(value, { runtime = true, root = true, repo_identity = true }, "WorkspaceKey")
	if not ok then
		return nil, err
	end
	local runtime, runtime_err = string_field(value.runtime, "WorkspaceKey.runtime")
	if not runtime then
		return nil, runtime_err
	end
	local root, root_err = string_field(value.root, "WorkspaceKey.root", true)
	if not root then
		return nil, root_err
	end
	local repo_identity, identity_err = string_field(value.repo_identity, "WorkspaceKey.repo_identity")
	if not repo_identity then
		return nil, identity_err
	end
	return { runtime = runtime, root = root, repo_identity = repo_identity }
end

function M.normalize_snapshot(value)
	local ok, err = exact_keys(value, { generation = true, source = true, validity = true, value = true }, "Snapshot")
	if not ok then
		return nil, err
	end
	if not is_integer(value.generation) or value.generation < 0 then
		return nil, "Snapshot.generation must be a non-negative integer"
	end
	local source, source_err = string_field(value.source, "Snapshot.source")
	if not source then
		return nil, source_err
	end
	local validity_kind = type(value.validity)
	if validity_kind ~= "boolean" and validity_kind ~= "string" and validity_kind ~= "table" then
		return nil, "Snapshot.validity must be a boolean, string, or table"
	end
	if validity_kind == "string" and value.validity == "" then
		return nil, "Snapshot.validity must not be an empty string"
	end
	local validity, validity_err = copy_value(value.validity, "Snapshot.validity", {})
	if validity_err then
		return nil, validity_err
	end
	local snapshot_value, value_err = copy_table(value.value, "Snapshot.value")
	if not snapshot_value then
		return nil, value_err
	end
	return {
		generation = value.generation,
		source = source,
		validity = validity,
		value = snapshot_value,
	}
end

function M.normalize_action_target(value)
	local ok, err = exact_keys(
		value,
		{ bufnr = true, winid = true, tabpage = true, cursor = true, changedtick = true },
		"ActionTarget"
	)
	if not ok then
		return nil, err
	end
	for _, field in ipairs({ "bufnr", "winid", "tabpage" }) do
		if not is_integer(value[field]) or value[field] < 1 then
			return nil, "ActionTarget." .. field .. " must be a positive integer"
		end
	end
	if not is_integer(value.changedtick) or value.changedtick < 0 then
		return nil, "ActionTarget.changedtick must be a non-negative integer"
	end
	local cursor_ok, cursor_err = exact_keys(value.cursor, { line = true, col = true }, "ActionTarget.cursor")
	if not cursor_ok then
		return nil, cursor_err
	end
	if not is_integer(value.cursor.line) or value.cursor.line < 1 then
		return nil, "ActionTarget.cursor.line must be a positive integer"
	end
	if not is_integer(value.cursor.col) or value.cursor.col < 0 then
		return nil, "ActionTarget.cursor.col must be a non-negative integer"
	end
	return {
		bufnr = value.bufnr,
		winid = value.winid,
		tabpage = value.tabpage,
		cursor = { line = value.cursor.line, col = value.cursor.col },
		changedtick = value.changedtick,
	}
end

local function normalize_terminal_key(value)
	return string_field(value, "TerminalSpec.key")
end

local function normalize_argv(value)
	local ok, err = dense_list(value, "TerminalSpec.launch.argv", 1)
	if not ok then
		return nil, err
	end
	local result = {}
	for index, argument in ipairs(value) do
		if type(argument) ~= "string" or argument:find("\0", 1, true) or (index == 1 and argument == "") then
			local requirement = index == 1 and "a non-empty string without NUL bytes" or "a string without NUL bytes"
			return nil, ("TerminalSpec.launch.argv[%d] must be %s"):format(index, requirement)
		end
		result[index] = argument
	end
	return result
end

local function normalize_env(value)
	if type(value) ~= "table" then
		return nil, "TerminalSpec.launch.env must be a table"
	end
	local result = {}
	for name, content in pairs(value) do
		if type(name) ~= "string" or name == "" or name:find("[=%z]") then
			return nil, "TerminalSpec.launch.env contains an invalid variable name"
		end
		if type(content) ~= "string" or content:find("\0", 1, true) then
			return nil, "TerminalSpec.launch.env values must be strings without NUL bytes"
		end
		result[name] = content
	end
	return result
end

function M.normalize_terminal_spec(value)
	local ok, err =
		exact_keys(value, { key = true, launch = true, policy = true, view = true, metadata = true }, "TerminalSpec")
	if not ok then
		return nil, err
	end
	local key, key_err = normalize_terminal_key(value.key)
	if not key then
		return nil, key_err
	end
	local launch_ok, launch_err =
		exact_keys(value.launch, { argv = true, cwd = true, env = true }, "TerminalSpec.launch")
	if not launch_ok then
		return nil, launch_err
	end
	local argv, argv_err = normalize_argv(value.launch.argv)
	if not argv then
		return nil, argv_err
	end
	local cwd, cwd_err = string_field(value.launch.cwd, "TerminalSpec.launch.cwd", true)
	if not cwd then
		return nil, cwd_err
	end
	local env, env_err = normalize_env(value.launch.env)
	if not env then
		return nil, env_err
	end
	local policy, policy_err = copy_table(value.policy, "TerminalSpec.policy")
	if not policy then
		return nil, policy_err
	end
	local view, view_err = copy_table(value.view, "TerminalSpec.view")
	if not view then
		return nil, view_err
	end
	local metadata, metadata_err = copy_table(value.metadata, "TerminalSpec.metadata")
	if not metadata then
		return nil, metadata_err
	end
	return {
		key = key,
		launch = { argv = argv, cwd = cwd, env = env },
		policy = policy,
		view = view,
		metadata = metadata,
	}
end

function M.normalize_tool_identity(value)
	local fields = { "backend", "name", "version", "target", "digest", "install_root" }
	local allowed = {}
	for _, field in ipairs(fields) do
		allowed[field] = true
	end
	local ok, err = exact_keys(value, allowed, "ToolIdentity")
	if not ok then
		return nil, err
	end
	local result = {}
	for _, field in ipairs(fields) do
		local normalized, field_err = string_field(value[field], "ToolIdentity." .. field, field == "install_root")
		if not normalized then
			return nil, field_err
		end
		result[field] = normalized
	end
	return result
end

return M
