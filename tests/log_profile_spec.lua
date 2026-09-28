vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("log_profile_spec: " .. message)
	vim.cmd("cquit")
end

local log_path = vim.fn.tempname() .. ".log"
local text_path = vim.fn.tempname() .. ".txt"
local generated_syntax = vim.fs.joinpath(vim.fn.stdpath("data"), "log-highlight", "after", "syntax", "log.vim")
local generated_before = vim.uv.fs_lstat(generated_syntax)
assert(vim.fn.writefile({ "INFO boot", "custom-marker" }, log_path) == 0)
assert(vim.fn.writefile({ "INFO prose", "custom-marker" }, text_path) == 0)

local function cleanup()
	vim.fn.delete(log_path)
	vim.fn.delete(text_path)
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				local spec = require("plugins.log-highlight")
				assert(type(spec.init) == "function", "*.log extension detection is missing")
				assert(spec.opts == nil and spec.config == nil, "syntax backend still generates runtime config state")

				vim.cmd.edit(vim.fn.fnameescape(log_path))
				assert(vim.bo.filetype == "log", "*.log was not detected as the log filetype")
				assert(vim.b.current_syntax == "log", "external log syntax backend did not load for *.log")
				assert(package.loaded["log-highlight"] == nil, "upstream state-generating setup module was loaded")
				assert(
					vim.deep_equal(generated_before, vim.uv.fs_lstat(generated_syntax)),
					"log-highlight generated or rewrote mutable syntax state"
				)
				for _, command in ipairs({ "LogHlAdd", "LogHlRegex", "LogHlClear", "LogWatchCurrentFile" }) do
					assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
				end
				vim.cmd("LogHlAdd red custom-marker")
				local state = vim.b.log_pattern_state
				assert(state and #state.patterns == 1, "custom log pattern did not coexist with log-highlight")

				vim.cmd.edit(vim.fn.fnameescape(text_path))
				assert(vim.bo.filetype ~= "log", "*.txt was automatically classified as a log")
				local original_filetype = vim.bo.filetype
				vim.cmd("ToggleLogHighlight")
				assert(vim.bo.filetype == "log", "explicit log highlighting did not enable the log filetype")
				vim.cmd("ToggleLogHighlight")
				assert(vim.bo.filetype == original_filetype, "explicit log highlighting did not restore the filetype")
			end, debug.traceback)

			cleanup()
			if not ok then
				fail(err)
				return
			end
			print("log_profile_spec: *.log, *.txt, custom patterns, and explicit toggling passed")
			vim.cmd("quitall!")
		end)
	end,
})
