-- Async adapter for the public tuicr-round launcher. This module never reads
-- TUICR state or drives the TUI; every review operation crosses the launcher.
local M = {}

local LAUNCHER = vim.fn.expand("~/.config/tuicr/tuicr-round")
local MAX_BODY_BYTES = 64 * 1024
local MAX_TEXT_BYTES = 4096
local UUID_PATTERN = "^"
	.. string.rep("[0-9a-f]", 8)
	.. "%-"
	.. string.rep("[0-9a-f]", 4)
	.. "%-"
	.. string.rep("[0-9a-f]", 4)
	.. "%-"
	.. string.rep("[0-9a-f]", 4)
	.. "%-"
	.. string.rep("[0-9a-f]", 12)
	.. "$"

local SEVERITY_BY_TYPE = {
	issue = "blocker",
	suggestion = "warning",
	rationale = "warning",
	question = "warning",
	pedantic = "nit",
	praise = "nit",
}

local VALUE_KEYS = {
	type = true,
	body = true,
	anchor = true,
	author = true,
	reply_to = true,
	delivery_key = true,
}
local WRITE_OPTION_KEYS = { preflight = true }
local ANCHOR_KEYS = {
	path = true,
	side = true,
	start_line = true,
	end_line = true,
}
local SIDE_BY_STORE_SIDE = { left = "old", right = "new" }

local function failure(code, message, details)
	return { code = code, message = message, details = details or {} }
end

local function is_object(value)
	return type(value) == "table" and (next(value) == nil or not vim.islist(value))
end

local function is_null(value)
	return value == nil or value == vim.NIL
end

local function exact_keys(value, allowed, label)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return nil, failure("invalid_" .. label, label .. " contains an unknown key", { key = key })
		end
	end
	return true
end

local function bounded_text(value, maximum, label)
	if type(value) ~= "string" or value == "" or not value:find("%S") then
		return nil, failure("invalid_" .. label, label .. " must be a non-empty string")
	end
	if #value > maximum then
		return nil, failure("invalid_" .. label, label .. " is too large", { maximum = maximum })
	end
	if value:find("%z") or not pcall(vim.str_utfindex, value) then
		return nil, failure("invalid_" .. label, label .. " must be valid UTF-8 without NUL bytes")
	end
	return value
end

local function valid_uuid(value)
	return type(value) == "string" and value:match(UUID_PATTERN) ~= nil
end

local function default_root(root)
	local valid, err = bounded_text(root, MAX_TEXT_BYTES, "root")
	if not valid then
		return nil, err
	end
	if root:sub(1, 1) ~= "/" or root:find("%c") then
		return nil, failure("invalid_root", "root must be an absolute path without control bytes")
	end
	local resolved = vim.uv.fs_realpath(root)
	local stat = resolved and vim.uv.fs_stat(resolved) or nil
	if not resolved or not stat or stat.type ~= "directory" then
		return nil, failure("invalid_root", "root must identify an existing directory", { root = root })
	end
	return vim.fs.normalize(resolved)
end

local function default_author()
	if type(vim.g.review_author) == "string" and vim.g.review_author ~= "" then
		return vim.g.review_author
	end
	if type(vim.env.USER) == "string" and vim.env.USER ~= "" then
		return vim.env.USER
	end
	return "Reviewer"
end

local function make_dependencies(options)
	options = options or {}
	return {
		system = options.system or vim.system,
		schedule = options.schedule or vim.schedule,
		canonical_root = options.canonical_root or default_root,
		author = options.author,
	}
end

local function deliver(deps, callback, result, err)
	deps.schedule(function()
		callback(result, err)
	end)
end

local function process_error(result, decoded)
	if is_object(decoded) and is_object(decoded.error) then
		return decoded.error
	end
	return failure("launcher_failed", "tuicr-round exited unsuccessfully", {
		exit_code = type(result.code) == "number" and result.code or -1,
		stderr = type(result.stderr) == "string" and result.stderr or "",
	})
end

