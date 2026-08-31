-- LSP isolation and conservative CURRENT-only bridging for native review buffers.
local M = {}

local dependencies = require("native_review.dependencies")
local editor = dependencies.get("editor")
local repo = dependencies.get("repo")

local BLOCKED = { old = true, snapshot = true, unified = true, panel = true }
local DIAGNOSTIC_NAMESPACE = vim.api.nvim_create_namespace("NvimReviewCurrentDiagnostics")
local LSP_NAVIGATION_MAPPINGS = {
	{ "n", "gd" },
	{ "n", "gD" },
	{ "n", "gi" },
	{ "n", "gr" },
	{ "n", "K" },
	{ "n", "gO" },
	{ "n", "gri" },
	{ "n", "grn" },
	{ "n", "grr" },
	{ "n", "grt" },
	{ "n", "grx" },
	{ "n", "gra" },
	{ "x", "gra" },
	{ "n", "<C-k>" },
	{ "n", "<leader>lr" },
	{ "n", "<leader>ca" },
	{ "v", "<leader>ca" },
}
local READ_ONLY_ACTIONS = {
	declaration = { method = "textDocument/declaration", mappings = { "gD" }, title = "declaration" },
	definition = { method = "textDocument/definition", mappings = { "gd" }, title = "definition" },
	hover = { method = "textDocument/hover", mappings = { "K" }, title = "hover" },
	implementation = {
		method = "textDocument/implementation",
		mappings = { "gi", "gri" },
		title = "implementation",
	},
	references = { method = "textDocument/references", mappings = { "gr", "grr" }, title = "references" },
	type_definition = {
		method = "textDocument/typeDefinition",
		mappings = { "grt" },
		title = "type definition",
	},
}
local metadata_by_buffer = {}
local mirrors_by_buffer = {}
local mirror_serial = 0
local setup_done = false
local start_diagnostic_mirror
local stop_diagnostic_mirror

