-- Dedicated Trouble source for native review comments.
local Item = require("trouble.item")
local review = require("config.code_review")

local M = {}

local function jump(_, context)
	local item = context.item and context.item.item
	if item and item.review_id then
		if item.review_stale then
			vim.notify("Stale review locations cannot be opened", vim.log.levels.WARN)
			return
		end
		review.jump(item.review_id, true)
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
	local snapshot = review.snapshot(true)
	if not snapshot then
		callback({})
		return
	end
	local items = {}
	for _, comment in ipairs(snapshot.items) do
		local anchor = comment.anchor
		local stale = snapshot.stale or anchor.stale
		if anchor.path then
			local file_level = anchor.kind == "file"
			local range = anchor.kind == "range"
			items[#items + 1] = Item.new({
				source = "review",
				filename = vim.fs.joinpath(snapshot.root, anchor.path),
				pos = { range and anchor.start_line or 1, math.max(0, (anchor.start_column or 1) - 1) },
				end_pos = {
					range and (anchor.end_line or anchor.start_line) or 1,
					math.max(0, (anchor.end_column or 1) - 1),
				},
				severity = (review.comment_type(comment.type) or {}).severity or vim.diagnostic.severity.INFO,
				text = string.format(
					"[%s · %s%s%s] %s",
					comment.type,
					comment.status,
					file_level and " · file" or "",
					stale and " · stale" or "",
					comment.body
				),
				item = { review_id = comment.id, review_stale = stale },
			})
		end
	end
	callback(items)
end

return M
