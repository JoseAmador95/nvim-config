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

local review = require("config.review")
local round = "12345678-1234-4234-8234-123456789abc"
local root = "/tmp/review fixture"

local function result(overrides)
	local value = { ok = true, command = "start", round = round, repo_root = root }
	for key, item in pairs(overrides or {}) do
		value[key] = item
	end
	return { code = 0, stdout = vim.json.encode(value) .. "\n", stderr = "" }
end

test("ReviewRoundStart uses exact asynchronous non-TTY argv and opens returned UUID", function()
	local captured
	local opened
	review.start(root, {
		system = function(command, options, callback)
			captured = { command = command, options = options }
			callback(result())
			return {}
		end,
		schedule = function(callback)
			callback()
		end,
		open_terminal = function(command, options)
			opened = { command = command, options = options }
		end,
		notify = function(message)
			error(message)
		end,
	})
	assert(vim.deep_equal(captured.command, { review._launcher, "start", "--repo", root }))
	assert(captured.options.text == true and captured.options.pty == nil, "start unexpectedly requested a PTY")
	assert(opened.command:find("open", 1, true) and opened.command:find("--round", 1, true))
	assert(opened.command:find(round, 1, true), "returned round UUID was not selected")
end)

test("malformed, multiple, and nonzero launcher results fail visibly", function()
	for _, failed in ipairs({
		{ code = 0, stdout = "not json", stderr = "" },
		{ code = 0, stdout = "{}\n{}", stderr = "" },
		{ code = 9, stdout = "", stderr = "launcher failed" },
		result({ repo_root = "/other" }),
		result({ round = "not-a-uuid" }),
	}) do
		local notices = {}
		local opened = false
		review.start(root, {
			system = function(_, _, callback)
				callback(failed)
				return {}
			end,
			schedule = function(callback)
				callback()
			end,
			open_terminal = function()
				opened = true
			end,
			notify = function(message, level)
				notices[#notices + 1] = { message, level }
			end,
		})
		assert(not opened and #notices == 1)
		assert(notices[1][2] == vim.log.levels.ERROR)
	end
end)

test("TuicrReview falls back to fail-closed repo selector without cache", function()
	local opened
	review.open("/tmp/uncached review", {
		open_terminal = function(command)
			opened = command
		end,
	})
	assert(opened:find("--repo", 1, true))
	assert(opened:find("/tmp/uncached review", 1, true))
	assert(not opened:find("--round", 1, true))
end)

test("ToggleTerm contract is a reusable 95 percent TUI-safe float", function()
	local options = review._terminal_options("command")
	assert(options.direction == "float" and options.hidden and options.close_on_exit)
	assert(options.float_opts.width() == math.floor(vim.o.columns * 0.95))
	assert(options.float_opts.height() == math.floor(vim.o.lines * 0.95))
	local buf = vim.api.nvim_create_buf(false, true)
	local close_count = 0
	options.on_open({
		bufnr = buf,
		close = function()
			close_count = close_count + 1
		end,
	})
	local maps = vim.api.nvim_buf_get_keymap(buf, "t")
	local found = {}
	for _, map in ipairs(maps) do
		found[map.lhs] = map
	end
	assert(found.j and found.j.rhs == "j" and found.j.nowait == 1)
	local space = found["<Space>"] or found[" "]
	assert(space and (space.rhs == "<Space>" or space.rhs == " ") and space.nowait == 1)
	local hide = found["<C-T>"] or found["<C-t>"]
	assert(hide and type(hide.callback) == "function" and hide.nowait == 1)
	assert(hide.desc == "Hide review terminal")
	hide.callback()
	assert(close_count == 1, "Ctrl-t did not hide the review terminal")
	local normal_hide
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == "<C-T>" or map.lhs == "<C-t>" then
			normal_hide = map
		end
	end
	assert(normal_hide and type(normal_hide.callback) == "function")
	vim.api.nvim_buf_delete(buf, { force = true })
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_spec: %d tests passed", count))
vim.cmd("quitall!")
