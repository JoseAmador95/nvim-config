local equal = require("tests.helpers").equal
local T = MiniTest.new_set()
local renders, errors, control = {}, {}, nil
package.loaded.snacks = { setup = function() end }
package.loaded["config.theme"] = { setup = function() end }
package.loaded["config.diagram"] = {
	setup = function()
		return true
	end,
	setup_controls = function(callback)
		control = callback
	end,
	render = function(item, mode, reset)
		renders[#renders + 1] = { item = item, mode = mode, reset = reset }
		return true
	end,
	outdated = function(err)
		errors[#errors + 1] = err
	end,
	teardown = function() end,
}
local viewer = require("config.diagram_rex_viewer")
viewer.setup({ background = "light", config = { max_stage_output_bytes = 64 }, parent_pid = vim.uv.os_getpid() })

T["viewer accepts bounded image bytes and rejects stale or invalid updates"] = function()
	viewer.update({ generation = 1, mode = "svg", reset = true, diagram = { kind = "image", source = "<svg/>" } })
	equal(1, #renders)
	equal("image", renders[1].item.kind)
	assert(renders[1].reset)
	viewer.update({ generation = 1, mode = "svg", diagram = { kind = "image", source = "obsolete" } })
	equal(1, #renders)
	viewer.update({ generation = 2, mode = "svg", diagram = { kind = "image", source = string.rep("x", 65) } })
	equal(1, #renders)
	equal("Invalid diagram update", errors[#errors])
	viewer.update({ generation = 3, error = "Source removed" })
	equal("Source removed", errors[#errors])
end

T["viewer sends controls only over its identified source channel"] = function()
	local original_notify, original_rpc = vim.notify, vim.rpcnotify
	local sent, warnings = {}, {}
	local address = vim.fn.serverstart(vim.fn.tempname())
	local channels = {}
	local function identify(name)
		local channel = vim.fn.sockconnect("pipe", address, { rpc = true })
		assert(channel > 0)
		channels[#channels + 1] = channel
		original_rpc(channel, "nvim_set_client_info", name, {}, "remote", {}, {})
		local peer
		assert(
			vim.wait(1000, function()
				for _, info in ipairs(vim.api.nvim_list_chans()) do
					if info.client and info.client.name == name then
						peer = info.id
						return true
					end
				end
			end),
			"RPC peer did not identify itself"
		)
		return peer
	end
	vim.notify = function(message)
		warnings[#warnings + 1] = message
	end
	vim.rpcnotify = function(channel, method, code, arguments)
		sent[#sent + 1] = { channel = channel, method = method, code = code, arguments = arguments }
	end
	local ok, err = xpcall(function()
		control("hide")
		equal(0, #sent)
		assert(#warnings == 1)
		local source = identify("nvim-rex-diagram-source")
		identify("inspector")
		control("hide")
		control("layout", "right")
		equal(source, sent[1].channel)
		equal(source, sent[2].channel)
		equal("nvim_exec_lua", sent[1].method)
		equal({ "hide" }, sent[1].arguments)
		equal({ "layout", "right" }, sent[2].arguments)
		local called
		package.loaded["config.diagram_rex"] = {
			layout = function(value)
				called = value
			end,
		}
		assert(loadstring(sent[2].code))(unpack(sent[2].arguments))
		equal("right", called)
	end, debug.traceback)
	vim.notify, vim.rpcnotify = original_notify, original_rpc
	for _, channel in ipairs(channels) do
		vim.fn.chanclose(channel)
	end
	vim.fn.serverstop(address)
	assert(ok, err)
end

T.hooks = {
	post_once = function()
		vim.api.nvim_exec_autocmds("VimLeavePre", {})
	end,
}
return T
