-- Persist document approvals using the host's owner-only filesystem policy.
local M = {}
local fs = require("config.fs")
local media = require("markdown_view.media")
local STATE_VERSION = 1
local store, store_path_override, store_warned
local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "Markdown images" })
end

local function store_path()
	return store_path_override or vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "markdown-images.json")
end

local function load_store()
	if store then
		return store
	end
	store = { version = STATE_VERSION, documents = {} }
	local path = store_path()
	if not vim.uv.fs_stat(path) then
		return store
	end
	local data, read_err = fs.read_binary(path)
	local ok, decoded = pcall(vim.json.decode, data or "")
	if not data or not ok or type(decoded) ~= "table" or decoded.version ~= STATE_VERSION then
		if not store_warned then
			store_warned = true
			notify(("Ignoring unreadable image approvals at %s: %s"):format(path, tostring(read_err or decoded)))
		end
		return store
	end
	if type(decoded.documents) == "table" then
		for key, value in pairs(decoded.documents) do
			if type(key) == "string" and key:sub(1, 1) == "/" and value == true then
				store.documents[key] = true
			end
		end
	end
	return store
end

local function save_store()
	local path = store_path()
	vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
	local ok, err = fs.write_binary_atomic(path, vim.json.encode(load_store()))
	if not ok then
		notify("Could not save image approvals: " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

M.preferences = {
	get = function(key)
		return load_store().documents[key]
	end,
	set = function(key, value)
		load_store().documents[key] = value
		return save_store()
	end,
}
M.supported = media.supported

-- Test seam: isolate the persisted host store and terminal detection together.
function M._reset(options)
	options = options or {}
	store, store_warned, store_path_override = nil, false, options.state_path
	media._reset(options)
end

return M
