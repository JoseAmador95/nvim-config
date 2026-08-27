-- LSP isolation and conservative source bridging for native review buffers.
local M = {}

local editor = require("config.editor")
local repo = require("config.repo")

local BLOCKED = { old = true, snapshot = true, panel = true }
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
local metadata_by_buffer = {}
local setup_done = false

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

local function install_guard_mapping(buf)
	if not valid_buffer(buf) or not BLOCKED[role(buf)] then
		return
	end
	clear_navigation_mappings(buf)
	for _, mapping in ipairs(LSP_NAVIGATION_MAPPINGS) do
		vim.keymap.set(mapping[1], mapping[2], function() end, {
			buffer = buf,
			silent = true,
			desc = "Historical review buffer has no LSP",
		})
	end
	local buffer_role = role(buf)
	local metadata = metadata_by_buffer[buf] or {}
	if buffer_role == "snapshot" and metadata.bridge ~= false then
		vim.keymap.set("n", "gd", function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			local ok, err = M.goto_definition(buf, cursor[1], cursor[2] + 1, metadata_by_buffer[buf])
			if not ok and err then
				vim.notify(err, vim.log.levels.INFO, { title = "Review" })
			end
		end, { buffer = buf, silent = true, desc = "Review definition in current source" })
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

local function diff_text(source)
	local lines, err = source_lines(source)
	if not lines then
		return nil, err
	end
	return table.concat(lines, "\n") .. "\n"
end

---Mark a buffer before setting its filetype so native LSP root discovery can reject it.
---@param buf integer
---@param buffer_role "old"|"snapshot"|"current"|"panel"
---@param metadata? table
---@return boolean
function M.mark(buf, buffer_role, metadata)
	if not valid_buffer(buf) or not ({ old = true, snapshot = true, current = true, panel = true })[buffer_role] then
		return false
	end
	vim.b[buf].nvim_review_role = buffer_role
	metadata_by_buffer[buf] = metadata or {}
	M.enforce_blocked(buf)
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
	local snapshot_text, snapshot_err = diff_text(snapshot)
	if not snapshot_text then
		return nil, snapshot_err
	end
	local current_text, current_err = diff_text(current)
	if not current_text then
		return nil, current_err
	end
	local snapshot_lines = assert(source_lines(snapshot))
	if line > #snapshot_lines then
		return nil, "line is outside the historical snapshot"
	end
	local delta = 0
	for _, hunk in ipairs(vim.diff(snapshot_text, current_text, { result_type = "indices" })) do
		local old_start, old_count, _, new_count = unpack(hunk)
		if old_count == 0 then
			if line > old_start then
				delta = delta + new_count
			end
		elseif line < old_start then
			break
		elseif line < old_start + old_count then
			return nil, "the historical line is inside a changed hunk"
		else
			delta = delta + new_count - old_count
		end
	end
	return line + delta
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

local function wait_for_lsp(buf, metadata, callback)
	local ready = metadata.lsp_ready
		or function(target)
			return #vim.lsp.get_clients({ bufnr = target, method = "textDocument/definition" }) > 0
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
	local open = metadata.open or editor.open_file_in_tab
	open(path, { lnum = mapped, col = target_column })
	local definition = metadata.definition or require("config.lsp_navigation").definition_at
	wait_for_lsp(current_buf, metadata, function()
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
			metadata_by_buffer[args.buf] = nil
		end,
	})
end

M._role = role

return M
