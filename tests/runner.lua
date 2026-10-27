local function run()
	-- This entry point is test-only; startup and plugin specifications never load it.
	local root = vim.env.NVIM_CONFIG_ROOT or vim.fn.getcwd()
	local dependency_root =
		assert(vim.env.NVIM_CONFIG_TEST_DEPS, "set NVIM_CONFIG_TEST_DEPS; run scripts/install-ci-tools first")
	local path = dependency_root .. "/mini.test"
	local pin = dofile(root .. "/lua/config/toolchain.lua").test_dependencies.mini_test
	local head = vim.system({ "git", "-C", path, "rev-parse", "HEAD" }, { text = true }):wait()
	assert(
		head.code == 0 and vim.trim(head.stdout) == pin.commit,
		"missing or mismatched mini.test; run scripts/install-ci-tools"
	)
	local status = vim.system({ "git", "-C", path, "status", "--porcelain" }, { text = true }):wait()
	assert(status.code == 0 and vim.trim(status.stdout) == "", "mini.test checkout has local changes")
	vim.opt.runtimepath:prepend(path)
	package.path = root .. "/?.lua;" .. package.path
	local MiniTest = require("mini.test")
	MiniTest.setup({ collect = { emulate_busted = false } })
	MiniTest.expect.reference_screenshot = require("tests.helpers").screenshot

	local suite = assert(vim.env.NVIM_CONFIG_TEST or arg[1], "test suite path is required")
	local cases = MiniTest.collect({
		find_files = function()
			return { suite }
		end,
	})
	assert(#cases > 0, "suite collected no test cases: " .. suite)
	local function execute()
		MiniTest.execute(cases)
	end

	if vim.env.NVIM_CONFIG_TEST_PROFILE == "1" then
		-- Collection installs startup observers before init.lua. The cases execute
		-- on the same scheduled VimEnter turn as the original profile suites.
		vim.api.nvim_create_autocmd("VimEnter", {
			once = true,
			callback = function()
				vim.schedule(execute)
			end,
		})
	else
		execute()
		-- -l has no main event loop. mini.test owns scheduling and the exit status.
		assert(
			vim.wait(tonumber(vim.env.NVIM_CONFIG_CHECK_TIMEOUT or "90") * 1000, function()
				return not MiniTest.is_executing()
			end, 10),
			"test suite timed out: " .. suite
		)
	end
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
	vim.api.nvim_err_writeln(err)
	vim.cmd("cquit 1")
end
