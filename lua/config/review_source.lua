local M = {}

local links = {}

local function valid_tab(tabpage)
	return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function copy_link(link)
	if not link then
		return nil
	end
	return {
		workspace = link.workspace,
		target = vim.deepcopy(link.target),
	}
end

---Remove source links whose tabpages no longer exist.
---@return integer removed
function M.prune()
	local removed = 0
	for tabpage in pairs(links) do
		if not valid_tab(tabpage) then
			links[tabpage] = nil
			removed = removed + 1
		end
	end
	return removed
end

---Return the explicit review lineage attached to a source tab.
---@param tabpage integer
---@return table?
function M.get(tabpage)
	M.prune()
	return copy_link(links[tabpage])
end

---Attach an exact review return target to a source tab.
---@param tabpage integer
---@param workspace table
---@param target table
---@return boolean
function M.set(tabpage, workspace, target)
	M.prune()
	if not valid_tab(tabpage) or type(workspace) ~= "table" or type(target) ~= "table" then
		return false
	end
	links[tabpage] = {
		workspace = workspace,
		target = vim.deepcopy(target),
	}
	return true
end

---Clear the review lineage attached to a source tab.
---@param tabpage integer
function M.clear(tabpage)
	links[tabpage] = nil
end

---Move every source link to a replacement workspace without changing its target.
---@param previous table
---@param replacement table
---@return integer migrated
function M.migrate(previous, replacement)
	M.prune()
	local migrated = 0
	for _, link in pairs(links) do
		if link.workspace == previous then
			link.workspace = replacement
			migrated = migrated + 1
		end
	end
	return migrated
end

---Clear every source link owned by a review workspace.
---@param workspace table
---@return integer cleared
function M.clear_workspace(workspace)
	M.prune()
	local cleared = 0
	for tabpage, link in pairs(links) do
		if link.workspace == workspace then
			links[tabpage] = nil
			cleared = cleared + 1
		end
	end
	return cleared
end

return M