local function valid_buffer(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function role(buf)
	if not valid_buffer(buf) then
		return nil
	end
	return vim.b[buf].nvim_review_role
end

local function clear_navigation_mappings(buf)
	for _, mapping in ipairs(LSP_NAVIGATION_MAPPINGS) do
		pcall(vim.keymap.del, mapping[1], mapping[2], { buffer = buf })
	end
end

local function clear_navic(buf)
	pcall(vim.api.nvim_clear_autocmds, { buffer = buf, group = "navic" })
	vim.b[buf].navic_client_id = nil
	vim.b[buf].navic_client_name = nil
	vim.b[buf].navic_awaiting_lsp_response = nil
	local lib = package.loaded["nvim-navic.lib"]
	if lib and type(lib.clear_buffer_data) == "function" then
		pcall(lib.clear_buffer_data, buf)
	end
end

local function review_notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Review" })
end

local function guard_message(buf)
	if role(buf) == "unified" then
		return "Direct LSP actions are disabled for the unified review projection"
	end
	return "LSP is disabled for historical review content"
end

local function set_guard_mapping(buf, mode, lhs)
	vim.keymap.set(mode, lhs, function()
		review_notify(guard_message(buf))
	end, {
		buffer = buf,
		silent = true,
		desc = "Historical review buffer has no LSP",
	})
end

local function set_unified_mapping(buf, lhs, action_name, action)
	vim.keymap.set("n", lhs, function()
		local win = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_get_buf(win) ~= buf then
			review_notify("The unified review projection is not active in this window")
			return
		end
		local cursor = vim.api.nvim_win_get_cursor(win)
		local ok, err = M.navigate(buf, action_name, cursor[1], cursor[2] + 1, metadata_by_buffer[buf], win)
		if not ok and err then
			review_notify(err)
		end
	end, {
		buffer = buf,
		silent = true,
		desc = "Review " .. action.title .. " in current source",
	})
end

local function install_guard_mapping(buf)
	if not valid_buffer(buf) or not BLOCKED[role(buf)] then
		return
	end
	clear_navigation_mappings(buf)
	for _, mapping in ipairs(LSP_NAVIGATION_MAPPINGS) do
		set_guard_mapping(buf, mapping[1], mapping[2])
	end
	local buffer_role = role(buf)
	local metadata = metadata_by_buffer[buf] or {}
	if buffer_role == "snapshot" and metadata.bridge ~= false then
		vim.keymap.set("n", "gd", function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			local ok, err = M.goto_definition(buf, cursor[1], cursor[2] + 1, metadata_by_buffer[buf])
			if not ok and err then
				review_notify(err)
			end
		end, { buffer = buf, silent = true, desc = "Review definition in current source" })
	elseif buffer_role == "unified" and metadata.bridge == true then
		for action_name, action in pairs(READ_ONLY_ACTIONS) do
			for _, lhs in ipairs(action.mappings) do
				set_unified_mapping(buf, lhs, action_name, action)
			end
		end
	end
end

local function detach_clients(buf, client_id)
	if client_id then
		pcall(vim.lsp.buf_detach_client, buf, client_id)
	end
	local ok, clients = pcall(vim.lsp.get_clients, { bufnr = buf })
	if not ok then
		return
	end
	for _, client in ipairs(clients) do
		if client.id ~= client_id then
			pcall(vim.lsp.buf_detach_client, buf, client.id)
		end
	end
end

---Detach accidental clients and restore the fail-closed mappings for a review buffer.
---@param buf integer
---@param client_id? integer
---@return boolean
function M.enforce_blocked(buf, client_id)
	if not valid_buffer(buf) or not BLOCKED[role(buf)] then
		return false
	end
	detach_clients(buf, client_id)
	clear_navic(buf)
	install_guard_mapping(buf)
	return true
end

local function source_lines(source)
	if type(source) == "number" then
		if not valid_buffer(source) then
			return nil, "buffer is no longer valid"
		end
		return vim.api.nvim_buf_get_lines(source, 0, -1, false)
	elseif type(source) == "string" then
		local text = source
		if text:sub(-1) == "\n" then
			text = text:sub(1, -2)
		end
		return vim.split(text, "\n", { plain = true })
	elseif type(source) == "table" and vim.islist(source) then
		return source
	end
	return nil, "source must be a buffer, string, or line list"
end

local function build_line_maps(snapshot, current)
	local snapshot_lines, snapshot_err = source_lines(snapshot)
	if not snapshot_lines then
		return nil, nil, snapshot_err
	end
	local current_lines, current_err = source_lines(current)
	if not current_lines then
		return nil, nil, current_err
	end
	local snapshot_text = table.concat(snapshot_lines, "\n") .. "\n"
	local current_text = table.concat(current_lines, "\n") .. "\n"
	local forward = {}
	local reverse = {}
	local snapshot_next = 1
	local current_next = 1
	for _, hunk in ipairs(vim.diff(snapshot_text, current_text, { result_type = "indices" })) do
		local snapshot_start, snapshot_count, current_start, current_count = unpack(hunk)
		local snapshot_first = snapshot_count == 0 and snapshot_start + 1 or snapshot_start
		local current_first = current_count == 0 and current_start + 1 or current_start
		local snapshot_gap = snapshot_first - snapshot_next
		local current_gap = current_first - current_next
		if snapshot_gap < 0 or current_gap < 0 or snapshot_gap ~= current_gap then
			return nil, nil, "current source diff has inconsistent unchanged regions"
		end
		for offset = 0, snapshot_gap - 1 do
			local snapshot_line = snapshot_next + offset
			local current_line = current_next + offset
			if snapshot_lines[snapshot_line] ~= current_lines[current_line] then
				return nil, nil, "current source diff mapped unequal lines"
			end
			forward[snapshot_line] = current_line
			reverse[current_line] = snapshot_line
		end
		snapshot_next = snapshot_first + snapshot_count
		current_next = current_first + current_count
	end
	local snapshot_tail = #snapshot_lines - snapshot_next + 1
	local current_tail = #current_lines - current_next + 1
	if snapshot_tail < 0 or current_tail < 0 or snapshot_tail ~= current_tail then
		return nil, nil, "current source diff has inconsistent tails"
	end
	for offset = 0, snapshot_tail - 1 do
		local snapshot_line = snapshot_next + offset
		local current_line = current_next + offset
		if snapshot_lines[snapshot_line] ~= current_lines[current_line] then
			return nil, nil, "current source diff mapped unequal lines"
		end
		forward[snapshot_line] = current_line
		reverse[current_line] = snapshot_line
	end
	return forward, reverse
end

---Mark a buffer before setting its filetype so native LSP root discovery can reject it.
---@param buf integer
---@param buffer_role "old"|"snapshot"|"unified"|"current"|"panel"
---@param metadata? table
---@return boolean
function M.mark(buf, buffer_role, metadata)
	if
		not valid_buffer(buf)
		or not ({ old = true, snapshot = true, unified = true, current = true, panel = true })[buffer_role]
	then
		return false
	end
	stop_diagnostic_mirror(buf)
	vim.b[buf].nvim_review_role = buffer_role
	metadata_by_buffer[buf] = metadata or {}
	M.enforce_blocked(buf)
	if buffer_role == "unified" then
		start_diagnostic_mirror(buf, metadata_by_buffer[buf])
	end
	return true
end

---Whether native LSP must never attach to this buffer.
---@param buf integer
---@return boolean
function M.blocked(buf)
	return BLOCKED[role(buf)] == true
end

---Wrap a native root_dir callback with the review role gate.
---@param upstream? string|fun(bufnr: integer, on_dir: fun(root_dir?: string))
---@param root_markers? string[]
---@return fun(bufnr: integer, on_dir: fun(root_dir?: string))
function M.wrap_root_dir(upstream, root_markers)
	return function(bufnr, on_dir)
		if M.blocked(bufnr) then
			return
		end
		if type(upstream) == "function" then
			upstream(bufnr, on_dir)
		elseif type(upstream) == "string" then
			on_dir(upstream)
		else
			on_dir(root_markers and vim.fs.root(bufnr, root_markers) or nil)
		end
	end
end

---Map a one-based historical-new line only when it belongs to an unchanged region.
---@param snapshot integer|string|string[]
---@param current integer|string|string[]
---@param line integer
---@return integer? mapped_line
---@return string? err
function M.map_line(snapshot, current, line)
	if type(line) ~= "number" or line % 1 ~= 0 or line < 1 then
		return nil, "line must be a positive integer"
	end
	local snapshot_lines, snapshot_err = source_lines(snapshot)
	if not snapshot_lines then
		return nil, snapshot_err
	end
	if line > #snapshot_lines then
		return nil, "line is outside the historical snapshot"
	end
	local forward, _, map_err = build_line_maps(snapshot, current)
	if not forward then
		return nil, map_err
	end
	return forward[line], forward[line] and nil or "the historical line is inside a changed hunk"
end

local function find_buffer(path)
	local expected = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buffer(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
			local name = vim.api.nvim_buf_get_name(buf)
			if vim.fs.normalize(vim.uv.fs_realpath(name) or name) == expected then
				if not vim.api.nvim_buf_is_loaded(buf) then
					vim.fn.bufload(buf)
				end
				return buf
			end
		end
	end
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	return buf
end

local function read_file(path)
	local handle, open_err = vim.uv.fs_open(path, "r", 0)
	if not handle then
		return nil, open_err
	end
	local stat, stat_err = vim.uv.fs_fstat(handle)
	if not stat then
		vim.uv.fs_close(handle)
		return nil, stat_err
	end
	local value, read_err = vim.uv.fs_read(handle, stat.size, 0)
	vim.uv.fs_close(handle)
	return value, read_err
end

local function buffer_text(buf)
	local separator = ({ dos = "\r\n", mac = "\r" })[vim.bo[buf].fileformat] or "\n"
	local value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), separator)
	return vim.bo[buf].endofline and value .. separator or value
