local M = {}

local editor = require("config.editor")
local markdown_navigation = require("config.markdown_navigation")
local navigation_history = require("config.navigation_history")
local review = require("config.code_review")

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

local owned_mappings = {}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "LSP" })
end

local function lsp_error_message(err)
	return type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
end

local function review_definition_options(bufnr, winid)
	return review.lsp_definition_options(bufnr, winid)
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
	if review.lsp_blocked(target) then
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
	options = vim.tbl_extend("force", {}, options or {})
	options.history_origin = vim.deepcopy(navigation_history.capture())
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
		if not options_pending(action, options) then
			return
		end
		local items = {}
		local errors = {}
		for client_id, response in pairs(results or {}) do
			local client = vim.lsp.get_client_by_id(client_id)
			local response_error = response and (response.err or response.error) or nil
			if response_error then
				errors[#errors + 1] = (client and client.name or ("client " .. tostring(client_id)))
					.. ": "
					.. lsp_error_message(response_error)
			elseif client and response and response.result then
				local locations = vim.islist(response.result) and response.result or { response.result }
				vim.list_extend(items, vim.lsp.util.locations_to_items(locations, client.offset_encoding))
			end
		end
		if #errors > 0 then
			notify(action.title .. ": " .. table.concat(errors, "; "), vim.log.levels.WARN)
		end
		if #items == 0 then
			if #errors == 0 then
				notify(action.title .. ": no locations found")
			end
			return
		end
		open_location_list(action, vim.tbl_extend("force", {}, options, { items = items }))
	end)
	return true
end

