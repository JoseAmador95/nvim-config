vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
vim.env.NVIM_APPNAME = "nvimpager"

local pager = require("config.pager")
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

local function buffer(lines)
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

test("bounded streaming strips CSI OSC and DCS while preserving buffer state", function()
	local buf = buffer({
		"plain \27[31mred\27[0m",
		"OSC \27]8;;https://example.test\7link\27]8;;\27\\ end",
		"DCS \27Pprivate payload\27\\ done",
	})
	vim.bo[buf].modified = true
	vim.bo[buf].modifiable = false
	assert(pager.strip_ansi(buf))
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"plain red",
		"OSC link end",
		"DCS  done",
	}))
	assert(vim.bo[buf].modifiable == false and vim.bo[buf].modified == true)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("64 MiB boundary is accepted and oversize aborts before materialization", function()
	local buf = buffer({ "plain" })
	local original_offset = vim.api.nvim_buf_get_offset
	local original_get_text = vim.api.nvim_buf_get_text
	local original_get_lines = vim.api.nvim_buf_get_lines
	local measurements = 0
	vim.api.nvim_buf_get_offset = function(target, index)
		if target == buf and index == 1 then
			measurements = measurements + 1
			if measurements == 1 then
				return pager.MAX_STRIP_BYTES
			end
		end
		return original_offset(target, index)
	end
	vim.api.nvim_buf_get_lines = function()
		error("strip_ansi must not materialize through get_lines")
	end
	local ok, result, err = pcall(pager.strip_ansi, buf)
	vim.api.nvim_buf_get_offset = original_offset
	vim.api.nvim_buf_get_lines = original_get_lines
	assert(ok and result, err)

	local text_called = false
	vim.api.nvim_buf_get_offset = function(target, index)
		if target == buf and index == 1 then
			return pager.MAX_STRIP_BYTES + 1
		end
		return original_offset(target, index)
	end
	vim.api.nvim_buf_get_text = function(...)
		text_called = true
		return original_get_text(...)
	end
	result, err = pager.strip_ansi(buf)
	vim.api.nvim_buf_get_offset = original_offset
	vim.api.nvim_buf_get_text = original_get_text
	assert(result == nil and err:find("exceed", 1, true))
	assert(not text_called, "oversize buffer was read before rejection")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("set_lines failure restores modifiable and modified exactly", function()
	local buf = buffer({ "\27[31mred\27[0m" })
	vim.bo[buf].modified = false
	vim.bo[buf].modifiable = false
	local original_set_lines = vim.api.nvim_buf_set_lines
	vim.api.nvim_buf_set_lines = function(target, ...)
		if target == buf then
			error("injected set_lines failure")
		end
		return original_set_lines(target, ...)
	end
	local ok, result, err = pcall(pager.strip_ansi, buf)
	vim.api.nvim_buf_set_lines = original_set_lines
	assert(ok and result == nil and err:find("injected set_lines failure", 1, true))
	assert(vim.bo[buf].modifiable == false and vim.bo[buf].modified == false)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

test("pager and viewer filetype callers abort when stripping fails", function()
	local buf = buffer({ "raw" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	local original_strip = pager.strip_ansi
	local original_notify = vim.notify
	vim.notify = function() end
	pager.strip_ansi = function()
		return nil, "injected strip failure"
	end
	local applied, apply_err = pager._apply_filetype(win, "lua")
	assert(applied == nil and apply_err == "injected strip failure")
	assert(vim.bo[buf].filetype == "")

	require("config.viewer_commands")
	assert(vim.fn.exists(":JsonTree") == 0 and vim.fn.exists(":JqxList") == 0)
	local name = vim.api.nvim_buf_get_name(buf)
	vim.cmd("SetFileType python")
	assert(vim.bo[buf].filetype == "" and vim.api.nvim_buf_get_name(buf) == name)
	pager.strip_ansi = original_strip
	vim.notify = original_notify
	vim.api.nvim_buf_delete(buf, { force = true })
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end
print(("pager_spec: %d tests passed"):format(count))
