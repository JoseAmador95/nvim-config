-- A disposable structural viewer, isolated from canonical review coordinates.
local adapter = require("native_review.dependencies").get("structural_diff")
local lsp = require("native_review.lsp")

local M = {}
local active

-- Only SGR is passed to the virtual terminal. Source text cannot issue terminal
-- commands (including OSC clipboard writes, hyperlinks, or cursor movement).
local function safe_output(output)
	local parts, first = {}, 1
	local function text(value)
		parts[#parts + 1] = value:gsub("[%z\1-\8\11-\31\127]", "")
	end
	while first <= #output do
		local escape = output:find("\27", first, true)
		if not escape then
			text(output:sub(first))
			break
		end
		text(output:sub(first, escape - 1))
		local sequence = output:match("^\27%[[0-?]*[ -/]*[@-~]", escape)
		if sequence then
			if sequence:match("^\27%[[%d;]*m$") then
				parts[#parts + 1] = sequence
			end
			first = escape + #sequence
		elseif output:sub(escape + 1, escape + 1) == "]" then
			local bell = output:find("\7", escape + 2, true)
			local terminator = output:find("\27\\", escape + 2, true)
			if bell and (not terminator or bell < terminator) then
				first = bell + 1
			else
				first = terminator and terminator + 2 or #output + 1
			end
		else
			first = escape + 1
		end
	end
	return table.concat(parts)
end

function M.close()
	local view = active
	if not view then
		return
	end
	active = nil
	if view.cancel then
		pcall(view.cancel)
	end
	if view.group then
		pcall(vim.api.nvim_del_augroup_by_id, view.group)
	end
	if vim.api.nvim_win_is_valid(view.win) then
		pcall(vim.api.nvim_win_close, view.win, true)
	end
	if vim.api.nvim_buf_is_valid(view.buf) then
		lsp.clear(view.buf)
		pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
	end
	if vim.api.nvim_win_is_valid(view.origin) then
		pcall(vim.api.nvim_set_current_win, view.origin)
	end
end

---Render only a copy of the frozen entry; never expose source/comment mappings.
---@param entry table
---@param valid function Owner generation and frozen entry validity predicate.
---@return boolean? opened
---@return string? err
function M.open(entry, valid)
	if entry.binary or entry.metadata_only then
		return nil, "Structural diff requires a text change"
	end
	M.close()
	local width = math.max(1, math.floor((vim.o.columns - 4) * 0.9))
	local height = math.max(1, math.floor((vim.o.lines - vim.o.cmdheight - 4) * 0.85))
	local view = { origin = vim.api.nvim_get_current_win(), buf = vim.api.nvim_create_buf(false, true) }
	lsp.mark(view.buf, "panel")
	vim.bo[view.buf].bufhidden = "wipe"
	vim.bo[view.buf].filetype = "reviewstructural"
	vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, { "Computing structural diff…" })
	vim.bo[view.buf].modifiable = false
	view.win = vim.api.nvim_open_win(view.buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		style = "minimal",
		border = "rounded",
		title = " Structural diff · q / Esc to close ",
		title_pos = "center",
	})
	active = view
	vim.wo[view.win].wrap = false
	vim.keymap.set({ "n", "t" }, "q", M.close, { buffer = view.buf, silent = true })
	vim.keymap.set({ "n", "t" }, "<Esc>", M.close, { buffer = view.buf, silent = true })
	view.group = vim.api.nvim_create_augroup("NativeReviewStructural" .. view.buf, { clear = true })
	vim.api.nvim_create_autocmd({ "BufWipeout", "WinClosed" }, {
		group = view.group,
		callback = function(event)
			if event.buf == view.buf or tonumber(event.match) == view.win then
				M.close()
			end
		end,
	})
	local delivered = false
	local function completed(output, err)
		if delivered then
			return
		end
		delivered = true
		vim.schedule(function()
			if active ~= view then
				return
			end
			if not valid() or not vim.api.nvim_win_is_valid(view.win) or not vim.api.nvim_buf_is_valid(view.buf) then
				M.close()
				return
			end
			if err or type(output) ~= "string" then
				M.close()
				vim.notify(
					tostring(err or "Structural diff returned no output"),
					vim.log.levels.WARN,
					{ title = "Review" }
				)
				return
			end
			vim.bo[view.buf].modifiable = true
			vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, {})
			vim.bo[view.buf].scrollback = 100000
			local channel = vim.api.nvim_open_term(view.buf, { on_input = function() end })
			vim.api.nvim_chan_send(channel, safe_output(output))
			vim.bo[view.buf].modifiable = false
			vim.api.nvim_win_set_cursor(view.win, { 1, 0 })
			vim.api.nvim_win_call(view.win, function()
				vim.cmd("normal! ggzt")
			end)
		end)
	end
	local ok, cancel = pcall(adapter.run, {
		entry = vim.deepcopy(entry),
		width = width,
		background = vim.o.background,
	}, completed)
	if not ok then
		M.close()
		return nil, tostring(cancel)
	end
	view.cancel = type(cancel) == "function" and cancel or nil
	return true
end

return M
