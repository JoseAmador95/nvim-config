local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

function M.set_compile_commands(argument)
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		notify(root_err, vim.log.levels.ERROR)
		return false
	end
	local ok, err = require("config.clangd").set_manual(root, argument)
	if not ok then
		notify("clangd compile database rejected: " .. err, vim.log.levels.ERROR)
		return false
	end
	notify("clangd manual compile database: " .. require("config.clangd").status(root).directory)
	return true
end

function M.switch_source_header()
	local clients = vim.lsp.get_clients({ name = "clangd", bufnr = 0 })
	if #clients == 0 then
		notify("No clangd client is attached to this buffer", vim.log.levels.WARN)
		return
	end
	local params = vim.lsp.util.make_text_document_params(0)
	clients[1]:request("textDocument/switchSourceHeader", params, function(err, result)
		vim.schedule(function()
			if err then
				notify("Could not switch source/header: " .. tostring(err.message or err), vim.log.levels.ERROR)
				return
			end
			if type(result) ~= "string" or result == "" then
				notify("clangd found no corresponding source/header", vim.log.levels.WARN)
				return
			end
			local path = result:match("^%a[%w+.-]*://") and vim.uri_to_fname(result) or result
			require("config.editor").open_file_in_tab(path)
		end)
	end, 0)
end

function M.setup()
	vim.api.nvim_create_user_command("ClangdSetCompileCommands", function(opts)
		M.set_compile_commands(opts.args)
	end, {
		nargs = 1,
		complete = "dir",
		desc = "Point clangd at a validated compile_commands.json directory for this root",
	})
	vim.api.nvim_create_user_command("ClangdSwitchSourceHeader", M.switch_source_header, {
		nargs = 0,
		desc = "Open clangd's corresponding source or header in a tab",
	})
end

M.setup()

return M
