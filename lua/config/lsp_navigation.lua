local M = {}

local editor = require("config.editor")
local markdown_navigation = require("config.markdown_navigation")
local review_lsp = require("config.native_review").lsp

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

local function review_definition_options(bufnr, winid)
	if type(review_lsp.definition_options) ~= "function" then
		return nil
	end
	return review_lsp.definition_options(bufnr, winid)
end

local open_location_list
local options_valid
local options_pending

local function position_params(bufnr, row, byte_column, client)
	return {
		textDocument = vim.lsp.util.make_text_document_params(bufnr),
		position = {
			line = row,
			character = vim.lsp.util.character_offset(bufnr, row, byte_column, client.offset_encoding),
		},
	}
end

local function has_client(method, title, bufnr, options)
	options = options or {}
	local target = bufnr or vim.api.nvim_get_current_buf()
	if review_lsp.blocked(target) then
		notify((title or "LSP") .. ": disabled for historical review content")
		return nil, "blocked"
	end
	local filter = { bufnr = target, method = method }
	if options.name then
		filter.name = options.name
	end
	local clients = vim.lsp.get_clients(filter)
	if clients and #clients > 0 then
		return clients
	end
	if options.notify_missing ~= false then
		local detail = options.name and ("no active " .. options.name .. " client") or "no active client for method"
		notify((title or "LSP") .. ": " .. detail)
	end
	return nil, "missing"
end

local function request_location_at(action, bufnr, line, column, options)
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
		if not options_pending(action, options or {}) then
			return
		end
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
		open_location_list(action, vim.tbl_extend("force", {}, options or {}, { items = items }))
	end)
	return true
end

