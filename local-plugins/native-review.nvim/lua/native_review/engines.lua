-- Engines interpret frozen sources; they never own Git identities or anchors.
local dependencies = require("native_review.dependencies")
local difftastic = require("native_review.difftastic")
local structural = dependencies.get("structural_diff")

local M = {}
local registry = {}

function M.register(id, engine)
	assert(type(id) == "string" and id:match("^[a-z][a-z0-9_-]*$") and #id <= 64, "invalid engine id")
	assert(not registry[id], "engine already registered: " .. id)
	assert(type(engine) == "table" and type(engine.prepare) == "function", "engine.prepare is required")
	assert(type(engine.label) == "string" and type(engine.version) == "string", "engine metadata is required")
	assert(
		#engine.version > 0 and #engine.version <= 128 and not engine.version:find("[^ -~]"),
		"invalid engine version"
	)
	registry[id] = { label = engine.label, version = engine.version, prepare = engine.prepare }
end

function M.list()
	local values = {}
	for id, engine in pairs(registry) do
		values[#values + 1] = { id = id, label = engine.label, version = engine.version }
	end
	table.sort(values, function(a, b)
		if a.id == "main" or b.id == "main" then
			return a.id == "main"
		end
		return a.label < b.label
	end)
	return values
end

function M.origin(id)
	local engine = registry[id]
	return engine and { id = id, version = engine.version } or nil
end

function M.prepare(id, entry, callback)
	local engine = registry[id]
	if not engine then
		callback(nil, "Unknown review engine: " .. tostring(id))
		return function() end
	end
	return engine.prepare(entry, function(result, err)
		if result then
			result.selected_engine = id
			result.origin_engine = M.origin(result.fallback_reason and "main" or id)
		end
		callback(result, err)
	end)
end

local runtime = vim.version()
M.register("main", {
	label = "Main",
	version = ("builtin-v1 / Neovim %d.%d.%d"):format(runtime.major, runtime.minor, runtime.patch),
	prepare = function(_, callback)
		-- The presenter owns Main's selected-entry refinement cache.
		callback({})
		return function() end
	end,
})

M.register("difftastic", {
	label = "Difftastic",
	version = "0.71.0",
	prepare = function(entry, callback)
		if type(structural.analyze) ~= "function" then
			callback(nil, "Difftastic is unavailable; run :NvimConfigToolsInstall difftastic")
			return function() end
		end
		if entry.metadata_only then
			callback({ fallback_reason = "Binary or metadata-only file" })
			return function() end
		end
		return structural.analyze({ entry = entry }, function(output, err)
			if not output then
				callback(nil, err)
				return
			end
			local ok, decoded = pcall(vim.json.decode, output)
			if not ok then
				callback(nil, "Invalid Difftastic JSON")
				return
			end
			local result, normalize_err = difftastic.normalize(entry, decoded)
			callback(result, normalize_err)
		end)
	end,
})

return M