local function request_location_from_client(action, client, bufnr, line, column, options)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	options = vim.tbl_extend("force", {}, options or {})
	options.history_origin = vim.deepcopy(navigation_history.capture())
	local row = math.max(0, math.min(line - 1, vim.api.nvim_buf_line_count(bufnr) - 1))
	local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	local byte_column = math.max(0, math.min(column - 1, #text))
	local params = position_params(bufnr, row, byte_column, client)
	local sent = client:request(action.method, params, function(err, result)
		if not options_pending(action, options) then
			return
		end
		if err then
			notify(action.title .. ": " .. lsp_error_message(err), vim.log.levels.WARN)
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
		open_location_list(action, vim.tbl_extend("force", {}, options, { items = items }))
	end, bufnr)
	if not sent then
		notify(action.title .. ": client rejected the request", vim.log.levels.WARN)
		return false
	end
	return true
end

local function snacks_picker_confirm(origin)
	return function(picker, item)
		picker:close()
		if not item then
			return
		end
		if type(item.buf) == "number" and vim.api.nvim_buf_is_valid(item.buf) then
			local name = vim.api.nvim_buf_get_name(item.buf)
			if name == "" or vim.bo[item.buf].buftype ~= "" then
				return
			end
		end
		local path = item.file
		if (not path or path == "") and item.buf then
			path = vim.api.nvim_buf_get_name(item.buf)
		end
		if not path or path == "" then
			return
		end
		local pos = item.pos or {}
		editor.open_file_in_tab(path, {
			lnum = pos[1] or 1,
			col = (pos[2] or 0) + 1,
			history_origin = origin,
		})
	end
end

local function snacks_lsp_picker(method, title, picker_name)
	return function()
		if not has_client(method, title) then
			return
		end
		local origin = vim.deepcopy(navigation_history.capture())
		local ok, snacks = pcall(require, "snacks")
		local picker = ok and snacks.picker and snacks.picker[picker_name] or nil
		if type(picker) ~= "function" then
			notify("Snacks picker not available", vim.log.levels.WARN)
			return
		end
		picker({ confirm = snacks_picker_confirm(origin) })
	end
end

options_valid = function(action, options)
	if type(options.valid) ~= "function" then
		return true
	end
	local ok, valid = pcall(options.valid)
	if not ok then
		notify(action.title .. ": location request could not be revalidated: " .. tostring(valid), vim.log.levels.WARN)
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
		notify(
			action.title .. ": pending location request could not be revalidated: " .. tostring(valid),
			vim.log.levels.WARN
		)
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
		local route_origin = navigation_history.capture()
		local ok, handled, route_err = pcall(options.route, location)
		if not ok then
			notify(action.title .. ": review location routing failed: " .. tostring(handled), vim.log.levels.WARN)
			return false
		elseif handled == true then
			local destination = navigation_history.capture()
			if route_origin and destination and not navigation_history.same_location(route_origin, destination) then
				navigation_history.record_transition(options.history_origin, destination)
			end
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
		history_origin = options.history_origin,
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
	local confirm = function(picker, item)
		picker:close()
		if item then
			dispatch_location(action, item._lsp_location or item, options)
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
	local request_options = vim.tbl_extend("force", {}, navigation_options or {})
	request_options.history_origin = vim.deepcopy(navigation_history.capture())
	action.request({
		on_list = function(options)
			open_location_list(action, vim.tbl_extend("force", {}, options, request_options))
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
	if review.lsp_blocked(target) then
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
		local origin = navigation_history.capture()
		vim.cmd("normal! gd")
		local destination = navigation_history.capture()
		if not navigation_history.same_location(origin, destination) then
			navigation_history.record_transition(origin, destination)
		end
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

local function current_keymap(mode, lhs, bufnr)
	local mappings = bufnr and vim.api.nvim_buf_get_keymap(bufnr, mode) or vim.api.nvim_get_keymap(mode)
	for _, mapping in ipairs(mappings) do
		if mapping.lhs == lhs then
			return mapping
		end
	end
end

local function delete_default_keymaps(bufnr)
	local options = bufnr and { buffer = bufnr } or nil
	for _, default in ipairs(NATIVE_DEFAULT_KEYMAPS) do
		local mode, lhs, description = unpack(default)
		local mapping = current_keymap(mode, lhs, bufnr)
		if mapping and mapping.desc == description then
			pcall(vim.keymap.del, mode, lhs, options)
		end
	end
end

local function owned_callback(bufnr, mode, lhs)
	return owned_mappings[bufnr] and owned_mappings[bufnr][mode] and owned_mappings[bufnr][mode][lhs]
end

local function remember_owned(bufnr, mode, lhs, callback)
	owned_mappings[bufnr] = owned_mappings[bufnr] or {}
	owned_mappings[bufnr][mode] = owned_mappings[bufnr][mode] or {}
	owned_mappings[bufnr][mode][lhs] = callback
end

local function forget_owned(bufnr, mode, lhs)
	local modes = owned_mappings[bufnr]
	if not modes or not modes[mode] then
		return
	end
	modes[mode][lhs] = nil
	if next(modes[mode]) == nil then
		modes[mode] = nil
	end
	if next(modes) == nil then
		owned_mappings[bufnr] = nil
	end
end

local function set_owned_keymap(bufnr, modes, lhs, callback, options)
	modes = type(modes) == "table" and modes or { modes }
	for _, mode in ipairs(modes) do
		local mapping = current_keymap(mode, lhs, bufnr)
		local owned = owned_callback(bufnr, mode, lhs)
		if not mapping or (owned and mapping.callback == owned) then
			local mapping_options = vim.tbl_extend("force", {}, options or {}, { buffer = bufnr })
			vim.keymap.set(mode, lhs, callback, mapping_options)
			remember_owned(bufnr, mode, lhs, callback)
		elseif owned then
			forget_owned(bufnr, mode, lhs)
		end
	end
end

local function clear_owned_keymaps(bufnr)
	local modes = owned_mappings[bufnr]
	owned_mappings[bufnr] = nil
	for mode, mappings in pairs(modes or {}) do
		for lhs, callback in pairs(mappings) do
			local mapping = current_keymap(mode, lhs, bufnr)
			if mapping and mapping.callback == callback then
				pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
			end
		end
	end
end

local function has_remaining_client(bufnr, detaching_client_id)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if client.id ~= detaching_client_id then
			return true
		end
	end
	return false
end

function M.setup()
	delete_default_keymaps()
	markdown_navigation.setup({
		allowed = M.navigation_allowed,
		eligible = function(bufnr)
			return not review.lsp_blocked(bufnr)
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
			if review.enforce_lsp_blocked(event.buf) then
				return
			end
			delete_default_keymaps(event.buf)
		end,
		desc = "Remove conflicting Neovim 0.12 navigation defaults",
	})
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(event)
			if review.enforce_lsp_blocked(event.buf, event.data and event.data.client_id or nil) then
				return
			end
			delete_default_keymaps(event.buf)
			if not markdown_navigation.handler(event.buf) then
				set_owned_keymap(event.buf, "n", "gd", M.definition, { silent = true, desc = "Go to definition" })
			end
			set_owned_keymap(event.buf, "n", "gD", M.declaration, { silent = true, desc = "Go to declaration" })
			set_owned_keymap(
				event.buf,
				"n",
				"gi",
				snacks_lsp_picker("textDocument/implementation", "Go to implementation", "lsp_implementations"),
				{ silent = true, desc = "Go to implementation" }
			)
			set_owned_keymap(
				event.buf,
				"n",
				"gr",
				snacks_lsp_picker("textDocument/references", "References", "lsp_references"),
				{ silent = true, desc = "References" }
			)
			set_owned_keymap(event.buf, "n", "K", function()
				vim.lsp.buf.hover(hover_opts)
			end, { silent = true, desc = "Hover symbol documentation" })
			set_owned_keymap(event.buf, "n", "<C-k>", vim.lsp.buf.signature_help, {
				silent = true,
				desc = "Signature help",
			})
			set_owned_keymap(event.buf, "n", "<leader>lr", vim.lsp.buf.rename, {
				silent = true,
				desc = "Rename",
			})
			set_owned_keymap(event.buf, { "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, {
				silent = true,
				desc = "Code action",
			})
		end,
	})
	vim.api.nvim_create_autocmd("LspDetach", {
		group = group,
		callback = function(event)
			local client_id = event.data and event.data.client_id or nil
			if not has_remaining_client(event.buf, client_id) then
				clear_owned_keymaps(event.buf)
			end
		end,
		desc = "Remove mappings after the last LSP client detaches",
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			owned_mappings[event.buf] = nil
		end,
		desc = "Forget disposed LSP mapping ownership",
	})
end

return M
