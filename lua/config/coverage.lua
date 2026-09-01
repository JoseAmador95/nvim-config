local M = {}
local deferred = require("config.deferred")
local local_config = require("config.local_config")

local workbench
local configured = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Coverage" })
end

local function root()
	return require("config.repo").current_root(0)
end

local function default_report(project_root)
	local relative = vim.bo.filetype == "python" and "coverage.json" or "coverage/lcov.info"
	return vim.fs.joinpath(project_root, relative)
end

local function load_workbench()
	if workbench then
		return workbench
	end
	local ok, result = deferred.try("coverage_workbench")
	if not ok then
		return nil, result
	end
	workbench = result
	return workbench
end

local function ensure_workbench()
	if configured then
		return workbench
	end
	local core, load_err = load_workbench()
	if not core then
		return nil, load_err
	end
	local options = local_config.plugin("coverage_workbench", {
		max_report_bytes = 50 * 1024 * 1024,
		signs = "all",
		stale = "hide",
	})
	local ok, setup_ok, setup_err = pcall(core.setup, options)
	if not ok then
		return nil, setup_ok
	end
	if not setup_ok then
		return nil, setup_err
	end
	configured = true
	return core
end

function M.load(path)
	local project_root, root_err = root()
	if not project_root then
		notify(root_err, vim.log.levels.ERROR)
		return false
	end
	local core, setup_err = ensure_workbench()
	if not core then
		notify("Could not initialize coverage workbench: " .. tostring(setup_err), vim.log.levels.ERROR)
		return false
	end
	local snapshot, err = core.load({
		root = project_root,
		path = path and path ~= "" and path or default_report(project_root),
	})
	if not snapshot then
		notify("Could not load report: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	notify("Loaded existing coverage report: " .. snapshot.path)
	return true
end

function M.clear()
	local project_root, err = root()
	if not project_root then
		notify(err, vim.log.levels.ERROR)
		return false
	end
	local core, setup_err = ensure_workbench()
	if not core then
		notify("Could not initialize coverage workbench: " .. tostring(setup_err), vim.log.levels.ERROR)
		return false
	end
	return core.clear(project_root)
end

function M.summary()
	local project_root, err = root()
	if not project_root then
		notify(err, vim.log.levels.ERROR)
		return nil
	end
	local core, setup_err = ensure_workbench()
	if not core then
		notify("Could not initialize coverage workbench: " .. tostring(setup_err), vim.log.levels.ERROR)
		return nil
	end
	local summary = core.summary(project_root)
	if not summary then
		notify("No coverage report is loaded", vim.log.levels.WARN)
		return nil
	end
	notify(
		("Coverage: %.2f%% (%d covered, %d missing, %d excluded)"):format(
			summary.percent_covered,
			summary.covered_lines,
			summary.missing_lines,
			summary.excluded_lines
		)
	)
	return summary
end

function M.setup()
	vim.api.nvim_create_user_command("CoverageLoad", function(opts)
		M.load(opts.args)
	end, {
		nargs = "?",
		complete = "file",
		desc = "Load an existing coverage.py JSON or LCOV report",
		force = true,
	})
	vim.api.nvim_create_user_command("CoverageSummary", M.summary, {
		nargs = 0,
		desc = "Show the loaded coverage summary",
		force = true,
	})
	vim.api.nvim_create_user_command("CoverageClear", M.clear, {
		nargs = 0,
		desc = "Clear loaded coverage data",
		force = true,
	})
	return true
end

M._workbench = setmetatable({}, {
	__index = function(_, key)
		local core, err = load_workbench()
		if not core then
			error("could not load coverage workbench: " .. tostring(err), 2)
		end
		return core[key]
	end,
})

return M
