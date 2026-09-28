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
			vim.fn.writefile({
				vim.json.encode({
					meta = { format = 3, version = "fixture" },
					files = {
						["src/probe.py"] = {
							executed_lines = { 1 },
							missing_lines = { 2 },
							excluded_lines = {},
						},
					},
					totals = {},
				}),
			}, json_report)
			vim.fn.writefile({ "TN:", "SF:src/probe.py", "DA:1,1", "DA:2,0", "end_of_record" }, lcov_report)

			vim.cmd.edit(vim.fn.fnameescape(source))
			vim.bo.filetype = "python"
			assert(vim.fn.exists(":CoverageLoad") == 2, "host did not register CoverageLoad")
			assert(vim.fn.exists(":CoverageSummary") == 2, "host did not register CoverageSummary")
			assert(vim.fn.exists(":CoverageClear") == 2, "host did not register CoverageClear")
			assert(package.loaded.coverage == nil, "retired nvim-coverage module was loaded")
			assert(package.loaded.coverage_workbench == nil, "coverage command registration initialized its core")

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
				local coverage = require("config.coverage")
				assert(coverage.load(json_report), "Coverage.py JSON report was not loaded")
				assert(
					vim.deep_equal(coverage._workbench.effective_config(), {
						max_report_bytes = 50 * 1024 * 1024,
						max_source_bytes = 16 * 1024 * 1024,
						max_model_bytes = 64 * 1024 * 1024,
						signs = "all",
						stale = "hide",
					}),
					"host coverage limits did not reach the core"
				)
				local snapshot = coverage._workbench.snapshot(fixture)
				assert(snapshot and snapshot.model.files[source], "JSON paths were not canonicalized")
				assert(snapshot.model.kind == "coverage.py-json")
				assert(coverage.load(lcov_report), "LCOV report was not loaded")
				assert(coverage._workbench.snapshot(fixture).model.kind == "lcov")
				assert(#forbidden == 0, "coverage import executed a generator")
				local summary = coverage.summary()
				assert(summary and summary.percent_covered == 50)
				assert(coverage.clear())
				assert(coverage._workbench.snapshot(fixture) == nil)
			end, debug.traceback)

			vim.system = original_system
			vim.fn.jobstart = original_jobstart
			vim.fn.delete(fixture, "rf")
			assert(ok, err)
			print("coverage_spec: host imports Coverage.py JSON and LCOV without generators")
			vim.cmd("quitall!")
		end)
	end,
})