local function decode_result(result)
	if type(result) ~= "table" then
		return nil, failure("invalid_response", "vim.system returned an invalid result")
	end
	local stdout = type(result.stdout) == "string" and result.stdout or ""
	local ok, decoded = pcall(vim.json.decode, stdout)
	if result.code ~= 0 then
		return nil, process_error(result, ok and decoded or nil)
	end
	if not ok or not is_object(decoded) then
		return nil, failure("invalid_json", "tuicr-round did not return one JSON object")
	end
	if decoded.ok ~= true then
		return nil, process_error(result, decoded)
	end
	return decoded
end

local function run(deps, command, callback)
	local completed = false
	local function finish(result, err)
		if completed then
			return
		end
		completed = true
		deliver(deps, callback, result, err)
	end
	local ok, process = pcall(deps.system, command, { text = true }, function(result)
		local decoded, err = decode_result(result)
		finish(decoded, err)
	end)
	if not ok then
		finish(nil, failure("launcher_unavailable", "cannot start tuicr-round", { reason = tostring(process) }))
		return nil
	end
	return process
end

local function resolve_root(deps, root)
	local ok, resolved, err = pcall(deps.canonical_root, root)
	if not ok then
		return nil, failure("invalid_root", "cannot resolve repository root", { reason = tostring(resolved) })
	end
	if not resolved then
		return nil, is_object(err) and err or failure("invalid_root", tostring(err or "cannot resolve root"))
	end
	if type(resolved) ~= "string" or resolved:sub(1, 1) ~= "/" or resolved:find("%c") then
		return nil, failure("invalid_root", "root resolver returned an invalid absolute path")
	end
	return resolved
end

local function validate_rounds(payload, root)
	if payload.command ~= "status" or payload.repo_root ~= root or not vim.islist(payload.rounds) then
		return nil, failure("invalid_response", "tuicr-round returned invalid round metadata")
	end
	local seen = {}
	for _, round in ipairs(payload.rounds) do
		if not is_object(round) or not valid_uuid(round.round) or round.repo_root ~= root or seen[round.round] then
			return nil, failure("invalid_response", "tuicr-round returned invalid or duplicate round metadata")
		end
		seen[round.round] = true
	end
	return payload.rounds
end

local function list_rounds_canonical(deps, root, callback)
	run(deps, { LAUNCHER, "status", "--repo", root, "--all" }, function(payload, err)
		if not payload then
			callback(nil, err)
			return
		end
		local rounds, rounds_err = validate_rounds(payload, root)
		callback(rounds, rounds_err)
	end)
end

local function with_round(deps, root, round_id, callback)
	if not valid_uuid(round_id) then
		deliver(deps, callback, nil, failure("invalid_round", "round must be a canonical lowercase UUID"))
		return
	end
	list_rounds_canonical(deps, root, function(rounds, err)
		if not rounds then
			callback(nil, err)
			return
		end
		for _, metadata in ipairs(rounds) do
			if metadata.round == round_id then
				callback(metadata)
				return
			end
		end
		callback(nil, failure("round_not_found", "round is not open for this repository", { round = round_id }))
	end)
end

local function positive_integer(value, label)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		return nil, failure("invalid_anchor", label .. " must be a positive integer")
	end
	return value
end

local function validate_path(path)
	local valid, err = bounded_text(path, MAX_TEXT_BYTES, "path")
	if not valid then
		return nil, err
	end
	if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") or path:find("\\", 1, true) then
		return nil, failure("invalid_anchor", "anchor.path must be a repository-relative POSIX path")
	end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." then
			return nil, failure("invalid_anchor", "anchor.path traversal is not allowed")
		end
	end
	return path:gsub("/+", "/"):gsub("/$", "")
end

