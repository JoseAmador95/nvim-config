-- lua/config/obsidian_vaults.lua
-- Reads the list of Obsidian vaults from ~/.nvim.config (a small owner-defined
-- YAML: a sequence of maps with name/path). Neovim ships no YAML parser, so
-- this handles just that minimal subset. Missing file -> empty list (no error).

local M = {}

local CONFIG_PATH = vim.fn.expand("~/.nvim.config")

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unquote(s)
	return (s:gsub('^["\']', ""):gsub('["\']$', ""))
end

function M.read(path)
	path = path or CONFIG_PATH
	local f = io.open(path, "r")
	if not f then
		return {}
	end

	local entries = {}
	local cur = nil
	for line in f:lines() do
		local stripped = trim(line)
		if stripped ~= "" and stripped:sub(1, 1) ~= "#" then
			local item = stripped:match("^%-%s*(.*)$")
			if item then
				cur = {}
				entries[#entries + 1] = cur
				stripped = item
			end
			local key, val = stripped:match("^([%w_]+):%s*(.*)$")
			if key and cur then
				cur[key] = unquote(trim(val))
			end
		end
	end
	f:close()

	local vaults = {}
	for _, e in ipairs(entries) do
		if e.name and e.path and e.name ~= "" and e.path ~= "" then
			vaults[#vaults + 1] = {
				name = e.name,
				path = vim.fn.expand(e.path),
			}
		end
	end
	return vaults
end

return M
