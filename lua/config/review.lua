-- Human-owned tuicr review rounds launched from the full editor profile.
local M = {}

local LAUNCHER = vim.fn.expand("~/.config/tuicr/tuicr-round")
local cached_rounds = {}
local review_terminal
local review_command

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

local function terminal_options(command)
	return {
		cmd = command,
		direction = "float",
		hidden = true,
		close_on_exit = true,
		float_opts = {
			width = function()
				return math.max(1, math.floor(vim.o.columns * 0.95))
			end,
			height = function()
				return math.max(1, math.floor(vim.o.lines * 0.95))
			end,
		},
		on_open = function(term)
			vim.cmd("startinsert!")
			local options = { buffer = term.bufnr, nowait = true }
			vim.keymap.set("t", "j", "j", options)
			vim.keymap.set("t", "<space>", "<space>", options)
			vim.keymap.set({ "n", "t" }, "<C-t>", function()
				term:close()
			end, { buffer = term.bufnr, nowait = true, silent = true, desc = "Hide review terminal" })
		end,
	}
end

local function shell_command(arguments)
	local escaped = {}
	for _, argument in ipairs(arguments) do
		escaped[#escaped + 1] = vim.fn.shellescape(argument)
	end
	return table.concat(escaped, " ")
end

local function open_terminal(root, round, dependencies)
	local selector = round and { "--round", round } or { "--repo", root }
	local arguments = { LAUNCHER, "open" }
	vim.list_extend(arguments, selector)
	local command = shell_command(arguments)
	local deps = dependencies or {}
	if deps.open_terminal then
		return deps.open_terminal(command, terminal_options(command))
	end

	require("lazy").load({ plugins = { "toggleterm.nvim" } })
	local ok, terminal_module = pcall(require, "toggleterm.terminal")
	if not ok then
		notify("toggleterm.nvim is required for review rounds", vim.log.levels.ERROR)
		return
	end

	if review_terminal and review_terminal:is_open() and review_command == command then
		review_terminal:focus()
		return
	end
	if review_terminal and review_command ~= command then
		review_terminal:shutdown()
		review_terminal = nil
	end
	if not review_terminal then
		review_terminal = terminal_module.Terminal:new(terminal_options(command))
	end
	review_command = command
	review_terminal.cmd = command
	review_terminal:open()
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
	open_terminal(root, cached_rounds[root], dependencies)
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

	vim.api.nvim_create_user_command("TuicrReview", function()
		local root, err = require("config.repo").current_root(0)
		if not root then
			notify(err, vim.log.levels.ERROR)
			return
		end
		M.open(root)
	end, { nargs = 0, desc = "Open the exact cached tuicr review round" })
end

M._decode_start = decode_start
M._terminal_options = terminal_options
M._launcher = LAUNCHER

return M
