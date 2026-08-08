local M = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

local function has_client(method, title)
	local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
	if clients and #clients > 0 then
		return clients
	end
	notify((title or "LSP") .. ": no active client for method")
	return nil
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

local function open_location_list(action, options)
	local items = options.items or {}
	if #items == 1 then
		local item = items[1]
		local path = item.filename
		if (not path or path == "") and item.bufnr then
			path = vim.api.nvim_buf_get_name(item.bufnr)
		end
		if not path or path == "" then
			notify(action.title .. ": invalid location from server", vim.log.levels.WARN)
			return
		end
		require("config.editor").open_file_in_tab(path, {
			lnum = item.lnum or 1,
			col = item.col or 1,
		})
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker or type(snacks.picker.pick) ~= "function" then
		notify("Snacks picker not available", vim.log.levels.WARN)
		return
	end
	local picker_items = {}
	for _, item in ipairs(items) do
		local path = item.filename
		if (not path or path == "") and item.bufnr then
			path = vim.api.nvim_buf_get_name(item.bufnr)
		end
		if path and path ~= "" then
			picker_items[#picker_items + 1] = {
				file = path,
				pos = { item.lnum or 1, math.max((item.col or 1) - 1, 0) },
				text = item.text or path,
			}
		end
	end
	if #picker_items == 0 then
		notify(action.title .. ": invalid locations from server", vim.log.levels.WARN)
		return
	end
	snacks.picker.pick({
		items = picker_items,
		format = "file",
		confirm = "open_in_tab",
		title = action.title,
	})
end

local location_actions = {
	declaration = {
		method = "textDocument/declaration",
		title = "Go to declaration",
		request = function(opts)
			vim.lsp.buf.declaration(opts)
		end,
	},
	definition = {
		method = "textDocument/definition",
		title = "Go to definition",
		request = function(opts)
			vim.lsp.buf.definition(opts)
		end,
	},
}

local function goto_location(name)
	local action = assert(location_actions[name], "unknown LSP location action: " .. tostring(name))
	if not has_client(action.method, action.title) then
		return false
	end
	action.request({
		on_list = function(options)
			open_location_list(action, options)
		end,
	})
	return true
end

function M.declaration()
	return goto_location("declaration")
end

function M.definition()
	return goto_location("definition")
end

local function delete_default_keymaps(bufnr)
	local options = bufnr and { buffer = bufnr } or nil
	for _, lhs in ipairs({ "K", "gO", "gri", "grn", "grr", "grt", "grx" }) do
		pcall(vim.keymap.del, "n", lhs, options)
	end
	for _, mode in ipairs({ "n", "x" }) do
		pcall(vim.keymap.del, mode, "gra", options)
	end
end

function M.setup()
	delete_default_keymaps()
	local hover_opts = { border = "rounded" }
	local group = vim.api.nvim_create_augroup("LspKeymaps", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		callback = function(event)
			delete_default_keymaps(event.buf)
		end,
		desc = "Remove conflicting Neovim 0.12 navigation defaults",
	})
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(event)
			delete_default_keymaps(event.buf)
			vim.keymap.set("n", "gd", M.definition, { buffer = event.buf, silent = true, desc = "Go to definition" })
			vim.keymap.set("n", "gD", M.declaration, { buffer = event.buf, silent = true, desc = "Go to declaration" })
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