end

local function same_path(left, right)
	local normalized_left = vim.fs.normalize(vim.uv.fs_realpath(left) or left)
	local normalized_right = vim.fs.normalize(vim.uv.fs_realpath(right) or right)
	return normalized_left == normalized_right
end

local function resolve_current_source(metadata, expected_buf)
	local root = metadata.root
	local relative = metadata.current_path or metadata.path
	if type(root) ~= "string" or type(relative) ~= "string" then
		return nil, "the review projection has no current source target"
	end
	local path, resolved_or_err = repo.resolve_relative(root, relative)
	if not path then
		return nil, "current source is unavailable: " .. tostring(resolved_or_err)
	end
	local disk, disk_err = read_file(path)
	if disk == nil then
		return nil, "current source is unavailable: " .. tostring(disk_err)
	end
	local current_buf
	if expected_buf ~= nil then
		if not valid_buffer(expected_buf) then
			return nil, "current source buffer is no longer valid"
		elseif not same_path(vim.api.nvim_buf_get_name(expected_buf), path) then
			return nil, "current source buffer identity changed"
		end
		current_buf = expected_buf
	else
		current_buf = find_buffer(path)
	end
	if M.blocked(current_buf) then
		return nil, "current source is itself a blocked review buffer"
	elseif vim.bo[current_buf].buftype ~= "" then
		return nil, "current source is not a normal file buffer"
	elseif vim.bo[current_buf].modified then
		return nil, "current source has unsaved changes"
	end
	local loaded = buffer_text(current_buf)
	if loaded ~= disk then
		return nil, "current source buffer differs from the file on disk"
	end
	return {
		buf = current_buf,
		changedtick = vim.api.nvim_buf_get_changedtick(current_buf),
		lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false),
		path = path,
		text = disk,
	}