local function request_location_from_client(action, client, bufnr, line, column, options)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local row = math.max(0, math.min(line - 1, vim.api.nvim_buf_line_count(bufnr) - 1))
	local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local byte_column = math.max(0, math.min(column - 1, #text))
	local params = position_params(bufnr, row, byte_column, client)
	local sent = client:request(action.method, params, function(err, result)
		if not options_pending(action, options or {}) then
			return
		end
		if err then
			local message = type(err) == "table" and err.message or tostring(err)
			notify(action.title .. ": " .. tostring(message), vim.log.levels.WARN)
			return
		end
		if not result then
			notify(action.title .. ": no locations found")
			return
		end
		local locations = vim.islist(result) and result or { result }
		local items = vim.lsp.util.locations_to_items(locations, client.offset_encoding)
		if #items == 0 then
			notify(action.title .. ": no locations found")
			return
		end
		open_location_list(action, vim.tbl_extend("force", {}, options or {}, { items = items }))
	end, bufnr)
	if not sent then
		notify(action.title .. ": client rejected the request", vim.log.levels.WARN)
		return false
	end
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

options_valid = function(action, options)
	if type(options.valid) ~= "function" then
		return true
	end
	local ok, valid = pcall(options.valid)
	if not ok then
		notify(action.title .. ": location request could not be revalidated", vim.log.levels.WARN)
		return false
	end
	return valid == true
end

options_pending = function(action, options)
	local pending = options.pending
	if type(pending) ~= "function" then
		return true
	end
	local ok, valid = pcall(pending)
	if not ok then
		notify(action.title .. ": pending location request could not be revalidated", vim.log.levels.WARN)
		return false
	end
	return valid == true
end

local function location_from_item(item)
	local path = item.filename
	if (not path or path == "") and item.bufnr then
		path = vim.api.nvim_buf_get_name(item.bufnr)
	end
	if not path or path == "" then
		return nil
	end
	return {
		path = path,
		lnum = item.lnum or 1,
		col = item.col or 1,
		item = item,
	}
end

local function dispatch_location(action, item, options)
	local routed = type(options.route) == "function"
	if (not routed or options.route_revalidates ~= true) and not options_valid(action, options) then
		return false
	end
	local location = location_from_item(item)
	if not location then
		notify(action.title .. ": invalid location from server", vim.log.levels.WARN)
		return false
	end
	-- Review routers return true when consumed and false only for a verified
	-- outside-diff destination. Errors and missing decisions fail closed.
	if routed then
		local ok, handled, route_err = pcall(options.route, location)
		if not ok then
			notify(action.title .. ": review location routing failed: " .. tostring(handled), vim.log.levels.WARN)
			return false
		elseif handled == true then
			return true
		elseif route_err then
			notify(action.title .. ": " .. tostring(route_err), vim.log.levels.WARN)
			return false
		elseif handled ~= false then
			notify(action.title .. ": review location routing returned no decision", vim.log.levels.WARN)
			return false
		end
	end
	editor.open_file_in_tab(location.path, {
		lnum = location.lnum,
		col = location.col,
	})
	return true
end

open_location_list = function(action, options)
	local items = options.items or {}
	if not options_pending(action, options) then
		return
	end
	if #items == 1 then
		dispatch_location(action, items[1], options)
		return
	end
	-- A multi-result picker can stay open indefinitely. Fully validate before
	-- exposing it, then validate again only when the user confirms a choice.
	if not options_valid(action, options) then
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
				_lsp_location = item,
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
	local confirm = "open_in_tab"
	if type(options.route) == "function" or type(options.valid) == "function" then
		confirm = function(picker, item)
			picker:close()
			if item then
				dispatch_location(action, item._lsp_location or item, options)
			end
		end
	end
	snacks.picker.pick({
		items = picker_items,
		format = "file",
		confirm = confirm,
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
	local bufnr = vim.api.nvim_get_current_buf()
	local winid = vim.api.nvim_get_current_win()
	local navigation_options = name == "definition" and review_definition_options(bufnr, winid) or nil
	if not has_client(action.method, action.title) then
		return false
	end
	if navigation_options and not options_valid(action, navigation_options) then
		return false
	end
	action.request({
		on_list = function(options)
			open_location_list(action, vim.tbl_extend("force", {}, options, navigation_options or {}))
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
---@param options? { valid?: fun(): boolean, route?: fun(location: table): boolean? }
---@return boolean
function M.location_at(name, bufnr, line, column, options)
	local action = location_actions[name]
	if not action then
		error("unknown LSP location action: " .. tostring(name))
	end
	return request_location_at(action, bufnr, line, column, options)
end

function M.definition_at(bufnr, line, column, options)
	return M.location_at("definition", bufnr, line, column, options)
end

---Return whether navigation is allowed for this buffer. Historical native-review
---buffers must never escape to CURRENT source through a host mapping.
---@param bufnr? integer
---@param title? string
---@return boolean
function M.navigation_allowed(bufnr, title)
	local target = bufnr or vim.api.nvim_get_current_buf()
	if review_lsp.blocked(target) then
		notify((title or "LSP") .. ": disabled for historical review content")
		return false
	end
	return true
end

---Request a definition from one named client only.
---@param name string
---@param bufnr integer
---@param line integer One-based line.
---@param column integer One-based byte column.
---@param title? string
---@return boolean
function M.definition_at_for_client(name, bufnr, line, column, title)
	local action = vim.tbl_extend("force", location_actions.definition, {
		title = title or ("Go to definition via " .. name),
	})
	local navigation_options = review_definition_options(bufnr, vim.api.nvim_get_current_win())
	local clients = has_client(action.method, action.title, bufnr, { name = name })
	if not clients then
		return false
	end
	if navigation_options and not options_valid(action, navigation_options) then
		return false
	end
	return request_location_from_client(action, clients[1], bufnr, line, column, navigation_options)
end

---Use LSP definition when available, otherwise preserve native tag navigation.
---Historical review content is blocked without falling through to native `gd`.
---@param bufnr? integer
---@return boolean
function M.definition_or_native(bufnr)
	local target = bufnr or vim.api.nvim_get_current_buf()
	local action = location_actions.definition
	local navigation_options = review_definition_options(target, vim.api.nvim_get_current_win())
	local clients, reason = has_client(action.method, action.title, target, { notify_missing = false })
	if clients then
		if navigation_options and not options_valid(action, navigation_options) then
			return false
		end
		local cursor = vim.api.nvim_win_get_cursor(0)
		return request_location_at(action, target, cursor[1], cursor[2] + 1, navigation_options)
	end
	if reason == "missing" then
		vim.cmd("normal! gd")
		return true
	end
	return false
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
	markdown_navigation.setup({
		allowed = M.navigation_allowed,
		eligible = function(bufnr)
			return not review_lsp.blocked(bufnr)
		end,
		definition = M.definition_or_native,
		marksman = function(bufnr, line, column)
			return M.definition_at_for_client("marksman", bufnr, line, column, "Markdown link")
		end,
	})
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
			local definition = markdown_navigation.handler(event.buf) or M.definition
			vim.keymap.set("n", "gd", definition, { buffer = event.buf, silent = true, desc = "Go to definition" })
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
