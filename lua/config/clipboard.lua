-- Bounded clipboard routing. Remote sessions use Neovim's OSC 52 encoder,
-- while local sessions retain the platform clipboard provider.
local M = {}

local DEFAULT_OSC52_MAX_BYTES = 1024 * 1024
local HARD_OSC52_MAX_BYTES = 16 * 1024 * 1024
local TITLE = "Clipboard"

local configured = false
local yank_group
local provider
local previous_provider
local policy = { osc52_max_bytes = DEFAULT_OSC52_MAX_BYTES }
local dependencies = {}

local function nonempty_env(name)
	local value = vim.env[name]
	return type(value) == "string" and value ~= ""
end

local function remote_session()
	return nonempty_env("SSH_TTY") or nonempty_env("SSH_CONNECTION")
end

local function attached_ui()
	return #vim.api.nvim_list_uis() > 0
end

local function notify(message, level)
	dependencies.notify(message, level or vim.log.levels.WARN, { title = TITLE })
end

local function validate_register(register)
	if register ~= "+" and register ~= "*" then
		return nil, "clipboard register must be + or *"
	end
	return register
end

local function payload_size(lines, maximum)
	if type(lines) ~= "table" or not vim.islist(lines) then
		return nil, "clipboard payload must be a list of strings"
	end
	local total = 0
	for index, line in ipairs(lines) do
		if type(line) ~= "string" then
			return nil, "clipboard payload must contain only strings"
		end
		local separator = index == 1 and 0 or 1
		if #line > maximum - total - separator then
			return nil, ("OSC 52 payload exceeds the configured %d-byte raw limit"):format(maximum)
		end
		total = total + separator + #line
	end
	return total
end

---Copy provider lines through OSC 52 after checking their pre-base64 size.
---@param register "+"|"*"
---@param lines string[]
---@return boolean? ok
---@return string? error_message
function M.copy_lines(register, lines)
	local valid, register_err = validate_register(register)
	if not valid then
		return nil, register_err
	end
	if not configured or not remote_session() then
		return nil, "OSC 52 clipboard is not active for this session"
	end
	local _, size_err = payload_size(lines, policy.osc52_max_bytes)
	if size_err then
		return nil, size_err
	end
	if not dependencies.has_ui() then
		return nil, "OSC 52 clipboard requires an attached UI"
	end
	local sender = dependencies.senders[register]
	local called, send_result = pcall(sender, lines)
	if not called then
		return nil, "OSC 52 copy failed: " .. tostring(send_result)
	end
	if send_result == false or (type(send_result) == "number" and send_result ~= 0) then
		return nil, "OSC 52 copy failed: sender rejected the payload"
	end
	return true
end

---Copy one exact string to the requested system clipboard.
---@param text string
---@param register? "+"|"*"
---@return boolean? ok
---@return string? error_message
function M.copy_text(text, register)
	if type(text) ~= "string" then
		return nil, "clipboard text must be a string"
	end
	if not configured then
		return nil, "clipboard adapter is not configured"
	end
	register = register or "+"
	local valid, register_err = validate_register(register)
	if not valid then
		return nil, register_err
	end
	if remote_session() then
		-- One string preserves the exact payload, including trailing newlines. The
		-- OSC 52 backend joins provider lines with newlines before encoding.
		return M.copy_lines(register, { text })
	end
	local called, result = pcall(dependencies.native_setreg, register, text)
	if not called or (type(result) == "number" and result ~= 0) then
		return nil, "native clipboard copy failed: " .. tostring(result)
	end
	return true
end

---setreg-compatible adapter for products that need a failure return value.
---@return integer status zero on success
function M.setreg(register, text)
	local ok = M.copy_text(text, register)
	return ok and 0 or 1
end

function M.available()
	if not configured then
		return false
	end
	if remote_session() then
		return dependencies.has_ui()
	end
	return vim.fn.has("clipboard") == 1
end

local function paste()
	return { vim.fn.getreg("", 1, true), vim.fn.getregtype("") }
end

local function copy_yank()
	local event = vim.v.event
	-- Explicit registers keep their native destination, including + and *.
	if event.operator ~= "y" or (event.regname ~= "" and event.regname ~= '"') then
		return
	end
	-- Preserve characterwise, linewise and blockwise types. Remote sessions
	-- reach the bounded OSC 52 provider through the same native register API.
	local ok, result = pcall(dependencies.native_setreg, "+", event.regcontents, event.regtype)
	if not ok or (type(result) == "number" and result ~= 0) then
		notify("Yank clipboard copy failed: " .. tostring(result), vim.log.levels.ERROR)
	end
end

function M.setup(opts, deps)
	opts = opts or {}
	deps = deps or {}
	for key in pairs(opts) do
		if key ~= "osc52_max_bytes" then
			error("clipboard setup contains an unknown option: " .. tostring(key))
		end
	end
	local maximum = opts.osc52_max_bytes or DEFAULT_OSC52_MAX_BYTES
	if type(maximum) ~= "number" or maximum % 1 ~= 0 or maximum < 1 or maximum > HARD_OSC52_MAX_BYTES then
		error(("clipboard osc52_max_bytes must be an integer between 1 and %d"):format(HARD_OSC52_MAX_BYTES))
	end
	for _, name in ipairs({ "has_ui", "native_setreg", "notify" }) do
		if deps[name] ~= nil and type(deps[name]) ~= "function" then
			error("clipboard dependency " .. name .. " must be a function")
		end
	end
	if deps.senders ~= nil then
		if type(deps.senders) ~= "table" then
			error("clipboard dependency senders must be a table")
		end
		for _, register in ipairs({ "+", "*" }) do
			if type(deps.senders[register]) ~= "function" then
				error("clipboard dependency sender " .. register .. " must be a function")
			end
		end
	end

	M.teardown()
	local osc52 = require("vim.ui.clipboard.osc52")
	policy = { osc52_max_bytes = maximum }
	dependencies = {
		has_ui = deps.has_ui or attached_ui,
		native_setreg = deps.native_setreg or vim.fn.setreg,
		notify = deps.notify or vim.notify,
		senders = deps.senders or { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
	}
	configured = true
	if remote_session() then
		previous_provider = vim.g.clipboard
		provider = {
			name = "OSC52 (bounded)",
			copy = {
				["+"] = function(lines)
					local ok, err = M.copy_lines("+", lines)
					if not ok then
						notify(err, vim.log.levels.ERROR)
					end
				end,
				["*"] = function(lines)
					local ok, err = M.copy_lines("*", lines)
					if not ok then
						notify(err, vim.log.levels.ERROR)
					end
				end,
			},
			paste = { ["+"] = paste, ["*"] = paste },
		}
		vim.g.clipboard = provider
	end
	yank_group = vim.api.nvim_create_augroup("config_clipboard_yank", { clear = true })
	vim.api.nvim_create_autocmd("TextYankPost", {
		group = yank_group,
		callback = copy_yank,
		desc = "Copy default yanks to the system clipboard without exporting edits",
	})
	return M
end

function M.status()
	return vim.deepcopy({
		configured = configured,
		remote = remote_session(),
		available = M.available(),
		osc52_max_bytes = policy.osc52_max_bytes,
	})
end

function M.teardown()
	if yank_group ~= nil then
		vim.api.nvim_del_augroup_by_id(yank_group)
		yank_group = nil
	end
	if provider ~= nil then
		vim.g.clipboard = previous_provider
	end
	configured = false
	provider = nil
	previous_provider = nil
	policy = { osc52_max_bytes = DEFAULT_OSC52_MAX_BYTES }
	dependencies = {}
	return true
end

return M