end

local function projection_new_lines(metadata)
	local source = metadata.projection and metadata.projection.sources and metadata.projection.sources.new
	if not source or type(source.lines) ~= "table" or not source.path then
		return nil, "the unified review projection has no NEW source"
	elseif type(metadata.root) ~= "string" or type(metadata.current_path) ~= "string" then
		return nil, "the unified review projection has no CURRENT source target"
	end
	local projection_lexical, projection_path = repo.resolve_relative(metadata.root, source.path)
	local current_lexical, current_path = repo.resolve_relative(metadata.root, metadata.current_path)
	if
		not projection_lexical
		or not current_lexical
		or vim.fs.normalize(projection_path) ~= vim.fs.normalize(current_path)
	then
		return nil, "the unified review projection NEW path no longer matches CURRENT"
	end
	local lines = {}
	for index, record in ipairs(source.lines) do
		if type(record) ~= "table" or type(record.text) ~= "string" then
			return nil, "the unified review projection has invalid NEW source lines"
		end
		lines[index] = record.text
	end
	return lines
end

local function projection_maps(display_buf, metadata, current)
	local projection = metadata.projection
	if type(projection) ~= "table" or type(projection.rows) ~= "table" then
		return nil, "the unified review projection has no row mapping"
	end
	local snapshot_lines, snapshot_err = projection_new_lines(metadata)
	if not snapshot_lines then
		return nil, snapshot_err
	end
	local display_lines = vim.api.nvim_buf_get_lines(display_buf, 0, -1, false)
	if #display_lines ~= #projection.rows then
		return nil, "the unified review projection row count changed"
	end
	for display_line, row in ipairs(projection.rows) do
		if
			type(row) ~= "table"
			or row.display_line ~= display_line
			or type(row.text) ~= "string"
			or display_lines[display_line] ~= row.text
		then
			return nil, "the unified review projection rows changed"
		end
		if row.new_line then
			if
				snapshot_lines[row.new_line] ~= row.text
				or not projection.by_source
				or not projection.by_source.new
				or projection.by_source.new[row.new_line] ~= display_line
			then
				return nil, "the unified review projection NEW mapping changed"
			end
		end
	end
	local forward, reverse, map_err = build_line_maps(snapshot_lines, current.lines)
	if not forward then
		return nil, map_err
	end
	return {
		current_to_new = reverse,
		new_to_current = forward,
		new_to_display = projection.by_source.new,
		projection = projection,
		snapshot_lines = snapshot_lines,
	}
end

local function display_line_visible(metadata, display_line)
	if metadata.context ~= "hunks" then
		return true
	end
	local sections = metadata.visible_sections
	if type(sections) ~= "table" then
		return false
	elseif #sections == 0 then
		return true
	end
	for _, section in ipairs(sections) do
		if display_line >= section.first and display_line <= section.last then
			return true
		end
	end
	return false
end

local function projection_generation_current(buf, metadata)
	return type(metadata.generation) == "number" and vim.b[buf].nvim_review_projection_generation == metadata.generation
end

