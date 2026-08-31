local M = {}

local workbench = require("coverage_workbench")

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

function M.load(path)
	local project_root, root_err = root()
	if not project_root then
		notify(root_err, vim.log.levels.ERROR)
		return false
	end
	local snapshot, err = workbench.load({
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
	return workbench.clear(project_root)
end

function M.summary()
	local project_root, err = root()
	if not project_root then
		notify(err, vim.log.levels.ERROR)
		return nil
	end
	local summary = workbench.summary(project_root)
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
	workbench.setup()
	vim.api.nvim_create_user_command("CoverageLoad", function(opts)
		M.load(opts.args)
	end, { nargs = "?", complete = "file", desc = "Load an existing coverage.py JSON or LCOV report" })
	vim.api.nvim_create_user_command("CoverageSummary", M.summary, {
		nargs = 0,
		desc = "Show the loaded coverage summary",
	})
	vim.api.nvim_create_user_command("CoverageClear", M.clear, {
		nargs = 0,
		desc = "Clear loaded coverage data",
	})
end

M._workbench = workbench

return M
