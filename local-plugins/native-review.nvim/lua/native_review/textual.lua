-- Textual display engines keep canonical Git entries immutable.
local projection = require("native_review.projection")
local diff = require("native_review.diff")
local moves = require("native_review.moves")

local M = {}

function M.main(entry)
	local result = { presentation = "native", structural_only = false, relations = {} }
	if entry.metadata_only or entry.binary then
		return result
	end
	local value, err = projection.build(entry)
	if not value then
		return nil, err
	end
	result.relations, result.relations_limited = moves.detect(value)
	return result
end

function M.patience(entry)
	if entry.metadata_only or entry.binary then
		return { fallback_reason = "Binary or metadata-only file" }
	end
	local ok, hunks = pcall(vim.text.diff, entry.old_text, entry.new_text, {
		result_type = "indices",
		algorithm = "patience",
		indent_heuristic = true,
		linematch = 60,
	})
	if not ok then
		return nil, tostring(hunks)
	end
	local visual_entry = vim.tbl_extend("force", {}, entry, { hunks = hunks })
	local value, err = projection.build(visual_entry)
	if not value then
		return nil, err
	end
	local intraline, detail_err = diff.refine(visual_entry)
	if not intraline then
		return nil, detail_err
	end
	local line_changes = { old = {}, new = {} }
	for _, row in ipairs(value.rows) do
		if row.kind == "old" or row.kind == "new" then
			line_changes[row.kind][row.source_line] = true
		end
	end
	local relations, limited = moves.detect(value)
	return {
		presentation = "projected",
		structural_only = false,
		display_hunks = hunks,
		projection = value,
		aligned_lines = projection.alignment(value),
		line_changes = line_changes,
		intraline = intraline,
		relations = relations,
		relations_limited = limited,
	}
end

return M
