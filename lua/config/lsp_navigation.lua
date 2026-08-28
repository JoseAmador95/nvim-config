local M = {}

local editor = require("config.editor")
local review_lsp = require("config.review_lsp")

local NATIVE_DEFAULT_KEYMAPS = {
	{ "n", "K", "vim.lsp.buf.hover()" },
	{ "n", "gO", "vim.lsp.buf.document_symbol()" },
	{ "n", "gri", "vim.lsp.buf.implementation()" },
	{ "n", "grn", "vim.lsp.buf.rename()" },
	{ "n", "grr", "vim.lsp.buf.references()" },
	{ "n", "grt", "vim.lsp.buf.type_definition()" },
	{ "n", "grx", "vim.lsp.codelens.run()" },
	{ "n", "gra", "vim.lsp.buf.code_action()" },
	{ "x", "gra", "vim.lsp.buf.code_action()" },
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

local open_location_list

local function position_params(bufnr, row, byte_column, client)
	return {
		textDocument = vim.lsp.util.make_text_document_params(bufnr),
		position = {
			line = row,
			character = vim.lsp.util.character_offset(bufnr, row, byte_column, client.offset_encoding),
		},
	}
end

local function has_client(method, title, bufnr)
	local target = bufnr or vim.api.nvim_get_current_buf()
	if review_lsp.blocked(target) then
		notify((title or "LSP") .. ": disabled for historical review content")
		return nil
	end
	local clients = vim.lsp.get_clients({ bufnr = target, method = method })
	if clients and #clients > 0 then
		return clients
	end
	notify((title or "LSP") .. ": no active client for method")
	return nil
end

local function request_location_at(action, bufnr, line, column)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local clients = has_client(action.method, action.title, bufnr)
	if not clients then
		return false
	end
	local row = math.max(0, math.min(line - 1, vim.api.nvim_buf_line_count(bufnr) - 1))
	local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local byte_column = math.max(0, math.min(column - 1, #text))
	vim.lsp.buf_request_all(bufnr, action.method, function(client)
		local params = position_params(bufnr, row, byte_column, client)
		if action.references then
			params.context = { includeDeclaration = true }
		end
		return params
	end, function(results)
		local items = {}
		for client_id, response in pairs(results) do
			local client = vim.lsp.get_client_by_id(client_id)
			if client and response and response.result then
				local locations = vim.islist(response.result) and response.result or { response.result }
				vim.list_extend(items, vim.lsp.util.locations_to_items(locations, client.offset_encoding))
			end
		end
		if #items == 0 then
			notify(action.title .. ": no locations found")
			return
		end
		open_location_list(action, { items = items })
	end)
	return true
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

open_location_list = function(action, options)
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
		editor.open_file_in_tab(path, {
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
	implementation = {
		method = "textDocument/implementation",
		title = "Go to implementation",
	},
	references = {
		method = "textDocument/references",
		references = true,
		title = "References",
	},
	type_definition = {
		method = "textDocument/typeDefinition",
		title = "Go to type definition",
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

---Request one location-oriented LSP action for an explicit buffer position.
---@param name "declaration"|"definition"|"implementation"|"references"|"type_definition"
---@param bufnr integer
---@param line integer One-based line.
---@param column integer One-based byte column.
---@return boolean
function M.location_at(name, bufnr, line, column)
	local action = location_actions[name]
	if not action then
		error("unknown LSP location action: " .. tostring(name))
	end
	return request_location_at(action, bufnr, line, column)
end

function M.definition_at(bufnr, line, column)
	return M.location_at("definition", bufnr, line, column)
end

local function hover_contents(results)
	local values = {}
	for client_id, response in pairs(results) do
		if response and not response.err and response.result and response.result.contents then
			local lines = vim.lsp.util.convert_input_to_markdown_lines(response.result.contents)
			if #lines > 0 then
				values[#values + 1] = { client_id = client_id, lines = lines }
			end
		end
	end
	local contents = {}
	for _, value in ipairs(values) do
		if #values > 1 then
			local client = vim.lsp.get_client_by_id(value.client_id)
			contents[#contents + 1] = "# " .. (client and client.name or ("LSP " .. value.client_id))
		end
		vim.list_extend(contents, value.lines)
		contents[#contents + 1] = "---"
	end
	contents[#contents] = nil
	return contents
end

---Request hover for an explicit source position while keeping the review window active.
---@param bufnr integer
---@param line integer One-based line.
---@param column integer One-based byte column.
---@param options? { border?: string, winid?: integer, valid?: fun(): boolean }
---@return boolean
function M.hover_at(bufnr, line, column, options)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local clients = has_client("textDocument/hover", "Hover", bufnr)
	if not clients then
		return false
	end
	options = options or {}
	local request_win = options.winid or vim.api.nvim_get_current_win()
	local valid = options.valid
	local float_options = vim.deepcopy(options)
	float_options.winid = nil
	float_options.valid = nil
	float_options.border = float_options.border or "rounded"
	float_options.focus_id = "textDocument/hover"
	local row = math.max(0, math.min(line - 1, vim.api.nvim_buf_line_count(bufnr) - 1))
	local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local byte_column = math.max(0, math.min(column - 1, #text))
	vim.lsp.buf_request_all(bufnr, "textDocument/hover", function(client)
		return position_params(bufnr, row, byte_column, client)
	end, function(results)
		if (type(valid) == "function" and not valid()) or not vim.api.nvim_win_is_valid(request_win) then
			return
		end
		local contents = hover_contents(results)
		if #contents == 0 then
			notify("Hover: no information found")
			return
		end
		vim.api.nvim_win_call(request_win, function()
			vim.lsp.util.open_floating_preview(contents, "markdown", float_options)
		end)
	end)
	return true
end

local function global_keymap(mode, lhs)
	for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
		if mapping.lhs == lhs then
			return mapping
		end
	end
end

local function delete_default_keymaps(bufnr)
	local options = bufnr and { buffer = bufnr } or nil
	for _, default in ipairs(NATIVE_DEFAULT_KEYMAPS) do
		local mode, lhs, description = unpack(default)
		local mapping = not bufnr and global_keymap(mode, lhs) or nil
		if bufnr or (mapping and mapping.desc == description) then
			pcall(vim.keymap.del, mode, lhs, options)
		end
	end
end

function M.setup()
	delete_default_keymaps()
	local hover_opts = { border = "rounded" }
	local group = vim.api.nvim_create_augroup("LspKeymaps", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		callback = function(event)
			if review_lsp.enforce_blocked(event.buf) then
				return
			end
			delete_default_keymaps(event.buf)
		end,
		desc = "Remove conflicting Neovim 0.12 navigation defaults",
	})
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(event)
			if review_lsp.enforce_blocked(event.buf, event.data and event.data.client_id or nil) then
				return
			end
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
			vim.keymap.set("n", "K", function()
				vim.lsp.buf.hover(hover_opts)
			end, { buffer = event.buf, silent = true, desc = "Hover symbol documentation" })
			vim.keymap.set("n", "<C-k>", vim.lsp.buf.signature_help, {
				buffer = event.buf,
				silent = true,
				desc = "Signature help",
			})
			vim.keymap.set("n", "<leader>lr", vim.lsp.buf.rename, {
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
