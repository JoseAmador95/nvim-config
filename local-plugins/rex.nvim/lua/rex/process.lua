-- A bounded argv-only CLI request. No client/socket protocol lives here.
local M = {}
local uv = vim.uv
local MAX_STDOUT = 1024 * 1024
local MAX_STDERR = 8192

function M.run(config, args, callback)
	local argv = { config.bin, "--autostart=false", "--timeout=" .. config.timeout_ms .. "ms" }
	vim.list_extend(argv, args)
	local output, errors = {}, {}
	local output_size, error_size = 0, 0
	local child, timer, settled, kill_requested
	local function kill()
		kill_requested = true
		if child then
			pcall(child.kill, child, 9)
		end
	end
	local function finish(err, value)
		if settled then
			return
		end
		settled = true
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		config.schedule(function()
			callback(err, value)
		end)
	end
	local function stream(stderr)
		return function(err, data)
			if settled then
				return
			end
			if err then
				kill()
				finish("Rex output read failed")
			elseif data then
				local size = (stderr and error_size or output_size) + #data
				if size > (stderr and MAX_STDERR or MAX_STDOUT) then
					kill()
					finish("Rex output exceeded its size limit")
				elseif stderr then
					error_size = size
					errors[#errors + 1] = data
				else
					output_size = size
					output[#output + 1] = data
				end
			end
		end
	end
	local ok, result = pcall(config.system, argv, {
		text = true,
		timeout = config.timeout_ms,
		stdin = false,
		stdout = stream(false),
		stderr = stream(true),
	}, function(result)
		if settled then
			return
		end
		if result.code ~= 0 then
			local detail = table.concat(errors):gsub("%c", " "):sub(1, 512)
			finish("Rex command failed (" .. tostring(result.code) .. ")" .. (detail ~= "" and ": " .. detail or ""))
		else
			finish(nil, table.concat(output))
		end
	end)
	if not ok then
		finish("Rex could not start: " .. tostring(result):sub(1, 512))
	else
		child = result
		if kill_requested then
			kill()
		end
		if not settled then
			timer = uv.new_timer()
			timer:start(config.timeout_ms, 0, function()
				kill()
				finish("Rex request timed out")
			end)
		end
	end
	return {
		cancel = function()
			if not settled then
				kill()
				finish("Rex request cancelled")
			end
		end,
	}
end

return M