---Resolve one unified display position through frozen NEW to the live CURRENT source.
---@param buf integer
---@param display_line integer
---@param column? integer One-based byte column.
---@param metadata? table
---@return table? position
---@return string? err
function M.resolve_current_position(buf, display_line, column, metadata)
	if not valid_buffer(buf) or role(buf) ~= "unified" then
		return nil, "current-source bridging requires a unified review projection"
	elseif type(display_line) ~= "number" or display_line < 1 or display_line % 1 ~= 0 then
		return nil, "display line must be a positive integer"
	end
	metadata = metadata or metadata_by_buffer[buf]
	if type(metadata) ~= "table" or metadata_by_buffer[buf] ~= metadata then
		return nil, "the unified review projection is no longer current"
	elseif metadata.bridge ~= true then
		return nil, "current-source bridging is disabled for this unified review projection"
	end
	if not projection_generation_current(buf, metadata) then
		return nil, "the unified review projection generation changed"
	end
	local row = metadata.projection and metadata.projection.rows and metadata.projection.rows[display_line]
	if not row then
		return nil, "display line is outside the unified review projection"
	elseif row.kind == "old" or (row.old_line and not row.new_line) then
		return nil, "LSP navigation is unavailable on OLD review rows"
	elseif row.kind == "empty" or not row.anchorable or not row.new_line then
		return nil, "this review row has no CURRENT source location"
	end
	local _, projection_err = projection_new_lines(metadata)
	if projection_err then
		return nil, projection_err
	end
	local current, current_err = resolve_current_source(metadata)
	if not current then
		return nil, current_err
	end
	local maps, map_err = projection_maps(buf, metadata, current)
	if not maps then
		return nil, map_err
	end
	local current_line = maps.new_to_current[row.new_line]
	if not current_line then
		return nil, "the frozen NEW line differs from the live CURRENT source"
	end
	local target_column = column or metadata.column or 1
	if type(target_column) ~= "number" or target_column < 1 or target_column % 1 ~= 0 then
		return nil, "column must be a positive integer"
	end
	return {
		buf = current.buf,
		changedtick = current.changedtick,
		column = target_column,
		current_text = current.text,
		display_line = display_line,
		line = current_line,
		maps = maps,
		new_line = row.new_line,
		path = current.path,
		row = row,
	}
end

local function reset_mirrored_diagnostics(buf)
	pcall(vim.diagnostic.reset, DIAGNOSTIC_NAMESPACE, buf)
end

local function copy_user_data(value)
	if value == nil then
		return nil
	end
	local ok, copied = pcall(vim.deepcopy, value)
	return ok and copied or value
end

local function map_diagnostic(record, diagnostic, maps)
	if
		type(diagnostic) ~= "table"
		or type(diagnostic.lnum) ~= "number"
		or diagnostic.lnum < 0
		or diagnostic.lnum % 1 ~= 0
	then
		return nil
	end
	local end_lnum = diagnostic.end_lnum or diagnostic.lnum
	local end_col = diagnostic.end_col or diagnostic.col or 0
	if type(end_lnum) ~= "number" or end_lnum < diagnostic.lnum or end_lnum % 1 ~= 0 then
		return nil
	end
	local half_open = end_lnum > diagnostic.lnum and end_col == 0
	local source_first = diagnostic.lnum + 1
	local source_last = half_open and end_lnum or end_lnum + 1
	local display_first
	local display_last
	local previous_display
	local previous_new
	for source_line = source_first, source_last do
		local new_line = maps.current_to_new[source_line]
		local display_line = new_line and maps.new_to_display[new_line] or nil
		local row = display_line and maps.projection.rows[display_line] or nil
		if
			not row
			or not row.new_line
			or row.new_line ~= new_line
			or (row.kind ~= "new" and row.kind ~= "context")
			or not display_line_visible(record.metadata, display_line)
			or (previous_display and display_line ~= previous_display + 1)
			or (previous_new and new_line ~= previous_new + 1)
		then
			return nil
		end
		display_first = display_first or display_line
		display_last = display_line
		previous_display = display_line
		previous_new = new_line
	end
	if not display_first or not display_last then
		return nil
	end
	local mapped_end_col = end_col
	local mapped_end_lnum = display_last - 1
	if half_open then
		local endpoint_new = maps.current_to_new[end_lnum + 1]
		local endpoint_display = endpoint_new and maps.new_to_display[endpoint_new] or nil
		local endpoint_row = endpoint_display and maps.projection.rows[endpoint_display] or nil
		if
			endpoint_display == display_last + 1
			and endpoint_row
			and endpoint_row.new_line == endpoint_new
			and (endpoint_row.kind == "new" or endpoint_row.kind == "context")
		then
			mapped_end_lnum = endpoint_display - 1
			mapped_end_col = 0
		else
			mapped_end_col = #(maps.projection.rows[display_last].text or "")
			if display_last > display_first and mapped_end_col == 0 then
				return nil
			end
		end
	end
	local mapped = {
		col = diagnostic.col or 0,
		end_col = mapped_end_col,
		end_lnum = mapped_end_lnum,
		lnum = display_first - 1,
		message = diagnostic.message,
		severity = diagnostic.severity,
	}
	if diagnostic.code ~= nil then
		mapped.code = diagnostic.code
	end
	if diagnostic.source ~= nil then
		mapped.source = diagnostic.source
	end
	if diagnostic.user_data ~= nil then
		mapped.user_data = copy_user_data(diagnostic.user_data)
	end
	if diagnostic._tags ~= nil then
		mapped._tags = copy_user_data(diagnostic._tags)
	end
	return mapped
