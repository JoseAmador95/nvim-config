vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local original_root = vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT
local fixture = vim.fn.tempname()
assert(vim.fn.mkdir(fixture, "p") == 1)
vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT = fixture
package.loaded["config.tool_paths"] = nil
package.loaded["config.tool_state"] = nil
local state = require("config.tool_state")

test("inspection is read-only and automatic claims are exact one-shots", function()
	local record, reason = state.inspect("demo", "1.0.0")
	assert(record == nil and reason == "absent")
	assert(vim.uv.fs_stat(state.root()) == nil, "inspection created the state directory")

	local claim = assert(state.claim_auto("demo", "1.0.0"))
	assert(claim.identity == "demo@1.0.0")
	local root_stat = assert(vim.uv.fs_stat(state.root()))
	local record_stat = assert(vim.uv.fs_stat(claim.path))
	assert(root_stat.mode % 512 == 448, "state directory is not 0700")
	assert(record_stat.mode % 512 == 384, "state record is not 0600")
	assert(state.claim_auto("demo", "1.0.0") == nil, "second automatic claim succeeded")
	assert(state.transition(claim, "installing"))
	assert(state.finish(claim, false, "download-failed"))
	assert(state.inspect("demo", "1.0.0").status == "failed")
	assert(state.claim_auto("demo", "1.0.0") == nil, "failed pin retried automatically")
	assert(state.claim_auto("demo", "2.0.0"), "new pin was not claimable")
end)

test("empty and corrupt records consume automatic attempts and fail closed manually", function()
	local root = state.root()
	assert(vim.fn.writefile({}, vim.fs.joinpath(root, "empty@1.json")) == 0)
	local inspected, reason = state.inspect("empty", "1")
	assert(inspected == nil and reason == "corrupt")
	assert(state.claim_auto("empty", "1") == nil)
	assert(state.claim_manual("empty", "1") == nil)

	assert(vim.fn.writefile({ "not json" }, vim.fs.joinpath(root, "broken@1.json")) == 0)
	inspected, reason = state.inspect("broken", "1")
	assert(inspected == nil and reason == "corrupt")
	assert(state.claim_auto("broken", "1") == nil)
	assert(state.claim_manual("broken", "1") == nil)
end)

test("manual retries use an exclusive lifetime lock", function()
	local fresh = assert(state.claim_manual("fresh", "1"))
	assert(state.claim_auto("fresh", "1") == nil, "automatic claim raced an absent-record manual claim")
	assert(state.finish(fresh, true))

	local auto = assert(state.claim_auto("retry", "1"))
	assert(state.finish(auto, true))
	local manual = assert(state.claim_manual("retry", "1"))
	assert(state.inspect("retry", "1").status == "claimed")
	local competing, reason = state.claim_manual("retry", "1")
	assert(competing == nil and reason == "locked")
	assert(state.transition(manual, "installing"))
	assert(state.finish(manual, false, "install-failed"))
	assert(state.claim_manual("retry", "1"), "completed manual attempt left a stale lock")
end)

test("manual retry reclaims only an interrupted attempt whose owner is gone", function()
	local interrupted = assert(state.claim_auto("interrupted", "1"))
	assert(state.transition(interrupted, "installing"))
	local live, live_reason = state.claim_manual("interrupted", "1")
	assert(live == nil and live_reason == "installing", "manual retry stole a live automatic attempt")

	local record = assert(state.inspect("interrupted", "1"))
	record.pid = 2147483647
	assert(vim.fn.writefile({ vim.json.encode(record) }, interrupted.path) == 0)
	local recovered, recovered_reason = state.claim_manual("interrupted", "1")
	assert(recovered, "manual retry did not recover a dead owner: " .. tostring(recovered_reason))
	assert(state.inspect("interrupted", "1").status == "claimed")
	assert(state.finish(recovered, true))
end)

test("unwritable state roots fail closed", function()
	local blocked = vim.fs.joinpath(fixture, "blocked")
	assert(vim.fn.writefile({ "file" }, blocked) == 0)
	vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT = blocked
	package.loaded["config.tool_paths"] = nil
	package.loaded["config.tool_state"] = nil
	local blocked_state = require("config.tool_state")
	local claim = blocked_state.claim_auto("demo", "1")
	assert(claim == nil, "claim succeeded below a regular file")
	assert(vim.uv.fs_stat(blocked_state.root()) == nil)
end)

vim.env.NVIM_CONFIG_PRIMARY_STATE_ROOT = original_root
package.loaded["config.tool_paths"] = nil
package.loaded["config.tool_state"] = nil
vim.fn.delete(fixture, "rf")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("tool_state_spec: %d tests passed", count))
vim.cmd("quitall!")
