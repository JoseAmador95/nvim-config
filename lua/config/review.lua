-- Human-owned tuicr review rounds launched from the full editor profile.
local M = {}

local LAUNCHER = vim.fn.expand("~/.config/tuicr/tuicr-round")
local cached_rounds = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Review" })
end

local function is_uuid(value)
	return type(value) == "string"
		and value:match(
				"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
			)
			~= nil
end

local function decode_start(result, root)
	if not result or result.code ~= 0 then
		local stderr = result and vim.trim(result.stderr or "") or ""
		local stdout = result and vim.trim(result.stdout or "") or ""
		local detail = stderr ~= "" and stderr or stdout
		return nil, detail ~= "" and detail or "tuicr-round exited with a nonzero status"
	end
	local stdout = result.stdout or ""
	local ok, value = pcall(vim.json.decode, stdout)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return nil, "tuicr-round did not return one JSON object"
	end
	if value.ok ~= true or value.command ~= "start" then
		local message = type(value.error) == "table" and value.error.message or nil
		return nil, message or "tuicr-round returned an unsuccessful start result"
	end
	if value.repo_root ~= root then
		return nil, "tuicr-round returned a different repository root"
	end
	if not is_uuid(value.round) then
		return nil, "tuicr-round returned an invalid round id"
	end
	return value.round
end

local function decode_status(result, root)
	local stdout = result and vim.trim(result.stdout or "") or ""
	local stderr = result and vim.trim(result.stderr or "") or ""
	local payload = stdout ~= "" and stdout or stderr
	local ok, value = pcall(vim.json.decode, payload)
	if not ok or type(value) ~= "table" or vim.islist(value) then
		return nil, payload ~= "" and payload or "tuicr-round did not return one JSON object"
	end
	if result.code == 0 and value.ok == true and value.command == "status" then
		if value.repo_root ~= root then
			return nil, "tuicr-round returned a different repository root"
		end
		if not is_uuid(value.round) then
			return nil, "tuicr-round returned an invalid round id"
		end
		return { value.round }
	end
	local error_value = type(value.error) == "table" and value.error or {}
	local details = type(error_value.details) == "table" and error_value.details or {}
	if
		result.code == 0
		or error_value.code ~= "ambiguous_round"
		or type(details.rounds) ~= "table"
		or not vim.islist(details.rounds)
	then
		return nil, error_value.message or "tuicr-round returned an unsuccessful status result"
	end
	local seen = {}
	local rounds = {}
	for _, round in ipairs(details.rounds) do
		if not is_uuid(round) or seen[round] then
			return nil, "tuicr-round returned an invalid ambiguous round list"
		end
		seen[round] = true
		rounds[#rounds + 1] = round
	end
	if #rounds < 2 then
		return nil, "tuicr-round returned an invalid ambiguous round list"
	end
	return rounds
end

local function open_terminal(root, round, dependencies)
	local selector = round and { "--round", round } or { "--repo", root }
	local argv = { LAUNCHER, "open" }
	vim.list_extend(argv, selector)
	local options = {
		runtime = "host",
		root = root,
		id = "tuicr-review",
		argv = argv,
		cwd = root,
		env = {},
		layout = "float",
		title = "tuicr review",
		passthrough = { "j", "<space>" },
		hide_keys = { "<C-t>" },
	}
	local deps = dependencies or {}
	if deps.open_terminal then
		return deps.open_terminal(argv, options)
	end
	local record, err = require("config.terminal").open(options)
	if not record then
		notify("Could not open review terminal: " .. tostring(err), vim.log.levels.ERROR)
	end
end

function M.start(root, dependencies)
	local deps = dependencies or {}
	local report = deps.notify or notify
	local system = deps.system or vim.system
	local schedule = deps.schedule or vim.schedule
	local command = { LAUNCHER, "start", "--repo", root }
	local function completed(result)
		schedule(function()
			local round, err = decode_start(result, root)
			if not round then
				report("Could not start review round: " .. err, vim.log.levels.ERROR)
				return
			end
			cached_rounds[root] = round
			open_terminal(root, round, deps)
		end)
	end
	local ok, err = pcall(system, command, { text = true }, completed)
	if not ok then
		report("Could not start review round: " .. tostring(err), vim.log.levels.ERROR)
	end
end

function M.open(root, dependencies)
	local deps = dependencies or {}
	local report = deps.notify or notify
	local requested_round = deps.round
	if requested_round ~= nil then
		if not is_uuid(requested_round) then
			report("Could not open review round: invalid round id", vim.log.levels.ERROR)
			return
		end
	end
	if requested_round == nil and cached_rounds[root] then
		open_terminal(root, cached_rounds[root], deps)
		return
	end

	local system = deps.system or vim.system
	local schedule = deps.schedule or vim.schedule
	local select = deps.select or vim.ui.select
	local selector = requested_round and { "--round", requested_round } or { "--repo", root }
	local command = { LAUNCHER, "status" }
	vim.list_extend(command, selector)
	local function completed(result)
		schedule(function()
			local rounds, err = decode_status(result, root)
			if not rounds then
				report("Could not find review round: " .. err, vim.log.levels.ERROR)
				return
			end
			if #rounds == 1 then
				if requested_round and rounds[1] ~= requested_round then
					report("Could not open review round: status returned a different round id", vim.log.levels.ERROR)
					return
				end
				cached_rounds[root] = rounds[1]
				open_terminal(root, rounds[1], deps)
				return
			end
			select(rounds, { prompt = "Select tuicr review round" }, function(round)
				if not round then
					return
				end
				M.open(root, vim.tbl_extend("force", deps, { round = round }))
			end)
		end)
	end
	local ok, err = pcall(system, command, { text = true }, completed)
	if not ok then
		report("Could not find review round: " .. tostring(err), vim.log.levels.ERROR)
	end
end

function M.setup()
	vim.api.nvim_create_user_command("ReviewRoundStart", function()
		local root, err = require("config.repo").current_root(0)
		if not root then
			notify(err, vim.log.levels.ERROR)
			return
		end
		M.start(root)
	end, { nargs = 0, desc = "Start and open an isolated tuicr review round" })

	vim.api.nvim_create_user_command("TuicrReview", function(command)
		local root, err = require("config.repo").current_root(0)
		if not root then
			notify(err, vim.log.levels.ERROR)
			return
		end
		M.open(root, { round = command.args ~= "" and command.args or nil })
	end, { nargs = "?", desc = "Open an exact tuicr review round" })
end

M._decode_start = decode_start
M._decode_status = decode_status
M._terminal_spec = function(root, round)
	local captured
	open_terminal(root, round, {
		open_terminal = function(_, options)
			captured = options
		end,
	})
	return captured
end
M._launcher = LAUNCHER

return M
