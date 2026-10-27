local root = vim.fn.getcwd()
local T = MiniTest.new_set()

T["process result"] = MiniTest.new_set({
	parametrize = {
		{ "local T = MiniTest.new_set(); T.pass = function() end; return T", 0, "Fails (0)" },
		{ 'local T = MiniTest.new_set(); T.fail = function() error("case failure") end; return T', 1, "case failure" },
		{
			'local T = MiniTest.new_set({ hooks = { post_once = function() error("cleanup failure") end } }); T.pass = function() end; return T',
			1,
			"cleanup failure",
		},
		{ "return MiniTest.new_set()", 1, "suite collected no test cases" },
		{ 'error("collection failure")', 1, "collection failure" },
	},
})
T["process result"]["reports failure and exits"] = function(source, code, message)
	local path = vim.fn.tempname() .. ".lua"
	MiniTest.finally(function()
		vim.fn.delete(path)
	end)
	assert(vim.fn.writefile({ source }, path) == 0)
	local result = vim.system(
		{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", root .. "/tests/runner.lua", path },
		{
			text = true,
			env = { NVIM_CONFIG_TEST = path, NVIM_CONFIG_TEST_PROFILE = "" },
		}
	):wait(5000)
	assert(result.code == code, vim.inspect(result))
	assert((result.stdout .. result.stderr):find(message, 1, true), vim.inspect(result))
end

T["screenshot policy"] = MiniTest.new_set({
	parametrize = {
		{ "", "", false, "missing screenshot reference" },
		{ "", "true", false, "missing screenshot reference" },
		{ "1", "true", false, "screenshot updates are forbidden in CI" },
		{ "", "", true, "screenshot capture returned nil" },
	},
})
T["screenshot policy"]["rejects unreviewed references"] = function(update, ci, missing_capture, message)
	local previous_update, previous_ci = vim.env.NVIM_CONFIG_UPDATE_SCREENSHOTS, vim.env.CI
	MiniTest.finally(function()
		vim.env.NVIM_CONFIG_UPDATE_SCREENSHOTS, vim.env.CI = previous_update, previous_ci
	end)
	vim.env.NVIM_CONFIG_UPDATE_SCREENSHOTS = update
	vim.env.CI = ci ~= "" and ci or nil
	local path = vim.fn.tempname() .. ".screenshot"
	local screenshot = not missing_capture and {} or nil
	local ok, err = pcall(MiniTest.expect.reference_screenshot, screenshot, path)
	assert(not ok and tostring(err):find(message, 1, true), tostring(err))
	assert(vim.fn.filereadable(path) == 0, "rejected expectation created a baseline")
end

return T
