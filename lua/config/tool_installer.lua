local M = {}

local manifest = require("config.toolchain")
local running = {}
local setup_done = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Tools" })
end

local function copy_command(command)
	local out = {}
	for index, value in ipairs(command) do
		out[index] = value
	end
	return out
end

local function targets_for(target)
	if target == "all" then
		local targets = {}
		for _, name in ipairs(manifest.order) do
			targets[#targets + 1] = name
		end
		return targets
	end
	if manifest.tools[target] then
		return { target }
	end
	return nil
end

local function result_message(result)
	local output = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
	return output ~= "" and output or "installer exited with code " .. tostring(result.code)
end

---@param name string
---@param on_complete? fun(ok: boolean, result: table)
function M.install_one(name, on_complete)
	local tool = manifest.tools[name]
	if not tool then
		error("unknown tool: " .. tostring(name))
	end
	if running[name] then
		notify(name .. " installation is already running", vim.log.levels.WARN)
		if on_complete then
			on_complete(false, { code = -1, stderr = "installation already running" })
		end
		return false
	end

	if vim.fn.executable(tool.installer) ~= 1 then
		notify(
			string.format("%s not found in PATH; it is required to install %s", tool.installer, name),
			vim.log.levels.ERROR
		)
		if on_complete then
			on_complete(false, { code = -1, stderr = tool.installer .. " not found" })
		end
		return false
	end

	local command = copy_command(tool.command)
	local expected_command = table.concat(tool.command, " ")
	running[name] = true
	notify(string.format("Installing %s %s asynchronously (%s)", name, tool.version, expected_command))
	vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(result)
			running[name] = nil
			local ok = result.code == 0
			if ok then
				notify(string.format("Installed %s %s", name, tool.version))
			else
				notify(string.format("Failed to install %s: %s", name, result_message(result)), vim.log.levels.ERROR)
			end
			if on_complete then
				on_complete(ok, result)
			end
		end)
	)
	return true
end

---@param target? string
---@param on_complete? fun(ok: boolean)
function M.install(target, on_complete)
	if target == nil or target == "" then
		target = "all"
	end
	local targets = targets_for(target)
	if not targets then
		notify("Unknown tool '" .. target .. "'. Choose all, mmdflux, or plantuml-lsp.", vim.log.levels.ERROR)
		return false
	end

	local pending = #targets
	local all_ok = true
	for _, name in ipairs(targets) do
		M.install_one(name, function(ok)
			all_ok = all_ok and ok
			pending = pending - 1
			if pending == 0 and on_complete then
				on_complete(all_ok)
			end
		end)
	end
	return true
end

function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	vim.api.nvim_create_user_command("NvimConfigToolsInstall", function(opts)
		M.install(opts.args)
	end, {
		nargs = "?",
		complete = function()
			return { "all", "mmdflux", "plantuml-lsp" }
		end,
		desc = "Install pinned non-Mason Neovim tools",
	})
end

return M
