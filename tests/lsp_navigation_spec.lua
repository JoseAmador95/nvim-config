vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

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

local markdown_handlers = {}
local markdown_setup
local blocked_buffers = {}
local enforced = {}
local capture_value
local capture_override
local definition_options
local history_records = {}
local opened = {}
local picker_calls = {}
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, options)
	notifications[#notifications + 1] = { message = tostring(message), level = level, options = options }
end

package.loaded["config.editor"] = {
	open_file_in_tab = function(path, options)
		opened[#opened + 1] = { path = path, options = vim.deepcopy(options) }
	end,
}
package.loaded["config.navigation_history"] = {
	capture = function()
		if capture_override then
			return capture_override()
		end
		return vim.deepcopy(capture_value)
	end,
	same_location = function(left, right)
		if type(left) ~= "table" or type(right) ~= "table" then
			return false
		end
		if left.kind == "provider" or right.kind == "provider" then
			return left.kind == "provider"
				and right.kind == "provider"
				and left.provider == right.provider
				and left.document_key == right.document_key
				and left.location_key == right.location_key
		end
		return left.path == right.path and left.lnum == right.lnum and left.col == right.col
	end,
	record_transition = function(origin, destination)
		history_records[#history_records + 1] = {
			origin = vim.deepcopy(origin),
			destination = vim.deepcopy(destination),
		}
		return origin ~= nil and destination ~= nil
	end,
}
package.loaded["config.markdown_navigation"] = {
	setup = function(options)
		markdown_setup = options
	end,
	handler = function(bufnr)
		return markdown_handlers[bufnr]
	end,
}
local native_review_stub = {
	lsp = {
		blocked = function(bufnr)
			return blocked_buffers[bufnr] == true
		end,
		enforce_blocked = function(bufnr, client_id)
			enforced[#enforced + 1] = { bufnr = bufnr, client_id = client_id }
			return blocked_buffers[bufnr] == true
		end,
		definition_options = function()
			return definition_options
		end,
	},
}
package.loaded["config.native_review"] = nil
local review = require("config.code_review")
assert(not review.lsp_blocked(0), "unloaded review runtime blocked ordinary LSP navigation")
assert(package.loaded["config.native_review"] == nil, "LSP observation activated native review")
package.loaded["config.native_review"] = native_review_stub
package.loaded.snacks = {
	picker = {
		pick = function(options)
			picker_calls[#picker_calls + 1] = { name = "pick", options = options }
		end,
		lsp_implementations = function(options)
			picker_calls[#picker_calls + 1] = { name = "lsp_implementations", options = options }
		end,
		lsp_references = function(options)
			picker_calls[#picker_calls + 1] = { name = "lsp_references", options = options }
		end,
	},
}

local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_request_all = vim.lsp.buf_request_all
local original_locations_to_items = vim.lsp.util.locations_to_items
local original_definition = vim.lsp.buf.definition
local original_declaration = vim.lsp.buf.declaration
local clients = {}
vim.lsp.get_clients = function()
	return clients
end
vim.lsp.get_client_by_id = function(client_id)
	for _, client in ipairs(clients) do
		if client.id == client_id then
			return client
		end
	end
end
vim.lsp.util.locations_to_items = function(locations)
	return vim.deepcopy(locations)
end

local pending_request_all
vim.lsp.buf_request_all = function(_, _, _, callback)
	pending_request_all = callback
end

local pending_on_list
vim.lsp.buf.definition = function(options)
	pending_on_list = options.on_list
end
vim.lsp.buf.declaration = function(options)
	pending_on_list = options.on_list
end

local function buffer_mapping(bufnr, mode, lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
		if mapping.lhs == lhs then
			return mapping
		end
	end
end

local function global_mapping(mode, lhs)
	for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
		if mapping.lhs == lhs then
			return mapping
		end
	end
end

local function new_buffer()
	return vim.api.nvim_create_buf(true, false)
end

local function origin(label)
	return { path = "/tmp/" .. label .. ".lua", lnum = 2, col = 3 }
end

local function reset_observations()
	capture_value = nil
	capture_override = nil
	definition_options = nil
	history_records = {}
	opened = {}
	picker_calls = {}
	notifications = {}
	pending_on_list = nil
	pending_request_all = nil
end

local function picker()
	return {
		closed = 0,
		close = function(self)
			self.closed = self.closed + 1
		end,
	}
end

local native_global = function() end
local external_global = function() end
vim.keymap.set("n", "gri", native_global, { desc = "vim.lsp.buf.implementation()" })
vim.keymap.set("n", "grn", external_global, { desc = "External rename" })

local navigation = require("config.lsp_navigation")
navigation.setup()

test("setup removes only exact native global defaults", function()
	equal(nil, global_mapping("n", "gri"), "exact native default survived setup")
	local mapping = global_mapping("n", "grn")
	assert(mapping and mapping.callback == external_global, "external global mapping was removed")
	equal("External rename", mapping.desc, "external global mapping changed")
end)

test("FileType removes only exact native buffer defaults", function()
	local bufnr = new_buffer()
	local native = function() end
	local external = function() end
	vim.keymap.set("n", "K", native, { buffer = bufnr, desc = "vim.lsp.buf.hover()" })
	vim.keymap.set("n", "gra", external, { buffer = bufnr, desc = "External code action" })
	vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
	equal(nil, buffer_mapping(bufnr, "n", "K"), "native buffer default survived FileType")
	local mapping = buffer_mapping(bufnr, "n", "gra")
	assert(mapping and mapping.callback == external, "external buffer mapping was removed")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("host mappings survive one detach and clear after the last client", function()
	local bufnr = new_buffer()
	clients = { { id = 11 }, { id = 12 } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 11 } })
	assert(buffer_mapping(bufnr, "n", "gd"), "LspAttach did not install gd")
	assert(buffer_mapping(bufnr, "n", "K"), "LspAttach did not install K")

	vim.api.nvim_exec_autocmds("LspDetach", { buffer = bufnr, data = { client_id = 11 } })
	assert(buffer_mapping(bufnr, "n", "gd"), "first detach removed mappings with a client remaining")

	clients = { { id = 12 } }
	vim.api.nvim_exec_autocmds("LspDetach", { buffer = bufnr, data = { client_id = 12 } })
	equal(nil, buffer_mapping(bufnr, "n", "gd"), "last detach retained owned gd")
	equal(nil, buffer_mapping(bufnr, "n", "K"), "last detach retained owned K")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("last detach preserves a mapping replaced by another owner", function()
	local bufnr = new_buffer()
	clients = { { id = 21 } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 21 } })
	local external = function() end
	vim.keymap.set("n", "K", external, { buffer = bufnr, desc = "External hover" })
	vim.api.nvim_exec_autocmds("LspDetach", { buffer = bufnr, data = { client_id = 21 } })
	local mapping = buffer_mapping(bufnr, "n", "K")
	assert(mapping and mapping.callback == external, "detach removed another owner's replacement")
	equal("External hover", mapping.desc, "replacement mapping changed")
	equal(nil, buffer_mapping(bufnr, "n", "gD"), "detach retained an untouched owned mapping")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("Markdown keeps callback identity across attach and detach", function()
	local bufnr = new_buffer()
	local markdown = function() end
	markdown_handlers[bufnr] = markdown
	vim.keymap.set("n", "gd", markdown, { buffer = bufnr, desc = "Follow Markdown link" })
	clients = { { id = 31 } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 31 } })
	local attached = buffer_mapping(bufnr, "n", "gd")
	assert(attached and attached.callback == markdown, "LspAttach replaced Markdown gd")
	vim.api.nvim_exec_autocmds("LspDetach", { buffer = bufnr, data = { client_id = 31 } })
	local detached = buffer_mapping(bufnr, "n", "gd")
	assert(detached and detached.callback == markdown, "LspDetach removed Markdown gd")
	equal("Follow Markdown link", detached.desc, "Markdown mapping metadata changed")
	markdown_handlers[bufnr] = nil
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("LspAttach does not clobber an existing buffer-local owner", function()
	local bufnr = new_buffer()
	local external = function() end
	vim.keymap.set("n", "gd", external, { buffer = bufnr, desc = "External definition" })
	clients = { { id = 41 } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 41 } })
	local mapping = buffer_mapping(bufnr, "n", "gd")
	assert(mapping and mapping.callback == external, "LspAttach clobbered buffer-local gd")
	equal("External definition", mapping.desc, "external gd metadata changed")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("single and multi-result LSP navigation retain one immutable request origin", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 61, offset_encoding = "utf-16" } }
	local issued = origin("issued")
	capture_value = issued
	assert(navigation.definition(), "definition request was not issued")
	assert(type(pending_on_list) == "function", "definition request did not retain on_list")
	capture_value = origin("late")
	pending_on_list({ items = { { filename = "/tmp/single.lua", lnum = 7, col = 5 } } })
	equal({
		{
			path = "/tmp/single.lua",
			options = { lnum = 7, col = 5, history_origin = issued },
		},
	}, opened, "single-result dispatch recaptured or duplicated its origin")
	equal({}, history_records, "ordinary single-result dispatch recorded outside the editor")

	reset_observations()
	capture_value = issued
	assert(navigation.declaration(), "declaration request was not issued")
	capture_value = origin("late-multi")
	pending_on_list({
		items = {
			{ filename = "/tmp/first.lua", lnum = 3, col = 2 },
			{ filename = "/tmp/second.lua", lnum = 9, col = 4 },
		},
	})
	equal(1, #picker_calls, "multi-result request did not open exactly one picker")
	equal({}, opened, "multi-result request navigated before confirmation")
	local instance = picker()
	picker_calls[1].options.confirm(instance, picker_calls[1].options.items[2])
	equal(1, instance.closed, "multi-result confirmation did not close its picker")
	equal({
		{
			path = "/tmp/second.lua",
			options = { lnum = 9, col = 4, history_origin = issued },
		},
	}, opened, "multi-result confirmation bypassed dispatch or duplicated navigation")
	equal({}, history_records, "ordinary multi-result dispatch recorded outside the editor")
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("successful review routing records the routed destination exactly once", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 62, offset_encoding = "utf-16" } }
	local issued = origin("review-issued")
	local destination = {
		kind = "provider",
		provider = "review",
		document_key = "session:file.lua",
		location_key = "18:4",
		label = "Review file.lua:18:4",
		payload = { line = 18, column = 4 },
	}
	definition_options = {
		route = function(location)
			equal({ path = "/tmp/review-target.lua", lnum = 18, col = 4 }, {
				path = location.path,
				lnum = location.lnum,
				col = location.col,
			}, "review route received the wrong location")
			capture_value = destination
			return true
		end,
	}
	capture_value = issued
	assert(navigation.definition(), "review definition request was not issued")
	pending_on_list({ items = { { filename = "/tmp/review-target.lua", lnum = 18, col = 4 } } })
	equal({}, opened, "handled review route also opened an editor tab")
	equal(
		{ { origin = issued, destination = destination } },
		history_records,
		"review route history was not recorded once"
	)
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("consumed review no-ops do not fabricate navigation history", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 63, offset_encoding = "utf-16" } }
	local issued = origin("review-issued")
	local current = origin("independent-current")
	definition_options = {
		route = function()
			return true
		end,
	}
	capture_value = issued
	assert(navigation.definition(), "review definition request was not issued")
	capture_value = current
	pending_on_list({ items = { { filename = "/tmp/stale-review-target.lua", lnum = 18, col = 4 } } })
	equal({}, opened, "consumed review no-op fell through to the editor")
	equal({}, history_records, "consumed review no-op fabricated a transition")
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("consumed review routes require two capturable endpoints", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 64, offset_encoding = "utf-16" } }
	local issued = origin("review-issued")
	local current = origin("transiently-capturable-current")
	local captures = { issued, nil, current }
	local capture_index = 0
	capture_override = function()
		capture_index = capture_index + 1
		return vim.deepcopy(captures[capture_index])
	end
	definition_options = {
		route = function()
			return true
		end,
	}
	assert(navigation.definition(), "review definition request was not issued")
	pending_on_list({ items = { { filename = "/tmp/transient-review-target.lua", lnum = 18, col = 4 } } })
	equal({}, opened, "consumed review route fell through to the editor")
	equal({}, history_records, "route with an incapturable pre-route endpoint fabricated a transition")
	equal(3, capture_index, "review route did not consume the expected endpoint captures")
	capture_override = nil
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("native gd fallback records movement and ignores an exact no-op", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local target = 1", "", "print(target)" })
	vim.api.nvim_win_set_buf(0, bufnr)
	local function current_location()
		local cursor = vim.api.nvim_win_get_cursor(0)
		return { path = "/tmp/native-gd.lua", lnum = cursor[1], col = cursor[2] + 1 }
	end
	capture_override = current_location
	vim.api.nvim_win_set_cursor(0, { 3, 8 })
	assert(navigation.definition_or_native(bufnr), "native gd fallback was not handled")
	equal(1, vim.api.nvim_win_get_cursor(0)[1], "native gd did not move to the declaration")
	equal(1, #history_records, "native gd movement was not recorded once")
	equal({ path = "/tmp/native-gd.lua", lnum = 3, col = 9 }, history_records[1].origin, "native gd origin changed")
	equal(
		{ path = "/tmp/native-gd.lua", lnum = 1, col = 7 },
		history_records[1].destination,
		"native gd destination changed"
	)

	history_records = {}
	assert(navigation.definition_or_native(bufnr), "native gd no-op was not handled")
	equal({}, history_records, "native gd no-op fabricated a transition")
	capture_override = nil
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("explicit aggregate and named-client requests keep their issuance origin", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	local issued = origin("aggregate-issued")
	clients = { { id = 71, name = "marksman", offset_encoding = "utf-16" } }
	capture_value = issued
	assert(navigation.location_at("definition", bufnr, 1, 1), "aggregate request was not issued")
	assert(type(pending_request_all) == "function", "aggregate callback was not retained")
	capture_value = origin("aggregate-late")
	pending_request_all({
		[71] = { result = { { filename = "/tmp/aggregate.lua", lnum = 4, col = 2 } } },
	})
	equal(issued, opened[1].options.history_origin, "aggregate request recaptured a late origin")

	reset_observations()
	local pending_client
	clients = {
		{
			id = 72,
			name = "marksman",
			offset_encoding = "utf-16",
			request = function(_, _, _, callback)
				pending_client = callback
				return true
			end,
		},
	}
	issued = origin("client-issued")
	capture_value = issued
	assert(
		navigation.definition_at_for_client("marksman", bufnr, 1, 1, "Markdown link"),
		"named-client request was not issued"
	)
	assert(type(pending_client) == "function", "named-client callback was not retained")
	capture_value = origin("client-late")
	pending_client(nil, { { filename = "/tmp/client.lua", lnum = 6, col = 7 } })
	equal(issued, opened[1].options.history_origin, "named-client request recaptured a late origin")
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("aggregate requests expose client errors and retain partial successes", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = {
		{ id = 73, name = "broken-lsp", offset_encoding = "utf-16" },
		{ id = 74, name = "working-lsp", offset_encoding = "utf-16" },
	}
	assert(navigation.location_at("definition", bufnr, 1, 1), "aggregate error request was not issued")
	pending_request_all({ [73] = { err = { message = "boom" } } })
	equal({}, opened, "failed aggregate request opened a destination")
	equal({}, picker_calls, "failed aggregate request opened a picker")
	equal(1, #notifications, "failed aggregate request did not report exactly one error")
	assert(notifications[1].message:find("broken%-lsp: boom"), notifications[1].message)
	assert(not notifications[1].message:find("no locations found", 1, true), notifications[1].message)

	reset_observations()
	assert(navigation.location_at("definition", bufnr, 1, 1), "partial aggregate request was not issued")
	pending_request_all({
		[73] = { error = { message = "partial failure" } },
		[74] = { result = { { filename = "/tmp/partial.lua", lnum = 8, col = 4 } } },
	})
	equal(1, #opened, "partial aggregate success was discarded")
	equal("/tmp/partial.lua", opened[1].path, "partial aggregate opened the wrong destination")
	equal(1, #notifications, "partial aggregate failure was not reported once")
	assert(notifications[1].message:find("broken%-lsp: partial failure"), notifications[1].message)
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("request guard exceptions retain their diagnostic text", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 75, name = "guarded-lsp", offset_encoding = "utf-16" } }
	assert(
		navigation.location_at("definition", bufnr, 1, 1, {
			pending = function()
				error("pending boom")
			end,
		}),
		"guarded request was not issued"
	)
	pending_request_all({
		[75] = { result = { { filename = "/tmp/pending.lua", lnum = 2, col = 1 } } },
	})
	equal({}, opened, "failed pending guard opened a destination")
	assert(notifications[1].message:find("pending boom", 1, true), notifications[1].message)

	reset_observations()
	assert(
		navigation.location_at("definition", bufnr, 1, 1, {
			valid = function()
				error("valid boom")
			end,
		}),
		"validity-guarded request was not issued"
	)
	pending_request_all({
		[75] = { result = { { filename = "/tmp/valid.lua", lnum = 3, col = 1 } } },
	})
	equal({}, opened, "failed validity guard opened a destination")
	assert(notifications[1].message:find("valid boom", 1, true), notifications[1].message)
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("gi and gr picker confirms use exact positions and invocation origins", function()
	reset_observations()
	local bufnr = new_buffer()
	vim.api.nvim_win_set_buf(0, bufnr)
	clients = { { id = 81, offset_encoding = "utf-16" } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 81 } })
	local issued = origin("picker-issued")
	capture_value = issued
	buffer_mapping(bufnr, "n", "gi").callback()
	equal("lsp_implementations", picker_calls[1].name, "gi opened the wrong picker")
	capture_value = origin("picker-late")
	local implementation = picker()
	picker_calls[1].options.confirm(implementation, { file = "/tmp/implementation.lua", pos = { 12, 4 } })
	equal(1, implementation.closed, "gi confirmation did not close its picker")
	equal({
		{
			path = "/tmp/implementation.lua",
			options = { lnum = 12, col = 5, history_origin = issued },
		},
	}, opened, "gi lost its exact position or invocation origin")

	reset_observations()
	issued = origin("references-issued")
	capture_value = issued
	buffer_mapping(bufnr, "n", "gr").callback()
	equal("lsp_references", picker_calls[1].name, "gr opened the wrong picker")
	local references = picker()
	picker_calls[1].options.confirm(references, { file = "/tmp/reference.lua", pos = { 21, 8 } })
	equal({
		{
			path = "/tmp/reference.lua",
			options = { lnum = 21, col = 9, history_origin = issued },
		},
	}, opened, "gr lost its exact position or invocation origin")

	local special = vim.api.nvim_create_buf(true, false)
	vim.bo[special].buftype = "nofile"
	local before = #opened
	picker_calls[1].options.confirm(picker(), { buf = special, file = "Review panel" })
	equal(before, #opened, "special picker item was treated as a file")
	vim.api.nvim_buf_delete(special, { force = true })
	clients = {}
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

test("historical review buffers fail closed before mappings are installed", function()
	local bufnr = new_buffer()
	blocked_buffers[bufnr] = true
	clients = { { id = 51 } }
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 51 } })
	equal(nil, buffer_mapping(bufnr, "n", "gd"), "blocked review buffer received gd")
	equal(nil, buffer_mapping(bufnr, "n", "K"), "blocked review buffer received K")
	local last = enforced[#enforced]
	equal({ bufnr = bufnr, client_id = 51 }, last, "review enforcement did not receive the attach identity")
	blocked_buffers[bufnr] = nil
	vim.api.nvim_buf_delete(bufnr, { force = true })
end)

assert(type(markdown_setup) == "table", "Markdown navigation was not configured")
assert(type(markdown_setup.eligible) == "function", "Markdown eligibility bridge is missing")

vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_request_all = original_buf_request_all
vim.lsp.util.locations_to_items = original_locations_to_items
vim.lsp.buf.definition = original_definition
vim.lsp.buf.declaration = original_declaration
vim.notify = original_notify
pcall(vim.keymap.del, "n", "grn")
pcall(vim.api.nvim_del_augroup_by_name, "LspKeymaps")

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("lsp_navigation_spec: %d tests passed", count))
vim.cmd("quitall!")
