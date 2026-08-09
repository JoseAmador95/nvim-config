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
	assert(vim.deep_equal(opened.command, { review._launcher, "open", "--round", round }))
	assert(opened.options.argv == opened.command, "terminal spec did not preserve argv identity")
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

test("TuicrReview discovers one exact round without opening an ambiguous terminal", function()
	local uncached_root = "/tmp/uncached review"
	local captured
	local opened
	review.open(uncached_root, {
		system = function(command, options, callback)
			captured = { command = command, options = options }
			callback({
				code = 0,
				stdout = vim.json.encode({
					ok = true,
					command = "status",
					round = round,
					repo_root = uncached_root,
				}) .. "\n",
				stderr = "",
			})
			return {}
		end,
		schedule = function(callback)
			callback()
		end,
		open_terminal = function(command)
			opened = command
		end,
	})
	assert(vim.deep_equal(captured.command, { review._launcher, "status", "--repo", uncached_root }))
	assert(captured.options.text == true)
	assert(vim.deep_equal(opened, { review._launcher, "open", "--round", round }))
end)

test("TuicrReview requires an explicit choice when repository rounds are ambiguous", function()
	local uncached_root = "/tmp/ambiguous review"
	local other_round = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	local selected
	local opened
	local commands = {}
	review.open(uncached_root, {
		system = function(command, _, callback)
			commands[#commands + 1] = command
			if #commands == 1 then
				callback({
					code = 2,
					stdout = vim.json.encode({
						ok = false,
						error = {
							code = "ambiguous_round",
							message = "More than one round matches; specify --round",
							details = { rounds = { round, other_round } },
						},
					}) .. "\n",
					stderr = "",
				})
			else
				callback({
					code = 0,
					stdout = vim.json.encode({
						ok = true,
						command = "status",
						round = other_round,
						repo_root = uncached_root,
					}) .. "\n",
					stderr = "",
				})
			end
			return {}
		end,
		schedule = function(callback)
			callback()
		end,
		select = function(items, options, callback)
			selected = { items = items, options = options }
			callback(other_round)
		end,
		open_terminal = function(command)
			opened = command
		end,
	})
	assert(vim.deep_equal(selected.items, { round, other_round }))
	assert(selected.options.prompt == "Select tuicr review round")
	assert(vim.deep_equal(commands[1], { review._launcher, "status", "--repo", uncached_root }))
	assert(vim.deep_equal(commands[2], { review._launcher, "status", "--round", other_round }))
	assert(vim.deep_equal(opened, { review._launcher, "open", "--round", other_round }))
end)

test("TuicrReview accepts a validated explicit UUID", function()
	local explicit_root = "/tmp/explicit review"
	local captured
	local opened
	review.open(explicit_root, {
		round = round,
		system = function(command, _, callback)
			captured = command
			callback({
				code = 0,
				stdout = vim.json.encode({
					ok = true,
					command = "status",
					round = round,
					repo_root = explicit_root,
				}) .. "\n",
				stderr = "",
			})
			return {}
		end,
		schedule = function(callback)
			callback()
		end,
		open_terminal = function(command)
			opened = command
		end,
	})
	assert(vim.deep_equal(captured, { review._launcher, "status", "--round", round }))
	assert(vim.deep_equal(opened, { review._launcher, "open", "--round", round }))
end)

test("review uses the shared 95 percent TUI terminal contract", function()
	local options = review._terminal_spec(root, round)
	assert(options.runtime == "host" and options.root == root and options.id == "tuicr-review")
	assert(options.layout == "float" and options.title == "tuicr review")
	assert(vim.deep_equal(options.argv, { review._launcher, "open", "--round", round }))
	assert(vim.deep_equal(options.passthrough, { "j", "<space>" }))
	assert(vim.deep_equal(options.hide_keys, { "<C-t>" }))
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("review_spec: %d tests passed", count))
vim.cmd("quitall!")
