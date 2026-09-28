local owned_augments = setmetatable({}, { __mode = "k" })

local function workspace_options(tree)
	local data = type(tree) == "table" and type(tree.data) == "function" and tree:data() or nil
	local path = type(data) == "table" and (data.path or data.id) or nil
	if type(path) == "string" and path ~= "" and not path:find("::", 1, true) then
		return { root = path }
	end
	return { buf = 0 }
end

local function default_strategy(tree, neotest_config)
	local ok, root = pcall(function()
		return tree:root():data().path
	end)
	local project = ok and type(root) == "string" and neotest_config.projects and neotest_config.projects[root] or nil
	return type(project) == "table" and project.default_strategy or neotest_config.default_strategy
end

local function guarded_augment(workflow, previous, neotest_config)
	if owned_augments[previous] then
		return previous
	end
	local augment = function(tree, args)
		local copied = vim.deepcopy(args or {})
		local options = workspace_options(tree)
		local granted, grant_err = workflow.grant("test", options)
		if not granted then
			workflow.notify("Neotest", "Test run denied: " .. tostring(grant_err), vim.log.levels.ERROR)
			error("Neotest test execution denied", 0)
		end
		if previous then
			copied = previous(tree, copied)
			if type(copied) ~= "table" then
				error("Neotest run augmentation must return a table", 0)
			end
		end
		if (copied.strategy or default_strategy(tree, neotest_config)) == "dap" then
			local debug_granted, debug_err = workflow.grant("debug", options)
			if not debug_granted then
				workflow.notify("Neotest", "Debug test run denied: " .. tostring(debug_err), vim.log.levels.ERROR)
				error("Neotest debug execution denied", 0)
			end
		end
		return copied
	end
	owned_augments[augment] = true
	return augment
end

return {
	"nvim-neotest/neotest",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "Neotest" },
	keys = {
		{
			"<leader>Tn",
			function()
				require("neotest").run.run()
			end,
			desc = "Run nearest test",
		},
		{
			"<leader>Td",
			function()
				require("neotest").run.run({ strategy = "dap" })
			end,
			desc = "Debug nearest test",
		},
	},
	dependencies = {
		"linux-cultist/venv-selector.nvim",
		"nvim-neotest/neotest-python",
		"alfaix/neotest-gtest",
		"nvim-lua/plenary.nvim",
	},
	config = function()
		local python = require("config.python")
		local workflow = require("config.workflow_execution")
		local adapters = {
			require("neotest-python")({
				python = python.neotest_python,
				runner = python.neotest_runner,
			}),
		}
		local ok_gtest, gtest = pcall(require, "neotest-gtest")
		if ok_gtest then
			adapters[#adapters + 1] = gtest.setup({})
		else
			vim.notify("neotest-gtest disabled: " .. tostring(gtest), vim.log.levels.WARN)
		end

		local neotest_config = require("neotest.config")
		require("neotest").setup({
			adapters = adapters,
			run = {
				augment = guarded_augment(workflow, neotest_config.run and neotest_config.run.augment, neotest_config),
			},
		})
	end,
}
