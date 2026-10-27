local MiniTest = require("mini.test")
local reference_screenshot = MiniTest.expect.reference_screenshot
local M = {}

function M.equal(expected, actual, message)
	return MiniTest.expect.equality(expected, actual, { fail_reason = message })
end

-- mini.test creates missing references by default. Require an explicit local
-- update so a deleted or misspelled baseline can never silently pass CI.
function M.screenshot(screenshot, path, opts)
	assert(screenshot ~= nil, "screenshot capture returned nil")
	assert(type(path) == "string" and path ~= "", "screenshot reference path is required")
	local update = vim.env.NVIM_CONFIG_UPDATE_SCREENSHOTS == "1"
	assert(not update or not vim.env.CI, "screenshot updates are forbidden in CI")
	assert(update or vim.fn.filereadable(path) == 1, "missing screenshot reference: " .. path)
	opts = vim.tbl_extend("force", opts or {}, { force = update })
	return reference_screenshot(screenshot, path, opts)
end

return M