end

local function refresh_mirror(record)
	if
		not record.active
		or mirrors_by_buffer[record.display_buf] ~= record
		or not valid_buffer(record.display_buf)
		or role(record.display_buf) ~= "unified"
		or metadata_by_buffer[record.display_buf] ~= record.metadata
	then
		return nil, "the diagnostic mirror is no longer active"
	elseif not projection_generation_current(record.display_buf, record.metadata) then
		reset_mirrored_diagnostics(record.display_buf)
		record.last_error = "the unified review projection generation changed"
		return nil, record.last_error
	end
	local current, current_err = resolve_current_source(record.metadata, record.source_buf)
	if not current then
		reset_mirrored_diagnostics(record.display_buf)
		record.last_error = current_err
		return nil, current_err
	end
	local maps, map_err = projection_maps(record.display_buf, record.metadata, current)
	if not maps then
		reset_mirrored_diagnostics(record.display_buf)
		record.last_error = map_err
		return nil, map_err
	end
	local get_diagnostics = record.metadata.get_diagnostics or vim.diagnostic.get
	local diagnostics = get_diagnostics(current.buf) or {}
	local mapped = {}
	for _, diagnostic in ipairs(diagnostics) do
		if diagnostic.namespace ~= DIAGNOSTIC_NAMESPACE then
			local value = map_diagnostic(record, diagnostic, maps)
			if value then
				mapped[#mapped + 1] = value
			end
		end
	end
	vim.diagnostic.set(DIAGNOSTIC_NAMESPACE, record.display_buf, mapped)
	record.last_error = nil
	record.last_source_changedtick = current.changedtick
	return true
end

local function schedule_mirror(record)
	if not record.active or record.pending then
		return
	end
	record.pending = true
	local serial = record.serial
	vim.schedule(function()
		if not record.active or record.serial ~= serial or mirrors_by_buffer[record.display_buf] ~= record then
			return
		end
		record.pending = false
		refresh_mirror(record)
	end)
end

stop_diagnostic_mirror = function(buf)
	local record = mirrors_by_buffer[buf]
	if not record then
		return false
	end
	record.active = false
	record.pending = false
	mirrors_by_buffer[buf] = nil
	for _, autocmd in ipairs(record.autocmds) do
		pcall(vim.api.nvim_del_autocmd, autocmd)
	end
	record.autocmds = {}
	reset_mirrored_diagnostics(buf)
	return true
end

start_diagnostic_mirror = function(buf, metadata)
	stop_diagnostic_mirror(buf)
	if role(buf) ~= "unified" or metadata.bridge ~= true or not metadata.current_path then
		return false
	end
	local snapshot_lines = projection_new_lines(metadata)
	if not snapshot_lines or not projection_generation_current(buf, metadata) then
		return false
	end
	local path = repo.resolve_relative(metadata.root, metadata.current_path)
	if not path or read_file(path) == nil then
		return false
	end
	local source_buf = find_buffer(path)
	if M.blocked(source_buf) or vim.bo[source_buf].buftype ~= "" then
		return false
	end
	mirror_serial = mirror_serial + 1
	local record = {
		active = true,
		autocmds = {},
		display_buf = buf,
		metadata = metadata,
		pending = false,
		serial = mirror_serial,
		source_buf = source_buf,
	}
	mirrors_by_buffer[buf] = record
	local group = vim.api.nvim_create_augroup("NvimReviewDiagnosticMirror", { clear = false })
	record.autocmds[#record.autocmds + 1] = vim.api.nvim_create_autocmd("DiagnosticChanged", {
		buffer = source_buf,
		group = group,
		desc = "Mirror current-source diagnostics into a unified review projection",
		callback = function()
			schedule_mirror(record)
		end,
	})
	record.autocmds[#record.autocmds + 1] = vim.api.nvim_create_autocmd(
		{ "BufModifiedSet", "BufReadPost", "BufWritePost", "FileChangedShellPost", "TextChanged", "TextChangedI" },
		{
			buffer = source_buf,
			group = group,
			desc = "Invalidate diagnostics when current review source changes",
			callback = function()
				schedule_mirror(record)
			end,
		}
	)
	record.autocmds[#record.autocmds + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = source_buf,
		group = group,
		desc = "Clear review diagnostics when current source is wiped",
		callback = function()
			stop_diagnostic_mirror(buf)
		end,
	})
	record.autocmds[#record.autocmds + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		group = group,
		desc = "Clear unified review diagnostic ownership",
		callback = function()
			M.clear(buf)
		end,
	})
	schedule_mirror(record)
	return true
