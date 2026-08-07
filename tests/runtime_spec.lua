vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

test("generation runner cancels stale work and starts only the latest pending request", function()
	local callbacks = {}
	local started = {}
	local killed = 0
	local delivered = {}
	local runner = require("config.async_runner").new({
		spawn = function(command, _, callback)
			started[#started + 1] = command[1]
			callbacks[command[1]] = callback
			return {
				kill = function()
					killed = killed + 1
				end,
			}
		end,
		schedule = function(callback)
			callback()
		end,
	})
	local function request(name)
		runner:request({
			command = { name },
			on_result = function()
				delivered[#delivered + 1] = name
			end,
		})
	end

	request("old")
	request("discarded")
	request("latest")
	equal({ "old" }, started, "requests overlapped")
	equal(1, killed, "active process cancellation count")
	callbacks.old({ code = 143 })
	equal({ "old", "latest" }, started, "pending requests were not coalesced")
	callbacks.latest({ code = 0 })
	equal({ "latest" }, delivered, "stale result was delivered")

	request("closed")
	runner:close()
	callbacks.closed({ code = 0 })
	equal({ "latest" }, delivered, "closed runner delivered a callback")
end)

test("diagram runtime modules load independently of the full config", function()
	for _, module in ipairs({
		"config.diagram_cache",
		"config.diagram",
		"config.mermaid_preview",
		"config.plantuml_preview",
		"config.plantuml_ascii",
	}) do
		local ok, result = pcall(require, module)
		assert(ok and type(result) == "table", module .. " failed to load: " .. tostring(result))
	end
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("runtime_spec: %d tests passed", count))
vim.cmd("quitall!")
