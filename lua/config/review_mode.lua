-- Ordinary-tab lifecycle and exact ownership restoration for native reviews.
local M = {}

local review_lsp = require("config.review_lsp")

local active_buffers = {}
local protected_transients = {}
local option_guard_ready = false
local protection_writes = {}
local WINDOW_OPTIONS = {
	"concealcursor",
	"conceallevel",
	"cursorbind",
	"diff",
	"fillchars",
	"foldenable",
	"foldcolumn",
	"foldlevel",
	"foldmethod",
	"number",
	"numberwidth",
	"relativenumber",
	"scrollbind",
	"signcolumn",
	"statuscolumn",
	"wrap",
	"winbar",
	"winhighlight",
}

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
	return type(tab) == "number" and vim.api.nvim_tabpage_is_valid(tab)
end

local function protect_buffer(buf)
	if protection_writes[buf] then
		return true
	end
	protection_writes[buf] = true
	local ok, err = pcall(function()
		vim.bo[buf].readonly = true
		vim.bo[buf].modifiable = false
	end)
	protection_writes[buf] = nil
	return ok and true or nil, ok and nil or tostring(err)
end

local function enforce_protection(buf)
	local state = active_buffers[buf]
	local enrolled = state and state.enabled and state.enrolled[buf]
	if not enrolled then
		state = protected_transients[buf]
		if not state or not state.protected_transients[buf] then
			return false
		end
	end
	if not valid_buf(buf) then
		return false
	end
	if vim.bo[buf].readonly and not vim.bo[buf].modifiable then
		return true
	end
	return protect_buffer(buf)
end

local function ensure_option_guard()
	if option_guard_ready then
		return
	end
	option_guard_ready = true
	local group = vim.api.nvim_create_augroup("NvimReviewModeProtection", { clear = true })
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = { "modifiable", "readonly" },
		callback = function(event)
			local buf = event.buf ~= 0 and event.buf or vim.api.nvim_get_current_buf()
			local protected, err = enforce_protection(buf)
			if protected == nil then
				vim.notify("Could not protect review buffer: " .. tostring(err), vim.log.levels.ERROR)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			local state = protected_transients[event.buf]
			if state then
				state.protected_transients[event.buf] = nil
				protected_transients[event.buf] = nil
			end
		end,
	})
end

local function local_mapping(buf, lhs)
	if not valid_buf(buf) then
		return nil
	end
	local mapping
	vim.api.nvim_buf_call(buf, function()
		mapping = vim.fn.maparg(lhs, "n", false, true)
	end)
	return type(mapping) == "table" and mapping.buffer == 1 and mapping or nil
end

local function restore_mapping(buf, lhs, mapping)
	pcall(vim.keymap.del, "n", lhs, { buffer = buf })
	if not mapping then
		return
	end
	vim.api.nvim_buf_call(buf, function()
		vim.fn.mapset("n", false, mapping)
	end)
end

local function normal_at(line, command)
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	vim.cmd("silent! normal! " .. command)
end

local function fold_close_line(folds, index)
	local fold = folds[index]
	local line = fold.first
	for child_index = index + 1, #folds do
		local child = folds[child_index]
		if child.level <= fold.level then
			break
		end
		if child.parent == index and not child.closed then
			if line < child.first then
				break
			end
			if line <= child.last then
				line = child.last + 1
			end
		end
	end
	return line <= fold.last and line or fold.first
end

local function apply_fold_states(folds, recreate_manual)
	local foldenable = vim.wo.foldenable
	vim.wo.foldenable = true
	if recreate_manual then
		-- Manual fold definitions are window-local, so an adopted window needs the tree as well as its open state.
		vim.cmd("silent! normal! zE")
		for index = #folds, 1, -1 do
			local fold = folds[index]
			vim.cmd(("silent! %d,%dfold"):format(fold.first, fold.last))
		end
	end
	for _, fold in ipairs(folds) do
		normal_at(fold.first, "zO")
	end
	for index = #folds, 1, -1 do
		local fold = folds[index]
		if fold.closed then
			normal_at(fold_close_line(folds, index), "zc")
		end
	end
	vim.wo.foldenable = foldenable
end