end

---Synchronously refresh a unified projection's diagnostic mirror.
---@param buf integer
---@return boolean?
---@return string? err
function M.refresh_diagnostics(buf)
	local record = mirrors_by_buffer[buf]
	if not record then
		return nil, "the unified review projection has no diagnostic mirror"
	end
	return refresh_mirror(record)
end

local function wait_for_lsp(buf, metadata, method, callback)
	local ready = metadata.lsp_ready
		or function(target)
			return #vim.lsp.get_clients({ bufnr = target, method = method }) > 0
		end
	local defer = metadata.defer or vim.defer_fn
	local timeout = metadata.lsp_timeout
		or function()
			vim.notify("LSP did not attach to the current source in time", vim.log.levels.WARN, { title = "Review" })
		end
	local attempts = 0
	local function poll()
		if not valid_buffer(buf) then
			return
		end
		attempts = attempts + 1
		if ready(buf) then
			vim.schedule(callback)
			return
		elseif attempts >= 40 then
			vim.schedule(timeout)
			return
		end
		defer(poll, 50)
	end
	poll()
end

local function position_unchanged(initial, current)
	return current
		and current.buf == initial.buf
		and current.line == initial.line
		and current.new_line == initial.new_line
		and current.current_text == initial.current_text
		and current.changedtick == initial.changedtick
end

---Bridge one allowlisted read-only action through the real CURRENT source.
---@param buf integer
---@param action_name "declaration"|"definition"|"hover"|"implementation"|"references"|"type_definition"
---@param display_line integer
---@param column? integer One-based byte column.
---@param metadata? table
---@param review_win? integer
---@return boolean?
---@return string? err
function M.navigate(buf, action_name, display_line, column, metadata, review_win)
	local action = READ_ONLY_ACTIONS[action_name]
	if not action then
		return nil, "unsupported review LSP action"
	end
	metadata = metadata or metadata_by_buffer[buf]
	local position, position_err = M.resolve_current_position(buf, display_line, column, metadata)
	if not position then
		return nil, position_err
	end
	review_win = review_win or vim.api.nvim_get_current_win()
	if action_name ~= "hover" then
		local open = metadata.open or editor.open_file_in_tab
		open(position.path, { lnum = position.line, col = position.column })
	end
	wait_for_lsp(position.buf, metadata, action.method, function()
		if not valid_buffer(buf) or role(buf) ~= "unified" or metadata_by_buffer[buf] ~= metadata then
			return
		end
		local current, current_err = M.resolve_current_position(buf, display_line, column, metadata)
		if not position_unchanged(position, current) then
			review_notify(current_err or "Current source mapping changed while waiting for LSP", vim.log.levels.WARN)
			return
		end
		local navigate = metadata.navigate
		if type(navigate) == "function" then
			navigate(action_name, current.buf, current.line, current.column, { winid = review_win })
			return
		end
		local navigation = metadata.navigation
		if type(navigation) ~= "table" then
			review_notify("Current-source LSP navigation is unavailable", vim.log.levels.WARN)
			return
		end
		if action_name == "hover" then
			navigation.hover_at(current.buf, current.line, current.column, {
				border = "rounded",
				valid = function()
					return valid_buffer(buf)
						and role(buf) == "unified"
						and metadata_by_buffer[buf] == metadata
						and vim.api.nvim_win_is_valid(review_win)
						and vim.api.nvim_win_get_buf(review_win) == buf
				end,
				winid = review_win,
			})
		else
			navigation.location_at(action_name, current.buf, current.line, current.column)
		end
	end)
	return true
