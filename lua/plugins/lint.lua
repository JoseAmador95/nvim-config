-- Lint saved file buffers in the terminal editor. Pager and VSCode sessions do
-- not own file writes or diagnostics, so they intentionally skip this plugin.
return {
	"mfussenegger/nvim-lint",
	event = "BufWritePost",
	cond = function()
		return not vim.g.vscode and not require("config.pager").active
	end,
	config = function()
		if vim.g.vscode or require("config.pager").active then
			return
		end

		local lint = require("lint")
		lint.linters_by_ft.dockerfile = { "hadolint" }
		lint.linters_by_ft.markdown = { "markdownlint-cli2" }
		lint.linters_by_ft.sh = { "shellcheck" }
		lint.linters_by_ft.bash = { "shellcheck" }

		local executables = {
			hadolint = "hadolint",
			["markdownlint-cli2"] = "markdownlint-cli2",
			shellcheck = "shellcheck",
		}
		local missing_notified = {}

		local function configured_linters(ft)
			local exact = lint.linters_by_ft[ft]
			if exact then
				return exact
			end

			local result = {}
			local seen = {}
			for _, component in ipairs(vim.split(ft, ".", { plain = true })) do
				for _, name in ipairs(lint.linters_by_ft[component] or {}) do
					if not seen[name] then
						seen[name] = true
						result[#result + 1] = name
					end
				end
			end
			return result
		end

		local function lint_buffer(buf)
			if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
				return
			end
			local name = vim.api.nvim_buf_get_name(buf)
			if vim.bo[buf].buftype ~= "" or name == "" or vim.fn.filereadable(name) ~= 1 then
				return
			end

			local names = configured_linters(vim.bo[buf].filetype)
			local available = {}
			for _, name in ipairs(names) do
				local executable = executables[name]
				if not executable or vim.fn.executable(executable) == 1 then
					available[#available + 1] = name
				elseif not missing_notified[executable] then
					missing_notified[executable] = true
					vim.notify_once(
						("Cannot run %s: executable `%s` was not found"):format(name, executable),
						vim.log.levels.WARN,
						{ title = "nvim-lint" }
					)
				end
			end

			if #available > 0 then
				vim.api.nvim_buf_call(buf, function()
					lint.try_lint(available)
				end)
			end
		end

		vim.api.nvim_create_autocmd("BufWritePost", {
			group = vim.api.nvim_create_augroup("NvimLint", { clear = true }),
			callback = function(args)
				lint_buffer(args.buf)
			end,
		})
	end,
}
