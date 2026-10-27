local store = require("config.usage_store")
local equal = require("tests.helpers").equal
local paths = {}
local T = MiniTest.new_set({
	hooks = {
		post_once = function()
			for _, path in ipairs(paths) do
				vim.fn.delete(path, "rf")
			end
		end,
	},
})

local function open(profile, clock)
	local directory = vim.fn.tempname()
	paths[#paths + 1] = directory
	local path = directory .. "/usage.sqlite3"
	return assert(store.open(path, profile or "editor", clock)), path
end

T["daily aggregates persist and retries do not double count"] = function()
	local now = os.time({ year = 2026, month = 10, day = 25, hour = 12 })
	local db, path = open("editor", function()
		return now
	end)
	db:record("mapping", "quote:'<leader>q", "n", 0)
	db:record("mapping", "quote:'<leader>q", "n")
	assert(db:flush(true))
	-- Force a retry of the same already-committed snapshot, as after a lost acknowledgement.
	db.saved = 0
	assert(db:flush(true))
	now = now + 86400
	db:record("mapping", "quote:'<leader>q", "n")
	db:record("mapping", "unused", "x", 0)
	local rows = assert(db:report("all", 0))
	equal(2, rows[1].uses)
	equal(2, rows[1].days)
	equal("quote:'<leader>q", rows[1].action)
	equal(0, rows[2].uses)
	equal(0, rows[2].days)
	local reopened = assert(store.open(path, "pager"))
	equal(rows, assert(reopened:report("all", 0)))
	equal("rw-------", vim.fn.getfperm(path))
	equal("rwx------", vim.fn.getfperm(vim.fs.dirname(path)))
end

T["concurrent writers and records arriving during a flush are retained"] = function()
	local first, path = open()
	local second = assert(store.open(path, "editor"))
	first:record("mapping", "shared", "n")
	second:record("mapping", "shared", "n")
	assert(first:flush(false))
	assert(second:flush(false))
	first:record("mapping", "shared", "n")
	assert(second:flush(true))
	local rows = assert(first:report("mapping", 30))
	equal(3, rows[1].uses)
	equal(1, rows[1].days)
end

T["period filters keep registered zero rows and count only days in the period"] = function()
	local today = os.time()
	local now = today - 2 * 86400
	local db = open("editor", function()
		return now
	end)
	db:record("mapping", "unused", "n", 0)
	db:record("mapping", "older", "n")
	db:record("mapping", "active", "n")
	now = today
	db:record("mapping", "active", "n")
	local rows = assert(db:report("mapping", 1))
	equal(3, #rows)
	equal("active", rows[1].action)
	equal(1, rows[1].uses)
	equal(1, rows[1].days)
	equal(0, rows[2].uses)
	equal(0, rows[2].days)
	equal(today - 2 * 86400, rows[2].last_used)
	equal(0, rows[3].uses)
	equal(0, rows[3].last_used)
end

T["reset prevents another editor's old counters from returning"] = function()
	local first, path = open()
	local second = assert(store.open(path, "pager"))
	first:record("palette", "file.new", "-")
	second:record("palette", "file.new", "-")
	assert(first:reset())
	assert(second:flush(true))
	second:record("palette", "file.new", "-")
	local rows = assert(second:report("all", 0))
	equal(1, rows[1].uses)
	equal("pager", rows[1].profile)
end

T["failed writes retain counters for an explicit retry"] = function()
	local db = open()
	db:record("palette", "file.new", "-")
	local sqlite = db.sqlite
	db.sqlite = "/no/such/sqlite3"
	assert(not db:flush(false))
	db.sqlite = sqlite
	equal(1, assert(db:report("all", 0))[1].uses)
end

T["private storage rejects symlinks and permissive existing files"] = function()
	local _, path = open()
	assert(vim.uv.fs_chmod(path, 420))
	local db, err = store.open(path, "editor")
	assert(not db and err:find("owner%-only"))
	assert(vim.uv.fs_chmod(path, 384))
	local link = vim.fs.dirname(path) .. "/linked.sqlite3"
	assert(vim.uv.fs_symlink(path, link))
	db, err = store.open(link, "editor")
	assert(not db and err:find("regular file"))
end

return T