end

---Bridge historical-new `gd` through a deterministically mapped real current file.
---@param buf integer
---@param line integer
---@param column? integer
---@param metadata? { root?: string, path?: string, current_path?: string, column?: integer, open?: fun(path: string, position: table), definition?: fun(buf: integer, line: integer, column: integer), lsp_ready?: fun(buf: integer): boolean, lsp_timeout?: fun(), defer?: fun(callback: function, delay: integer) }
---@return boolean?
---@return string? err
function M.goto_definition(buf, line, column, metadata)
	if type(column) == "table" and metadata == nil then
		metadata = column
		column = nil
	end
	local buffer_role = role(buf)
	if buffer_role == "old" or buffer_role == "panel" then
		return nil, "LSP is disabled for historical review content"
	end
	if buffer_role ~= "snapshot" then
		return nil, "definition bridging requires a historical-new snapshot"
	end
	metadata = metadata or metadata_by_buffer[buf] or {}
	local root = metadata.root
	local relative = metadata.current_path or metadata.path
	if type(root) ~= "string" or type(relative) ~= "string" then
		return nil, "the review snapshot has no current source target"
	end
	local path, resolved_or_err = repo.resolve_relative(root, relative)
	if not path then
		return nil, "current source is unavailable: " .. tostring(resolved_or_err)
	end
	local current_buf = find_buffer(path)
	if vim.bo[current_buf].modified then
		return nil, "current source has unsaved changes"
	end
	local mapped, map_err = M.map_line(buf, current_buf, line)
	if not mapped then
		return nil, map_err
	end
	local target_column = column or metadata.column or 1
	local definition = metadata.definition or (metadata.navigation and metadata.navigation.definition_at)
	if type(definition) ~= "function" then
		return nil, "current-source definition navigation is unavailable"
	end
	local open = metadata.open or editor.open_file_in_tab
	open(path, { lnum = mapped, col = target_column })
	wait_for_lsp(current_buf, metadata, "textDocument/definition", function()
		if not valid_buffer(buf) or role(buf) ~= "snapshot" or not valid_buffer(current_buf) then
			return
		end
		if vim.bo[current_buf].modified then
			vim.notify("Current source changed while waiting for LSP", vim.log.levels.WARN, { title = "Review" })
			return
		end
		local current_line = M.map_line(buf, current_buf, line)
		if current_line ~= mapped then
			vim.notify(
				"Current source mapping changed while waiting for LSP",
				vim.log.levels.WARN,
				{ title = "Review" }
			)
			return
		end
		definition(current_buf, current_line, target_column)
	end)
	return true
end

---Release projection-owned mappings, diagnostic state, and metadata.
---@param buf integer
function M.clear(buf)
	if not stop_diagnostic_mirror(buf) then
		reset_mirrored_diagnostics(buf)
	end
	metadata_by_buffer[buf] = nil
	if valid_buffer(buf) and role(buf) == "unified" then
		install_guard_mapping(buf)
	end
end

---Install the defensive racing-attach guard once.
function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	local group = vim.api.nvim_create_augroup("NvimReviewLspGuard", { clear = true })
	vim.api.nvim_create_autocmd("LspAttach", {
		group = group,
		callback = function(args)
			if not M.blocked(args.buf) then
				return
			end
			M.enforce_blocked(args.buf, args.data and args.data.client_id or nil)
			vim.schedule(function()
				M.enforce_blocked(args.buf)
			end)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			if metadata_by_buffer[args.buf] ~= nil or mirrors_by_buffer[args.buf] ~= nil then
				M.clear(args.buf)
			end
		end,
	})
end

M._build_line_maps = build_line_maps
M._diagnostic_namespace = DIAGNOSTIC_NAMESPACE
M._metadata = metadata_by_buffer
M._mirrors = mirrors_by_buffer
M._role = role

return M
