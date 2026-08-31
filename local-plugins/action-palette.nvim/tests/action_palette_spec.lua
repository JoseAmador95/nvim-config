vim.o.shadafile = "NONE"
vim.o.swapfile = false

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root .. "/local-plugins/action-palette.nvim")
package.path = table.concat({ root .. "/local-plugins/_shared/lua/?.lua", package.path }, ";")

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
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

local action_palette = require("action_palette")

local function catalog(when)
	return {
		{
			id = "sample",
			label = "Sample",
			items = {
				{ id = "sample.run", label = "Run", when = when },
				{ id = "sample.confirm", label = "Confirm" },
			},
		},
	}
end

test("schema accepts only exact ActionTarget and catalog fields", function()
	local target = action_palette.capture_target()
	assert(action_palette.schema.action_target(target))
	local injected = vim.deepcopy(target)
	injected.surface = "palette"
	local invalid, invalid_err = action_palette.schema.action_target(injected)
	assert(not invalid and invalid_err:find("unknown field", 1, true))

	local duplicate = catalog()
	duplicate[1].items[2].id = "sample.run"
	local sections, sections_err = action_palette.schema.catalog(duplicate)
	assert(not sections and sections_err:find("duplicated", 1, true))
	local callback = function() end
	local with_callback = catalog()
	with_callback[1].items[1].run = callback
	sections, sections_err = action_palette.schema.catalog(with_callback)
	assert(not sections and sections_err:find("unknown key", 1, true))
end)

test("capture and revalidation fail closed for changed content and cursor", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
	local target = action_palette.capture_target()
	equal(vim.api.nvim_buf_get_changedtick(buf), target.changedtick, "captured changedtick")
	assert(action_palette.revalidate_target(target))

	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	local moved, moved_err = action_palette.revalidate_target(target)
	assert(not moved and moved_err:find("cursor changed", 1, true))
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
	local changed, changed_err = action_palette.revalidate_target(target)
	assert(not changed and changed_err:find("buffer changed", 1, true))
end)

test("availability is filtered and revalidated immediately before execution", function()
	local allowed = true
	local executions = 0
	local registry = action_palette.new({
		refresh_context = function(context)
			context.allowed = allowed
			return context
		end,
		notify = function() end,
	})
	registry:register_catalog(
		catalog(function(context)
			return context.allowed
		end),
		{
			supports = function()
				return true
			end,
			execute = function()
				executions = executions + 1
			end,
		}
	)
	local context = { allowed = true, target = action_palette.capture_target() }
	assert(#registry:sections(context, "palette")[1].items == 2)
	local run = registry:bind("sample.run", context, "palette")
	allowed = false
	local ok, err = run()
	assert(not ok and err:find("no longer available", 1, true))
	equal(0, executions, "unavailable action executed")
	assert(not run(), "consumed unavailable action ran twice")
end)

test("confirmation is intrinsic and a bound callback executes at most once", function()
	local prompts = {}
	local decision
	local executions = {}
	local registry = action_palette.new({
		confirm = function(prompt, callback)
			prompts[#prompts + 1] = prompt
			decision = callback
		end,
		notify = function() end,
	})
	registry:register_catalog(catalog(), {
		supports = function()
			return true
		end,
		confirmation = function(id)
			return id == "sample.confirm" and "Proceed?" or nil
		end,
		execute = function(id, invocation)
			executions[#executions + 1] = { id = id, surface = invocation.surface }
		end,
	})
	local context = { target = action_palette.capture_target() }
	local run = registry:bind("sample.confirm", context, "context")
	assert(run())
	assert(not run(), "pending confirmation accepted a duplicate invocation")
	equal({ "Proceed?" }, prompts, "intrinsic confirmation prompt")
	decision(true)
	decision(true)
	equal({ { id = "sample.confirm", surface = "context" } }, executions, "exactly-once execution")
end)

test("confirmation revalidates the target again immediately before execution", function()
	local decision
	local executions = 0
	local notifications = {}
	local registry = action_palette.new({
		confirm = function(_, callback)
			decision = callback
		end,
		notify = function(message)
			notifications[#notifications + 1] = message
		end,
	})
	registry:register_catalog(catalog(), {
		supports = function()
			return true
		end,
		confirmation = function(id)
			return id == "sample.confirm" and "Proceed?" or nil
		end,
		execute = function()
			executions = executions + 1
		end,
	})
	local context = { target = action_palette.capture_target() }
	assert(registry:bind("sample.confirm", context, "palette")())
	vim.api.nvim_buf_set_lines(context.target.bufnr, 0, -1, false, { "changed while confirming" })
	decision(true)
	equal(0, executions, "changed target executed after confirmation")
	assert(notifications[1]:find("buffer changed", 1, true), "target drift was not reported")
end)

test("confirmation fails closed without a host presentation adapter", function()
	local executions = 0
	local notification
	local registry = action_palette.new({
		notify = function(message)
			notification = message
		end,
	})
	registry:register_catalog(catalog(), {
		supports = function()
			return true
		end,
		confirmation = function(id)
			return id == "sample.confirm" and "Proceed?" or nil
		end,
		execute = function()
			executions = executions + 1
		end,
	})
	local ok, err = registry:bind("sample.confirm", { target = action_palette.capture_target() }, "context")()
	assert(not ok and err == "Confirmation adapter is unavailable", "missing confirmation adapter did not fail closed")
	equal(0, executions, "confirmed action executed without a host presentation adapter")
	equal(err, notification, "missing confirmation adapter was not reported")
end)

test("plugin setup creates no global commands, mappings, or config imports", function()
	local commands_before = vim.api.nvim_get_commands({ builtin = false })
	local maps_before = vim.api.nvim_get_keymap("n")
	action_palette.setup({ notify = function() end })
	equal(commands_before, vim.api.nvim_get_commands({ builtin = false }), "plugin registered a global command")
	equal(maps_before, vim.api.nvim_get_keymap("n"), "plugin registered a global mapping")
	for name in pairs(package.loaded) do
		assert(not name:match("^config%."), "plugin imported host module " .. name)
	end
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("action_palette_spec: %d tests passed", count))
vim.cmd("quitall!")
