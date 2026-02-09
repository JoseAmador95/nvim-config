-- lua/config/tabnames.lua
-- Smart tab titles:
-- 1. Unique filename -> show filename
-- 2. Duplicate filenames -> prepend path until unique
-- 3. If tab has splits -> "A + B"

local M = {}

-- normalize path
local function norm(path)
	return vim.fn.fnamemodify(path, ":p")
end

-- get main-window file of a tab
local function tab_main_file(tab)
	local win = vim.api.nvim_tabpage_get_win(tab)
	local buf = vim.api.nvim_win_get_buf(win)
	return norm(vim.api.nvim_buf_get_name(buf))
end

-- get all windows in a tab to detect splits
local function tab_split_files(tab)
	local wins = vim.api.nvim_tabpage_list_wins(tab)
	local files = {}
	for _, win in ipairs(wins) do
		local buf = vim.api.nvim_win_get_buf(win)
		local name = norm(vim.api.nvim_buf_get_name(buf))
		if name ~= "" then
			table.insert(files, name)
		end
	end
	return files
end

-- return filename-only part
local function fname(path)
	return vim.fn.fnamemodify(path, ":t")
end

-- return path parts
local function split_path(path)
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end
	return parts
end

-- build unique name among duplicates:
local function build_unique(paths)
	local groups = {}
	-- group by filename
	for _, p in ipairs(paths) do
		local base = fname(p)
		groups[base] = groups[base] or {}
		table.insert(groups[base], p)
	end

	local out = {}

	for base, gpaths in pairs(groups) do
		if #gpaths == 1 then
			out[gpaths[1]] = base -- unique
		else
			-- need to disambiguate
			local split = {}
			-- split each path into components
			for _, p in ipairs(gpaths) do
				split[p] = split_path(vim.fn.fnamemodify(p, ":h"))
			end

			local max_depth = 0
			for _, sp in pairs(split) do
				if #sp > max_depth then
					max_depth = #sp
				end
			end

			for _, p in ipairs(gpaths) do
				local sp = split[p]
				local label = base

				-- prepend directories until unique
				for level = #sp, 1, -1 do
					local prefix = sp[level] .. "/" .. label

					-- Check if ANY other file would collide with this prefix
					local ok = true
					for _, q in ipairs(gpaths) do
						if q ~= p then
							local q_sp = split[q]
							local rel = (q_sp[level] and (q_sp[level] .. "/" .. base)) or base
							if rel == prefix then
								ok = false
								break
							end
						end
					end

					label = prefix
					if ok then
						break
					end
				end

				out[p] = label
			end
		end
	end

	return out
end

-- MAIN: compute tab title
function M.tab_title(tab)
	local main = tab_main_file(tab)
	if main == "" then
		return "[No Name]"
	end

	local tabs = vim.api.nvim_list_tabpages()
	local all_main = {}
	for _, t in ipairs(tabs) do
		local mf = tab_main_file(t)
		if mf ~= "" then
			table.insert(all_main, mf)
		end
	end

	local unique = build_unique(all_main)
	local base_label = unique[main] or fname(main)

	-- check splits
	local files = tab_split_files(tab)
	if #files > 1 then
		-- Build list of filenames (not full paths)
		local names = {}
		for _, p in ipairs(files) do
			table.insert(names, fname(p))
		end

		table.sort(names)

		-- Return ONLY "A + B + C", no prefix, no brackets
		return table.concat(names, " + ")
	end

	return base_label
end

return M
