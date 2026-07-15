local M = {}

-- Open the grug-far result under the cursor in a new tab, reusing the shared
-- tab-opening helper (which dedupes to an existing tab for the same file).
function M.open_entry_in_tab(buf)
	buf = buf or 0
	local ok, grug_far = pcall(require, "grug-far")
	if not ok then
		return
	end

	local inst = grug_far.get_instance(buf)
	if not inst then
		return
	end

	local resultsList = require("grug-far.render.resultsList")
	local loc = resultsList.getResultLocationAtCursor(inst._buf, inst._context)
	if not loc or not loc.filename then
		return
	end

	require("config.editor").open_file_in_tab(loc.filename, { lnum = loc.lnum, col = loc.col })
end

return M
