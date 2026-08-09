vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local fixture = vim.fn.tempname()
			vim.fn.mkdir(fixture .. "/src", "p")
			vim.fn.system({ "git", "init", "-q", fixture })
			assert(vim.v.shell_error == 0, "could not initialize coverage fixture")
			fixture = vim.uv.fs_realpath(fixture) or fixture
			local source = fixture .. "/src/probe.py"
			local json_report = fixture .. "/coverage.json"
			local lcov_report = fixture .. "/coverage/lcov.info"
			vim.fn.mkdir(fixture .. "/coverage", "p")
			vim.fn.writefile({ "value = 1", "print(value)" }, source)
			local summary = {
				covered_lines = 1,
				missing_lines = 1,
				excluded_lines = 0,
				num_branches = 0,
				num_partial_branches = 0,
				num_statements = 2,
				percent_covered = 50,
			}
			vim.fn.writefile({
				vim.json.encode({
					meta = { version = "test" },
					files = {
						["src/probe.py"] = {
							executed_lines = { 1 },
							missing_lines = { 2 },
							excluded_lines = {},
							summary = summary,
						},
					},
					totals = summary,
				}),
			}, json_report)
			vim.fn.writefile({ "TN:", "SF:src/probe.py", "DA:1,1", "DA:2,0", "end_of_record" }, lcov_report)

			vim.cmd.edit(vim.fn.fnameescape(source))
			vim.bo.filetype = "python"
			require("lazy").load({ plugins = { "nvim-coverage" } })
			local coverage = require("config.coverage")

			local original_system = vim.system
			local original_jobstart = vim.fn.jobstart
			local forbidden = {}
			vim.system = function(command, options, callback)
				local argv = type(command) == "table" and command or { command }
				if tostring(argv[1]):match("python") or argv[1] == "coverage" or argv[1] == "pytest" then
					forbidden[#forbidden + 1] = vim.deepcopy(argv)
				end
				return original_system(command, options, callback)
			end
			vim.fn.jobstart = function(command, options)
				local text = type(command) == "table" and table.concat(command, " ") or tostring(command)
				if text:match("coverage") or text:match("pytest") or text:match("python") then
					forbidden[#forbidden + 1] = text
				end
				return original_jobstart(command, options)
			end

			local ok, err = xpcall(function()
				assert(coverage.load(json_report), "Python JSON report was not loaded")
				local cached = require("coverage.report").get()
				assert(cached and cached.files[source], "Python paths were not sanitized to contained absolute paths")
				assert(require("coverage.report").language() == "python")
				assert(coverage.load(lcov_report), "LCOV report was not loaded")
				assert(require("coverage.report").language() == "common")
				assert(require("coverage.report").get().files[source], "relative LCOV source was not canonicalized")
				assert(#forbidden == 0, "coverage import executed a report/test command")

				local outside = vim.fn.tempname()
				vim.fn.writefile({ "value = 2" }, outside)
				local rejected = coverage._sanitize_python(fixture, {
					files = { [outside] = { executed_lines = {}, missing_lines = {}, excluded_lines = {} } },
					totals = {},
				})
				assert(rejected == nil, "outside JSON source was accepted")
				vim.fn.writefile({ "SF:" .. outside, "DA:1,1", "end_of_record" }, lcov_report)
				assert(coverage._validate_lcov(fixture, lcov_report) == nil, "outside LCOV source was accepted")
				vim.fn.delete(outside)
				coverage.clear()
				assert(require("coverage.report").get() == nil, "CoverageClear retained the report")
			end, debug.traceback)

			vim.system = original_system
			vim.fn.jobstart = original_jobstart
			vim.fn.delete(fixture, "rf")
			assert(ok, err)
			print("coverage_spec: read-only Python JSON and LCOV imports passed")
			vim.cmd("quitall!")
		end)
	end,
})