local function validate_anchor(value)
	if value == nil then
		return {}
	end
	if not is_object(value) then
		return nil, failure("invalid_anchor", "anchor must be an object")
	end
	local keys_ok, keys_err = exact_keys(value, ANCHOR_KEYS, "anchor")
	if not keys_ok then
		return nil, keys_err
	end
	local anchor = {}
	if not is_null(value.path) then
		local path, path_err = validate_path(value.path)
		if not path then
			return nil, path_err
		end
		anchor.path = path
	end
	if not is_null(value.side) then
		anchor.side = SIDE_BY_STORE_SIDE[value.side]
		if not anchor.side then
			return nil, failure("invalid_anchor", "anchor.side must be left or right")
		end
	end
	for _, key in ipairs({ "start_line", "end_line" }) do
		if not is_null(value[key]) then
			local line, line_err = positive_integer(value[key], "anchor." .. key)
			if not line then
				return nil, line_err
			end
			anchor[key] = line
		end
	end
	if (anchor.side or anchor.start_line or anchor.end_line) and not anchor.path then
		return nil, failure("invalid_anchor", "anchor target details require anchor.path")
	end
	if anchor.end_line and not anchor.start_line then
		return nil, failure("invalid_anchor", "anchor.end_line requires anchor.start_line")
	end
	if anchor.end_line and anchor.end_line < anchor.start_line then
		return nil, failure("invalid_anchor", "anchor end is before start")
	end
	return anchor
end

local function resolve_author(values, deps)
	local author = values.author
	if is_null(author) then
		author = type(deps.author) == "function" and deps.author() or deps.author
	end
	if is_null(author) then
		author = default_author()
	end
	return bounded_text(author, MAX_TEXT_BYTES, "author")
end

local function validate_values(values, response, deps)
	if not is_object(values) then
		return nil, failure("invalid_values", "values must be an object")
	end
	local keys_ok, keys_err = exact_keys(values, VALUE_KEYS, "values")
	if not keys_ok then
		return nil, keys_err
	end
	local severity = SEVERITY_BY_TYPE[values.type]
	if not severity then
		return nil, failure("invalid_type", "type must be one of the six native TUICR types", { type = values.type })
	end
	local body, body_err = bounded_text(values.body, MAX_BODY_BYTES, "body")
	if not body then
		return nil, body_err
	end
	local anchor, anchor_err = validate_anchor(values.anchor)
	if not anchor then
		return nil, anchor_err
	end
	local author, author_err = resolve_author(values, deps)
	if not author then
		return nil, author_err
	end
	local delivery_key, delivery_err = bounded_text(values.delivery_key, 256, "delivery_key")
	if not delivery_key then
		return nil, delivery_err
	end
	local reply_to
	if response then
		reply_to, body_err = bounded_text(values.reply_to, MAX_TEXT_BYTES, "reply_to")
		if not reply_to then
			return nil, body_err
		end
	elseif not is_null(values.reply_to) then
		return nil, failure("invalid_values", "add does not accept reply_to")
	end
	return {
		type = values.type,
		severity = severity,
		body = body,
		author = author,
		delivery_key = delivery_key,
		reply_to = reply_to,
		anchor = anchor,
	}
end

