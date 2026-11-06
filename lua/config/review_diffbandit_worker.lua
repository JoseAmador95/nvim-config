-- Standalone -l entry point. No editor config or Diffbandit UI is loaded.
package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local diff = require("diffbandit.diff")

local request = vim.json.decode(io.read("*a"))
local hunks, err = diff.compute_hunks(request.old_text, request.new_text, { ignore_whitespace = false })
assert(not err, err)
local result = { hunks = {}, intraline = { old = {}, new = {} } }
local new_lines = vim.split(request.new_text, "\n", { plain = true })
for _, hunk in ipairs(hunks) do
	for _, block in ipairs(hunk.sub_hunks or { hunk }) do
		result.hunks[#result.hunks + 1] = { block.left.start, block.left.count, block.right.start, block.right.count }
	end
	local spans = hunk.inner_spans
	if spans then
		for side, field in pairs({ old = "left", new = "right" }) do
			for line, ranges in pairs(spans[field]) do
				for _, range in ipairs(ranges) do
					result.intraline[side][#result.intraline[side] + 1] = {
						line = line,
						start_col = range[1] - 1,
						end_col = range[2],
					}
				end
			end
		end
		-- Appended tails are kept separate by upstream's renderer, but they
		-- are ordinary NEW byte ranges in the review presentation contract.
		for line, start in pairs(spans.add_start) do
			result.intraline.new[#result.intraline.new + 1] = {
				line = line,
				start_col = start - 1,
				end_col = #new_lines[line],
			}
		end
	end
end
io.write(vim.json.encode(result))
