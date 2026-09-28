-- Bounded trailing-whitespace policy with view-preserving cleanup.
local M = {}

local DEFAULT_MAX_BYTES = 4 * 1024 * 1024
local DEFAULT_MAX_LINES = 100000
local HARD_MAX_BYTES = 64 * 1024 * 1024
local HARD_MAX_LINES = 1000000
local TITLE = "Whitespace"

local policy = {
	max_bytes = DEFAULT_MAX_BYTES,
	max_lines = DEFAULT_MAX_LINES,
}

local semantic_filetypes = {
	markdown = true,
	["markdown.mdx"] = true,
	mdx = true,
	gitcommit = true,
	gitrebase = true,
	diff = true,
	patch = true,
	mail = true,
	email = true,
}

local function result(changed, skipped, reason, err)
	return {
		changed = changed,
		skipped = skipped,
		reason = reason,
		error = err,
	}
end

local function save_views(buf)
	local views = {}
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		local ok, view = pcall(vim.api.nvim_win_call, win, function()
			return vim.fn.winsaveview()
		end)
		if ok then
			views[win] = view
		end
	end
	return views
end

local function restore_views(buf, views)
	for win, view in pairs(views) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			pcall(vim.api.nvim_win_call, win, function()
				vim.fn.winrestview(view)
			end)
		end
	end
end

local function eligibility(buf)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return nil, "invalid-buffer"
	end
	if not vim.api.nvim_buf_is_loaded(buf) then
		return nil, "unloaded"
	end
	if vim.bo[buf].buftype ~= "" then
		return nil, "special-buffer"
	end
	if not vim.bo[buf].modifiable then
		return nil, "not-modifiable"
	end
	if vim.b[buf].trim_trailing_whitespace == false then
		return nil, "buffer-opt-out"
	end
	local filetype = vim.bo[buf].filetype
	if semantic_filetypes[filetype] then
		return nil, "semantic-whitespace"
	end
	if vim.bo[buf].binary or vim.b[buf].hex == true or filetype == "xxd" then
		return nil, "binary-or-hex"
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count > policy.max_lines then
		return nil, "line-limit"
	end
	local offset_ok, byte_count = pcall(vim.api.nvim_buf_get_offset, buf, line_count)
	if not offset_ok or type(byte_count) ~= "number" or byte_count < 0 then
		return nil, "size-unavailable"
	end
	if byte_count > policy.max_bytes then
		return nil, "byte-limit"
	end
	return true
end

---Remove incidental trailing spaces and tabs without disturbing window views.
---@param buf integer
---@return { changed: boolean, skipped: boolean, reason: string?, error: string? }
function M.trim(buf)
	local eligible, reason = eligibility(buf)
	if not eligible then
		return result(false, true, reason)
	end

	local before = vim.api.nvim_buf_get_changedtick(buf)
	local views = save_views(buf)
	local ok, err = xpcall(function()
		vim.api.nvim_buf_call(buf, function()
			vim.cmd([[silent keepjumps keeppatterns %s/[ \t]\+$//e]])
		end)
	end, debug.traceback)
	restore_views(buf, views)
	if not ok then
		return result(false, false, "cleanup-error", tostring(err))
	end
	return result(vim.api.nvim_buf_get_changedtick(buf) ~= before, false)
end

function M.setup(opts)
	opts = opts or {}
	for key in pairs(opts) do
		if key ~= "max_bytes" and key ~= "max_lines" then
			error("whitespace setup contains an unknown option: " .. tostring(key))
		end
	end
	local max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES
	local max_lines = opts.max_lines or DEFAULT_MAX_LINES
	if type(max_bytes) ~= "number" or max_bytes % 1 ~= 0 or max_bytes < 1 or max_bytes > HARD_MAX_BYTES then
		error(("whitespace max_bytes must be an integer between 1 and %d"):format(HARD_MAX_BYTES))
	end
	if type(max_lines) ~= "number" or max_lines % 1 ~= 0 or max_lines < 1 or max_lines > HARD_MAX_LINES then
		error(("whitespace max_lines must be an integer between 1 and %d"):format(HARD_MAX_LINES))
	end
	policy = { max_bytes = max_bytes, max_lines = max_lines }
	vim.api.nvim_create_autocmd("BufWritePre", {
		group = vim.api.nvim_create_augroup("trim_whitespace", { clear = true }),
		callback = function(event)
			local outcome = M.trim(event.buf)
			if outcome.error then
				vim.notify(
					"Could not trim trailing whitespace: " .. outcome.error,
					vim.log.levels.ERROR,
					{ title = TITLE }
				)
			end
		end,
	})
	return M
end

function M.status()
	return vim.deepcopy(policy)
end

return M
