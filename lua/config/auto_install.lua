-- First-run provisioning for interactive sessions. Plugins are handled before
-- they load (config.lazy installs missing ones and moves drifted checkouts to
-- the lockfile); this fills in the rest:
--   * Mise (full editor only), which installs every locked tool on first use;
--   * missing or stale configured Tree-sitter parsers.
-- Everything runs in the background after the UI is up. NVIM_CONFIG_OFFLINE=1,
-- headless sessions and VSCode never download anything. Failures are retried
-- after RETRY_SECONDS and reported by :checkhealth nvimconfig.
local deferred = require("config.deferred")

local M = {}

local RETRY_SECONDS = 24 * 60 * 60
local TITLE = "nvim.config"

local state = {
	profile = nil,
	ran = false,
	steps = {},
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = TITLE })
end

local function state_path()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "auto-install.json")
end

local function read_failures()
	local ok, lines = pcall(vim.fn.readfile, state_path())
	if not ok or type(lines) ~= "table" or #lines == 0 then
		return {}
	end
	local decoded, value = pcall(vim.json.decode, table.concat(lines, "\n"))
	return decoded and type(value) == "table" and value or {}
end

local function write_failures(failures)
	local path = state_path()
	vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
	if next(failures) == nil then
		pcall(vim.fn.delete, path)
		return
	end
	pcall(vim.fn.writefile, { vim.json.encode(failures) }, path)
end

local function record(step, ok, detail)
	state.steps[step] = { ok = ok, detail = detail and tostring(detail) or nil, at = os.time() }
	local failures = read_failures()
	if ok then
		failures[step] = nil
	else
		failures[step] = { at = os.time(), detail = detail and tostring(detail) or "failed" }
	end
	write_failures(failures)
end

local function recently_failed(step)
	local failure = read_failures()[step]
	return type(failure) == "table" and type(failure.at) == "number" and os.time() - failure.at < RETRY_SECONDS
end

local function enabled()
	if vim.env.NVIM_CONFIG_OFFLINE == "1" then
		return false, "NVIM_CONFIG_OFFLINE=1"
	end
	if vim.g.vscode then
		return false, "VSCode profile"
	end
	if #vim.api.nvim_list_uis() == 0 then
		return false, "headless session"
	end
	return true
end

local function stale_parsers(treesitter)
	local inventory = treesitter.inventory()
	local names, force = {}, false
	for _, item in ipairs(inventory.required) do
		-- Unpinned parsers have no revision to compare against; leave them alone.
		if not item.exact and item.expected ~= vim.NIL then
			names[#names + 1] = item.name
			force = force or item.actual ~= vim.NIL
		end
	end
	return names, force
end

local function install_parsers()
	local treesitter = package.loaded["config.treesitter_runtime"]
	if type(treesitter) ~= "table" or type(treesitter.inventory) ~= "function" then
		return
	end
	local names, force = stale_parsers(treesitter)
	if #names == 0 then
		state.steps.parsers = { ok = true, at = os.time() }
		return
	end
	if recently_failed("parsers") then
		return
	end
	local started, err = treesitter.install(names, {
		summary = false,
		force = force,
		on_done = function(ok, detail)
			record("parsers", ok, detail)
			if ok then
				notify("Installed Tree-sitter parsers: " .. table.concat(names, ", "))
			else
				notify(
					"Tree-sitter parser install failed: " .. tostring(detail) .. "\nSee :checkhealth nvimconfig",
					vim.log.levels.WARN
				)
			end
		end,
	})
	if started then
		notify("Installing Tree-sitter parsers in the background: " .. table.concat(names, ", "))
	else
		record("parsers", false, err)
		notify(
			"Tree-sitter parsers are missing and could not be installed: "
				.. tostring(err)
				.. "\nSee :checkhealth nvimconfig",
			vim.log.levels.WARN
		)
	end
end

local function install_mise(continue)
	if vim.fn.executable("mise") == 1 then
		return continue()
	end
	if recently_failed("mise") then
		return continue()
	end
	notify("Installing Mise in the background; editor tools install on first use once it is ready")
	local called, started = pcall(deferred.load("config.tool_bootstrap").install_mise, function(ok, detail)
		record("mise", ok, detail)
		if ok then
			notify("Mise is installed. Language servers start for files opened from now on.")
		else
			notify("Mise install failed: " .. tostring(detail) .. "\nSee :checkhealth nvimconfig", vim.log.levels.WARN)
		end
		continue()
	end)
	if not called or not started then
		record("mise", false, called and "installer could not start" or started)
		notify("Mise install could not start: " .. tostring(started), vim.log.levels.WARN)
		continue()
	end
end

---Run the background provisioning once for this session.
function M.run()
	if state.ran then
		return false
	end
	local ok, reason = enabled()
	if not ok then
		state.skipped = reason
		return false
	end
	state.ran = true
	if state.profile == "full" then
		install_mise(install_parsers)
	else
		install_parsers()
	end
	return true
end

---@param opts { profile: "full"|"pager" }
function M.setup(opts)
	state.profile = opts and opts.profile or "full"
	vim.api.nvim_create_autocmd("UIEnter", {
		group = vim.api.nvim_create_augroup("nvim_config_auto_install", { clear = true }),
		once = true,
		callback = function()
			vim.defer_fn(M.run, 200)
		end,
	})
end

---Copied state for :checkhealth nvimconfig. Never starts work.
function M.status()
	local status = vim.deepcopy(state)
	status.failures = read_failures()
	status.retry_seconds = RETRY_SECONDS
	return status
end

return M