local function capture_navigable_folds()
	local foldenable = vim.wo.foldenable
	vim.wo.foldenable = true
	local folds = {}
	local parents = {}
	local first = 1
	if vim.fn.foldlevel(first) == 0 then
		normal_at(first, "zj")
		first = vim.api.nvim_win_get_cursor(0)[1]
		if vim.fn.foldlevel(first) == 0 then
			first = nil
		end
	end
	while first do
		-- Open each closed fold just long enough for zj to visit any nested folds, then replay every captured state.
		local closed = vim.fn.foldclosed(first) == first
		local last
		if closed then
			last = vim.fn.foldclosedend(first)
		else
			normal_at(first, "]z")
			last = vim.api.nvim_win_get_cursor(0)[1]
		end
		local level = vim.fn.foldlevel(first)
		folds[#folds + 1] = {
			closed = closed,
			first = first,
			last = last,
			level = level,
			parent = parents[level - 1],
		}
		parents[level] = #folds
		for nested = level + 1, #parents do
			parents[nested] = nil
		end
		if closed then
			normal_at(first, "zo")
		end
		normal_at(first, "zj")
		local following = vim.api.nvim_win_get_cursor(0)[1]
		first = following > first and vim.fn.foldlevel(following) > 0 and following or nil
	end
	apply_fold_states(folds, false)
	vim.wo.foldenable = foldenable
	return folds
end

