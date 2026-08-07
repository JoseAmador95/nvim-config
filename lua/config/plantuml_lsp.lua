local M = {}

function M.available()
	return vim.fn.executable("plantuml-lsp") == 1
end

function M.root_dir(bufnr, on_dir)
	local filename = vim.api.nvim_buf_get_name(bufnr)
	if filename == "" then
		on_dir(nil)
		return
	end
	local marker = vim.fs.find({ ".git" }, { path = filename, upward = true })[1]
	on_dir(marker and vim.fs.dirname(marker) or vim.fs.dirname(filename))
end

function M.config(capabilities)
	return {
		capabilities = capabilities,
		cmd = { "plantuml-lsp", "--exec-path=plantuml" },
		filetypes = { "plantuml" },
		root_dir = M.root_dir,
	}
end

function M.setup_install_command()
	vim.api.nvim_create_user_command("PlantumlLspInstall", function()
		require("config.tool_installer").install("plantuml-lsp", function(ok)
			if not ok then
				return
			end
			if not M.available() then
				vim.notify(
					"plantuml-lsp installed, but is not in PATH; add your Go bin directory and restart Neovim",
					vim.log.levels.WARN,
					{ title = "LSP" }
				)
				return
			end
			vim.lsp.enable("plantuml_lsp")
		end)
	end, { desc = "Install the pinned PlantUML LSP with Go" })
end

return M
