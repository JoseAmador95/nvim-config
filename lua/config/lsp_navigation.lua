local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

local function is_list(value)
	return vim.islist(value)
end

local function has_client(method, title)
	local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
	if clients and #clients > 0 then
		return clients
	end
	notify((title or "LSP") .. ": no active client for method")
	return nil
end

function M.byte_column(bufnr, position, encoding)
	local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1]
	if line == nil then
		return nil, "target line is outside the buffer"
	end
	local ok, byte = pcall(vim.str_byteindex, line, encoding or "utf-16", position.character, false)
	if not ok then
		return nil, byte
	end
	return byte
end

local function snacks_lsp_picker(method, title, picker_fn)
	return function()
		if not has_client(method, title) then
			return
		end
		local ok = pcall(require, "snacks")
		if ok then
			picker_fn()
		else
			notify("Snacks picker not available", vim.log.levels.WARN)
		end
	end
end

local function safe_lsp_jump(method, title)
	return function()
		local clients = has_client(method, title)
		if not clients then
			return
		end

		local client = clients[1]
		local request_encoding = client.offset_encoding or "utf-16"
		local params = vim.lsp.util.make_position_params(0, request_encoding)
		client:request(method, params, function(err, result, ctx)
			if err then
				notify((title or "LSP") .. ": " .. (err.message or "request failed"), vim.log.levels.ERROR)
				return
			end
			if not result or (is_list(result) and vim.tbl_isempty(result)) then
				notify((title or "LSP") .. ": no location found")
				return
			end

			local response_client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id) or client
			local location = is_list(result) and result[1] or result
			local uri = location.uri or location.targetUri
			if not uri then
				notify((title or "LSP") .. ": invalid location from server", vim.log.levels.WARN)
				return
			end

			local range = location.range or location.targetSelectionRange or location.selectionRange
			local start_position = range and range.start or { line = 0, character = 0 }
			local target_buf = vim.uri_to_bufnr(uri)
			local loaded, load_error = pcall(vim.fn.bufload, target_buf)
			local column = 0
			if loaded then
				local byte, conversion_error =
					M.byte_column(target_buf, start_position, response_client.offset_encoding or request_encoding)
				if byte then
					column = byte
				else
					notify(
						(title or "LSP") .. ": could not convert target column: " .. conversion_error,
						vim.log.levels.WARN
					)
				end
			else
				notify((title or "LSP") .. ": could not load target buffer: " .. load_error, vim.log.levels.WARN)
			end

			require("config.editor").open_file_in_tab(vim.uri_to_fname(uri), {
				lnum = start_position.line + 1,
				col = column + 1,
			})
		end)
	end
end

function M.setup()
	local hover_opts = { border = "rounded" }
	vim.api.nvim_create_autocmd("LspAttach", {
		group = vim.api.nvim_create_augroup("LspKeymaps", { clear = true }),
		callback = function(event)
			vim.keymap.set(
				"n",
				"gd",
				safe_lsp_jump("textDocument/definition", "Go to definition"),
				{ buffer = event.buf, silent = true, desc = "Go to definition" }
			)
			vim.keymap.set(
				"n",
				"gD",
				safe_lsp_jump("textDocument/declaration", "Go to declaration"),
				{ buffer = event.buf, silent = true, desc = "Go to declaration" }
			)
			vim.keymap.set(
				"n",
				"gi",
				snacks_lsp_picker("textDocument/implementation", "Go to implementation", function()
					Snacks.picker.lsp_implementations({ confirm = "open_in_tab" })
				end),
				{ buffer = event.buf, silent = true, desc = "Go to implementation" }
			)
			vim.keymap.set(
				"n",
				"gr",
				snacks_lsp_picker("textDocument/references", "References", function()
					Snacks.picker.lsp_references({ confirm = "open_in_tab" })
				end),
				{ buffer = event.buf, silent = true, desc = "References" }
			)
			vim.keymap.set("n", "<leader>.", function()
				vim.lsp.buf.hover(hover_opts)
			end, { buffer = event.buf, silent = true, desc = "Hover symbol documentation" })
			vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, {
				buffer = event.buf,
				silent = true,
				desc = "Signature help",
			})
			vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, {
				buffer = event.buf,
				silent = true,
				desc = "Rename",
			})
			vim.keymap.set({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, {
				buffer = event.buf,
				silent = true,
				desc = "Code action",
			})
		end,
	})
end

return M