local function manual_fold_tree()
	local folds = {}
	local stack = {}
	local first = 1
	if vim.fn.foldlevel(first) == 0 then
		normal_at(first, "zj")
		first = vim.api.nvim_win_get_cursor(0)[1]
		if vim.fn.foldlevel(first) == 0 then
			return folds
		end
	end
	local line_count = vim.api.nvim_buf_line_count(0)
	-- Manual fold levels are the exact tree projection, including several folds that begin on the same line.
	for line = first, line_count do
		local level = vim.fn.foldlevel(line)
		while #stack > level do
			folds[stack[#stack]].last = line - 1
			table.remove(stack)
		end
		while #stack < level do
			local fold = {
				first = line,
				last = line,
				level = #stack + 1,
				parent = stack[#stack],
			}
			folds[#folds + 1] = fold
			stack[#stack + 1] = #folds
		end
	end
	while #stack > 0 do
		folds[stack[#stack]].last = line_count
		table.remove(stack)
	end
	return folds
end

local function capture_manual_folds()
	local foldenable = vim.wo.foldenable
	vim.wo.foldenable = true
	local folds = manual_fold_tree()
	for _, fold in ipairs(folds) do
		fold.closed = vim.fn.foldclosed(fold.first) == fold.first and vim.fn.foldclosedend(fold.first) == fold.last
		if fold.closed then
			normal_at(fold.first, "zo")
		end
	end
	apply_fold_states(folds, false)
	vim.wo.foldenable = foldenable
	return folds
end

local function capture_window(state, win)
	if not valid_win(win) or state.window_snapshots[win] then
		return
	end
	local options = {}
	for _, name in ipairs(WINDOW_OPTIONS) do
		options[name] = vim.wo[win][name]
	end
	local local_options = {
		fillchars = vim.api.nvim_get_option_value("fillchars", { scope = "local", win = win }),
	}
	local view
	local folds
	vim.api.nvim_win_call(win, function()
		view = vim.fn.winsaveview()
		folds = options.foldmethod == "manual" and capture_manual_folds() or capture_navigable_folds()
		vim.fn.winrestview(view)
	end)
	state.window_snapshots[win] = {
		buf = vim.api.nvim_win_get_buf(win),
		folds = folds,
		local_options = local_options,
		options = options,
		view = view,
	}
end

local function restore_window(state, win)
	local snapshot = state.window_snapshots[win]
	state.window_snapshots[win] = nil
	if not snapshot or not valid_win(win) then
		return
	end
	for name, value in pairs(snapshot.options) do
		if name ~= "fillchars" then
			vim.wo[win][name] = value
		end
	end
	vim.api.nvim_set_option_value("fillchars", snapshot.local_options.fillchars, { scope = "local", win = win })
	if vim.api.nvim_win_get_buf(win) == snapshot.buf then
		vim.api.nvim_win_call(win, function()
			apply_fold_states(snapshot.folds or {}, snapshot.options.foldmethod == "manual")
			if snapshot.view then
				vim.fn.winrestview(snapshot.view)
			end
		end)
	end
end

local function affected_paths(state)
	local paths = {}
	local model = state.workspace and (state.workspace.model or state.workspace.changes)
	for _, entry in ipairs(model and model.entries or {}) do
		if entry.old_path then
			paths[vim.fs.normalize(vim.fs.joinpath(state.workspace.root, entry.old_path))] = true
		end
		if entry.new_path then
			paths[vim.fs.normalize(vim.fs.joinpath(state.workspace.root, entry.new_path))] = true
		end
	end
	return paths
end

local function affected_buffers(state)
	local paths = affected_paths(state)
	local buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if valid_buf(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" then
				local normalized = vim.fs.normalize(vim.uv.fs_realpath(name) or vim.fn.fnamemodify(name, ":p"))
				if paths[normalized] then
					buffers[#buffers + 1] = buf
				end
			end
		end
	end
	return buffers
end

local function buffer_is_affected(state, buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return false
	end
	local normalized = vim.fs.normalize(vim.uv.fs_realpath(name) or vim.fn.fnamemodify(name, ":p"))
	return affected_paths(state)[normalized] == true
end

local function preflight(state, buffers)
	for _, buf in ipairs(buffers) do
		if vim.bo[buf].modified then
			return nil, "affected buffer has unsaved changes: " .. vim.api.nvim_buf_get_name(buf)
		end
		local previous = active_buffers[buf]
		if previous and previous ~= state then
			return nil, "buffer is already enrolled by another review"
		end
	end
	return true
end

local function call_handler(state, name)
	local callback = state.handlers and state.handlers[name]
	if type(callback) == "function" then
		callback(state)
	end
end

local function restore_enrolled(state, buf, record)
	if not valid_buf(buf) then
		active_buffers[buf] = nil
		state.enrolled[buf] = nil
		return
	end
	for lhs, callback in pairs(record.callbacks) do
		local current = local_mapping(buf, lhs)
		if current and current.callback == callback then
			restore_mapping(buf, lhs, record.mappings[lhs])
		end
	end
	if active_buffers[buf] == state then
		active_buffers[buf] = nil
	end
	state.enrolled[buf] = nil
	if vim.bo[buf].readonly == true then
		vim.bo[buf].readonly = record.readonly
	end
	if vim.bo[buf].modifiable == false then
		vim.bo[buf].modifiable = record.modifiable
	end
	if vim.b[buf].nvim_review_role == "current" then
		vim.b[buf].nvim_review_role = record.role
	end
end

---Create review state around the current ordinary tab/window/buffer.
---@param workspace table
---@return table state
function M.new(workspace)
	local win = vim.api.nvim_get_current_win()
	local state = {
		workspace = workspace,
		origin = {
			tab = vim.api.nvim_get_current_tabpage(),
			win = win,
			buf = vim.api.nvim_get_current_buf(),
		},
		enabled = false,
		enrolled = {},
		protected_transients = {},
		auxiliary = {},
		window_snapshots = {},
		handlers = {},
		readonly_is_buffer_global = true,
	}
	capture_window(state, win)
	return state
end

---Protect one presenter-owned scratch buffer without enrolling it as current source.
---@param state table
---@param buf integer
---@return boolean?
---@return string? err
function M.protect_transient(state, buf)
	ensure_option_guard()
	if not valid_buf(buf) then
		return nil, "buffer is no longer valid"
	end
	if active_buffers[buf] then
		return nil, "buffer is already enrolled by a review"
	end
	local previous = protected_transients[buf]
	if previous and previous ~= state then
		return nil, "buffer is already protected by another review"
	end
	state.protected_transients[buf] = true
	protected_transients[buf] = state
	local protected, protect_err = protect_buffer(buf)
	if not protected then
		state.protected_transients[buf] = nil
		protected_transients[buf] = nil
		return nil, protect_err
	end
	return true
end

---Release transient protection ownership without enrolling or restoring the scratch buffer.
---@param state table
---@param buf integer
---@return boolean released
function M.release_transient(state, buf)
	if protected_transients[buf] ~= state then
		return false
	end
	protected_transients[buf] = nil
	state.protected_transients[buf] = nil
	return true
end

---Enroll one real current buffer, applying review-local readonly state and hunk maps.
---@param state table
---@param buf integer
---@return boolean?
---@return string? err
function M.enroll(state, buf)
	ensure_option_guard()
	if not valid_buf(buf) then
		return nil, "buffer is no longer valid"
	end
	if vim.bo[buf].modified then
		return nil, "affected buffer has unsaved changes: " .. vim.api.nvim_buf_get_name(buf)
	end
	if state.enrolled[buf] then
		active_buffers[buf] = state
		return protect_buffer(buf)
	end
	local previous = active_buffers[buf]
	if previous and previous ~= state then
		return nil, "buffer is already enrolled by another review"
	end
	local record = {
		modifiable = vim.bo[buf].modifiable,
		readonly = vim.bo[buf].readonly,
		role = vim.b[buf].nvim_review_role,
		mappings = { ["[h"] = local_mapping(buf, "[h"), ["]h"] = local_mapping(buf, "]h") },
		callbacks = {},
	}
	record.callbacks["[h"] = function()
		call_handler(state, "prev_hunk")
	end
	record.callbacks["]h"] = function()
		call_handler(state, "next_hunk")
	end
	state.enrolled[buf] = record
	active_buffers[buf] = state
	local protected, protect_err = protect_buffer(buf)
	if not protected then
		active_buffers[buf] = nil
		state.enrolled[buf] = nil
		return nil, protect_err
	end
	review_lsp.mark(buf, "current", { workspace = state.workspace })
	vim.keymap.set("n", "[h", record.callbacks["[h"], {
		buffer = buf,
		silent = true,
		desc = "Previous review hunk",
	})
	vim.keymap.set("n", "]h", record.callbacks["]h"], {
		buffer = buf,
		silent = true,
		desc = "Next review hunk",
	})
	return true
end

local function enroll_buffers(state, buffers)
	local ready, ready_err = preflight(state, buffers)
	if not ready then
		return nil, ready_err
	end
	local enrolled = {}
	for _, buf in ipairs(buffers) do
		local already_enrolled = state.enrolled[buf] ~= nil
		local ok, enroll_err = M.enroll(state, buf)
		if not ok then
			for index = #enrolled, 1, -1 do
				local enrolled_buf = enrolled[index]
				restore_enrolled(state, enrolled_buf, state.enrolled[enrolled_buf])
			end
			state.enabled = false
			return nil, enroll_err
		end
		if not already_enrolled then
			enrolled[#enrolled + 1] = buf
		end
	end
	state.enabled = true
	return true
end

---Enroll a newly opened affected buffer while review mode is active.
---@param state table
---@param buf integer
---@return boolean? enrolled False means the buffer does not need enrollment.
---@return string? err
function M.enroll_affected_buffer(state, buf)
	if not state.enabled then
		return false
	end
	if not valid_buf(buf) then
		return nil, "buffer is no longer valid"
	end
	if not buffer_is_affected(state, buf) then
		return false
	end
	local ready, ready_err = preflight(state, { buf })
	if not ready then
		return nil, ready_err
	end
	return M.enroll(state, buf)
end

---Enable ordinary-buffer review mode after refusing all modified affected buffers.
---@param state table
---@return boolean?
---@return string? err
function M.enable(state)
	if state.enabled then
		return true
	end
	if not valid_tab(state.origin.tab) or not valid_win(state.origin.win) then
		return nil, "origin tab or window is no longer valid"
	end
	return enroll_buffers(state, affected_buffers(state))
end

---Track a presenter-created auxiliary window and buffer owned by this state.
---@param state table
---@param kind string
---@param win integer
---@param buf integer
function M.set_auxiliary(state, kind, win, buf)
	state.auxiliary[kind] = { win = win, buf = buf }
end

---Return the active review state for one real current buffer.
---@param buf integer
---@return table?
function M.active_for_buffer(buf)
	local state = active_buffers[buf]
	return state and state.enabled and state or nil
end

local function close_auxiliary(state)
	for kind, item in pairs(state.auxiliary) do
		if valid_win(item.win) and item.win ~= state.origin.win and vim.api.nvim_win_get_buf(item.win) == item.buf then
			vim.api.nvim_win_close(item.win, true)
		end
		if valid_buf(item.buf) and vim.bo[item.buf].buftype == "nofile" and #vim.fn.win_findbuf(item.buf) == 0 then
			pcall(vim.api.nvim_buf_delete, item.buf, { force = true })
		end
		state.auxiliary[kind] = nil
	end
end

---Disable the review and restore only buffers/windows still carrying owned state.
---@param state table
function M.disable(state)
	if type(state.clear_presentation) == "function" then
		state.clear_presentation(state)
	end
	for buf, record in pairs(vim.deepcopy(state.enrolled)) do
		restore_enrolled(state, buf, record)
	end
	for buf in pairs(vim.deepcopy(state.protected_transients)) do
		M.release_transient(state, buf)
	end
	close_auxiliary(state)
	for win in pairs(state.window_snapshots) do
		restore_window(state, win)
	end
	state.enabled = false
	if valid_tab(state.origin.tab) and valid_win(state.origin.win) then
		vim.api.nvim_set_current_tabpage(state.origin.tab)
		vim.api.nvim_set_current_win(state.origin.win)
	end
end

---Temporarily release enrolled real buffers without disturbing presenter windows.
---@param state table
---@return table snapshot
function M.suspend(state)
	local snapshot = { enabled = state.enabled, buffers = {} }
	for buf, record in pairs(vim.deepcopy(state.enrolled)) do
		snapshot.buffers[#snapshot.buffers + 1] = buf
		restore_enrolled(state, buf, record)
	end
	state.enabled = false
	return snapshot
end

---Restore a prior suspend snapshot, atomically reenrolling the currently affected buffers.
---@param state table
---@param snapshot table
---@return boolean?
---@return string? err
function M.restore(state, snapshot)
	if not snapshot or not snapshot.enabled then
		return true
	end
	return enroll_buffers(state, affected_buffers(state))
end

M.capture_window = capture_window
M.enforce_protection = enforce_protection
M.restore_window = restore_window

return M