local function append_anchor(command, anchor)
	if anchor.path then
		command[#command + 1] = "--path=" .. anchor.path
	end
	if anchor.start_line then
		command[#command + 1] = "--start=" .. tostring(anchor.start_line)
	end
	if anchor.end_line then
		command[#command + 1] = "--end=" .. tostring(anchor.end_line)
	end
	if anchor.side then
		command[#command + 1] = "--side=" .. anchor.side
	end
end

local function comment_command(action, round_id, values)
	local command = {
		LAUNCHER,
		action,
		"--round",
		round_id,
		"--author=" .. values.author,
		"--severity=" .. values.severity,
		"--comment-type=" .. values.type,
		"--delivery-key=" .. values.delivery_key,
	}
	if action == "respond" then
		command[#command + 1] = "--reply-to=" .. values.reply_to
	end
	append_anchor(command, values.anchor)
	command[#command + 1] = "--"
	command[#command + 1] = values.body
	return command
end

local function validate_operation(payload, action, round_id)
	if payload.command ~= action or payload.round ~= round_id then
		return nil, failure("invalid_response", "tuicr-round returned mismatched operation metadata")
	end
	if not is_object(payload.tuicr) then
		return nil, failure("invalid_response", "tuicr-round omitted the TUICR write receipt")
	end
	local id = bounded_text(payload.tuicr.id, MAX_TEXT_BYTES, "comment_id")
	if not id then
		return nil, failure("invalid_response", "tuicr-round returned an invalid TUICR comment id")
	end
	return { command = action, round = round_id, id = id }
end

local function check_callback(callback)
	if type(callback) ~= "function" then
		error("callback must be a function", 3)
	end
	return callback
end

local function validate_write_options(options)
	if options == nil then
		return nil, failure("invalid_preflight", "TUICR writes require an authoritative preflight function")
	end
	if not is_object(options) then
		return nil, failure("invalid_options", "write options must be an object")
	end
	local keys_ok, keys_err = exact_keys(options, WRITE_OPTION_KEYS, "options")
	if not keys_ok then
		return nil, keys_err
	end
	if type(options.preflight) ~= "function" then
		return nil, failure("invalid_preflight", "TUICR writes require an authoritative preflight function")
	end
	return { preflight = options.preflight }
end

local function run_preflight(preflight)
	if not preflight then
		return true
	end
	local ok, allowed, reason = pcall(preflight)
	if ok and allowed == true then
		return true
	end
	if not ok then
		reason = allowed
	end
	if type(reason) == "table" then
		reason = reason.message or reason.code or vim.inspect(reason)
	end
	return nil,
		failure("preflight_failed", "TUICR write preflight rejected the operation", {
			reason = tostring(reason or "authoritative review changed"),
		})
end

function M.new(options)
	local deps = make_dependencies(options)
	local client = {}

	function client.list_rounds(root, callback)
		check_callback(callback)
		local resolved, err = resolve_root(deps, root)
		if not resolved then
			deliver(deps, callback, nil, err)
			return
		end
		list_rounds_canonical(deps, resolved, callback)
	end

	function client.comments(root, round_id, callback)
		check_callback(callback)
		local resolved, err = resolve_root(deps, root)
		if not resolved then
			deliver(deps, callback, nil, err)
			return
		end
		with_round(deps, resolved, round_id, function(_, round_err)
			if round_err then
				callback(nil, round_err)
				return
			end
			run(deps, { LAUNCHER, "comments", "--round", round_id }, function(payload, result_err)
				if not payload then
					callback(nil, result_err)
					return
				end
				if
					payload.command ~= "comments"
					or payload.round ~= round_id
					or payload.repo_root ~= resolved
					or not vim.islist(payload.comments)
					or not vim.islist(payload.threads)
				then
					callback(nil, failure("invalid_response", "tuicr-round returned invalid comment metadata"))
					return
				end
				callback(payload)
			end)
		end)
	end

	local function write(action, root, round_id, values, options, callback)
		if type(options) == "function" and callback == nil then
			callback = options
			options = nil
		end
		check_callback(callback)
		local normalized_options, options_err = validate_write_options(options)
		if not normalized_options then
			deliver(deps, callback, nil, options_err)
			return
		end
		local normalized, values_err = validate_values(values, action == "respond", deps)
		if not normalized then
			deliver(deps, callback, nil, values_err)
			return
		end
		local resolved, root_err = resolve_root(deps, root)
		if not resolved then
			deliver(deps, callback, nil, root_err)
			return
		end
		with_round(deps, resolved, round_id, function(_, round_err)
			if round_err then
				callback(nil, round_err)
				return
			end
			local allowed, preflight_err = run_preflight(normalized_options.preflight)
			if not allowed then
				callback(nil, preflight_err)
				return
			end
			run(deps, comment_command(action, round_id, normalized), function(payload, result_err)
				if not payload then
					callback(nil, result_err)
					return
				end
				callback(validate_operation(payload, action, round_id))
			end)
		end)
	end

	function client.add(root, round_id, values, options, callback)
		write("add", root, round_id, values, options, callback)
	end

	function client.respond(root, round_id, values, options, callback)
		write("respond", root, round_id, values, options, callback)
	end

	return client
end

local default = M.new()

function M.list_rounds(root, callback)
	return default.list_rounds(root, callback)
end

function M.comments(root, round_id, callback)
	return default.comments(root, round_id, callback)
end

function M.add(root, round_id, values, options, callback)
	return default.add(root, round_id, values, options, callback)
end

function M.respond(root, round_id, values, options, callback)
	return default.respond(root, round_id, values, options, callback)
end

return M
