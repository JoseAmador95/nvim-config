-- VSCode-Neovim injects this module in the extension host. Headless profile
-- validation supplies a recording double so the same init path can run
-- without pretending that a terminal Neovim process is VSCode itself.
local M = { calls = {} }

local function record(method, action, options)
	M.calls[#M.calls + 1] = {
		method = method,
		action = action,
		options = options,
	}
end

function M.call(action, options)
	record("call", action, options)
end

function M.action(action, options)
	record("action", action, options)
end

setmetatable(M, {
	__index = function(_, method)
		return function(...)
			record(method, ...)
		end
	end,
})

package.preload["vscode"] = function()
	return M
end
package.loaded["vscode"] = M

return M
