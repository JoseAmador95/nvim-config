-- Dedicated Trouble source for native review comments.
local Item = require("trouble.item")

local M = {}

local SEVERITY = {
	issue = vim.diagnostic.severity.ERROR,
	suggestion = vim.diagnostic.severity.WARN,
	rationale = vim.diagnostic.severity.INFO,
	question = vim.diagnostic.severity.INFO,
	pedantic = vim.diagnostic.severity.HINT,
	praise = vim.diagnostic.severity.HINT,
}

local function jump(_, context)
	local item = context.item and context.item.item
	if item and item.review_id then
		if item.review_stale then
			vim.notify("Stale review locations cannot be opened", vim.log.levels.WARN)
			return
		end
		require("config.code_review").jump(item.review_id, true)
	end
end

M.config = {
	modes = {
		review = {
			desc = "Comments in the active native code review",
			source = "review",
			groups = {
				{ "filename", format = "{file_icon} {filename} {count}" },
			},
			sort = { "filename", "pos", "severity" },
			format = "{severity_icon} {text:ts} {pos}",
			auto_preview = false,
			keys = {
				["<cr>"] = jump,
				["<2-leftmouse>"] = jump,
				o = jump,
			},
		},
	},
}

---Provide review comments without using quickfix or vim.diagnostic state.
---@param callback function
function M.get(callback)
	local snapshot = require("config.code_review").snapshot(true)
	if not snapshot then
		callback({})
		return
	end
	local items = {}
	for _, review in ipairs(snapshot.items) do
		local anchor = review.anchor
		local stale = snapshot.stale or anchor.stale
		if anchor.path then
			local file_level = anchor.start_line == nil
			items[#items + 1] = Item.new({
				source = "review",
				filename = vim.fs.joinpath(snapshot.root, anchor.path),
				pos = { anchor.start_line or 1, math.max(0, (anchor.start_column or 1) - 1) },
				end_pos = { anchor.end_line or anchor.start_line or 1, math.max(0, (anchor.end_column or 1) - 1) },
				severity = SEVERITY[review.type],
				text = string.format(
					"[%s · %s%s%s] %s",
					review.type,
					review.status,
					file_level and " · file" or "",
					stale and " · stale" or "",
					review.body
				),
				item = { review_id = review.id, review_stale = stale },
			})
		end
	end
	callback(items)
end

return M
