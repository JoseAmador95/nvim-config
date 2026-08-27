vim.o.shadafile = "NONE"
vim.o.swapfile = false

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

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

local review_lsp = require("config.review_lsp")
local lsp_navigation = require("config.lsp_navigation")

test("roles gate root discovery and racing attachments", function()
	local old = vim.api.nvim_create_buf(false, true)
	assert(review_lsp.mark(old, "old"))
	assert(review_lsp.blocked(old))
	local called = false
	review_lsp.wrap_root_dir(function()
		called = true
	end)(old, function() end)
	assert(not called, "blocked buffer reached native root resolution")
	local current = vim.api.nvim_create_buf(false, true)
	review_lsp.mark(current, "current")
	review_lsp.wrap_root_dir(function(_, on_dir)
		called = true
		on_dir("/tmp")
	end)(current, function(value)
		assert(value == "/tmp")
	end)
	assert(called)

	local original = vim.lsp.buf_detach_client
	local detached
	vim.lsp.buf_detach_client = function(buf, client)
		detached = { buf, client }
	end
	review_lsp.setup()
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = old, data = { client_id = 17 } })
	vim.lsp.buf_detach_client = original
	assert(vim.deep_equal(detached, { old, 17 }), "racing LSP client was not detached")
	vim.api.nvim_buf_delete(old, { force = true })
	vim.api.nvim_buf_delete(current, { force = true })
end)

test("late LspAttach consumers stay fail-closed after didOpen fallback", function()
	local snapshot = vim.api.nvim_create_buf(false, true)
	local normal = vim.api.nvim_create_buf(false, true)
	local active = { [snapshot] = { { id = 41 } }, [normal] = {} }
	local detached = {}
	local navic_attaches = 0
	local navic_clears = 0
	local originals = {
		get_clients = vim.lsp.get_clients,
		get_client_by_id = vim.lsp.get_client_by_id,
		buf_detach_client = vim.lsp.buf_detach_client,
		lazy = package.loaded.lazy,
		navic = package.loaded["nvim-navic"],
		navic_lib = package.loaded["nvim-navic.lib"],
	}
	local ok, err = xpcall(function()
		vim.lsp.get_clients = function(options)
			return active[options.bufnr] or {}
		end
		vim.lsp.buf_detach_client = function(buf, client_id)
			detached[#detached + 1] = { buf, client_id }
			local remaining = {}
			for _, client in ipairs(active[buf] or {}) do
				if client.id ~= client_id then
					remaining[#remaining + 1] = client
				end
			end
			active[buf] = remaining
			return true
		end
		vim.lsp.get_client_by_id = function(id)
			return {
				id = id,
				supports_method = function()
					return true
				end,
			}
		end
		package.loaded.lazy = { load = function() end }
		package.loaded["nvim-navic"] = {
			attach = function()
				navic_attaches = navic_attaches + 1
			end,
		}
		package.loaded["nvim-navic.lib"] = {
			clear_buffer_data = function(buf)
				assert(buf == snapshot)
				navic_clears = navic_clears + 1
			end,
		}

		vim.keymap.set("n", "gd", function() end, { buffer = snapshot, desc = "Go to definition" })
		vim.keymap.set("n", "gD", function() end, { buffer = snapshot, desc = "Go to declaration" })
		vim.keymap.set("n", "gri", function() end, { desc = "Unrelated global mapping" })
		for _, lhs in ipairs({ "K", "gO", "gri", "grn", "grr", "grt", "grx", "gra" }) do
			vim.keymap.set("n", lhs, function() end, { buffer = snapshot, desc = "Default LSP navigation" })
		end
		vim.keymap.set("x", "gra", function() end, { buffer = snapshot, desc = "Default LSP code action" })
		vim.b[snapshot].navic_client_id = 41
		vim.b[snapshot].navic_client_name = "late-lsp"
		local navic_group = vim.api.nvim_create_augroup("navic", { clear = true })
		vim.api.nvim_create_autocmd("BufEnter", { group = navic_group, buffer = snapshot, callback = function() end })

		assert(review_lsp.mark(snapshot, "snapshot", { bridge = true }))
		assert(vim.deep_equal(detached, { { snapshot, 41 } }), "mark did not detach the existing client")
		assert(vim.b[snapshot].navic_client_id == nil and vim.b[snapshot].navic_client_name == nil)
		assert(#vim.api.nvim_get_autocmds({ group = navic_group, buffer = snapshot }) == 0)
		local marked_gd = vim.api.nvim_buf_call(snapshot, function()
			return vim.fn.maparg("gd", "n", false, true)
		end)
		assert(marked_gd.desc == "Review definition in current source")
		for _, lhs in ipairs({ "gD", "K", "gO", "gri", "grn", "grr", "grt", "grx", "gra" }) do
			local mapping = vim.api.nvim_buf_call(snapshot, function()
				return vim.fn.maparg(lhs, "n", false, true)
			end)
			assert(mapping.desc == "Historical review buffer has no LSP", "navigation escaped guard: " .. lhs)
		end
		local visual_guard = vim.api.nvim_buf_call(snapshot, function()
			return vim.fn.maparg("gra", "x", false, true)
		end)
		assert(visual_guard.desc == "Historical review buffer has no LSP")
		local global_preserved = false
		for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
			global_preserved = global_preserved or mapping.lhs == "gri" and mapping.desc == "Unrelated global mapping"
		end
		assert(global_preserved, "mark deleted an unrelated global mapping")

		-- Reproduce startup order: the review guard exists before normal LSP/navic consumers.
		lsp_navigation.setup()
		require("plugins.navic").init()
		active[snapshot] = { { id = 42 } }
		vim.api.nvim_exec_autocmds("LspAttach", { buffer = snapshot, data = { client_id = 42 } })
		assert(vim.wait(100, function()
			return #active[snapshot] == 0
		end))
		local final_gd = vim.api.nvim_buf_call(snapshot, function()
			return vim.fn.maparg("gd", "n", false, true)
		end)
		assert(final_gd.desc == "Review definition in current source", vim.inspect(final_gd))
		for _, lhs in ipairs({
			"gD",
			"gi",
			"gr",
			"K",
			"gO",
			"gri",
			"grn",
			"grr",
			"grt",
			"grx",
			"gra",
			"<C-k>",
			"<leader>lr",
			"<leader>ca",
		}) do
			local mapping = vim.api.nvim_buf_call(snapshot, function()
				return vim.fn.maparg(lhs, "n", false, true)
			end)
			assert(mapping.desc == "Historical review buffer has no LSP", "normal LSP mapping escaped: " .. lhs)
		end
		for _, lhs in ipairs({ "gra", "<leader>ca" }) do
			local mapping = vim.api.nvim_buf_call(snapshot, function()
				return vim.fn.maparg(lhs, "x", false, true)
			end)
			assert(mapping.desc == "Historical review buffer has no LSP", "visual LSP mapping escaped: " .. lhs)
		end
		assert(navic_attaches == 0, "navic attached to historical review content")
		assert(navic_clears >= 2, "navic state was not cleared across mark and racing attach")

		vim.api.nvim_exec_autocmds("LspAttach", { buffer = normal, data = { client_id = 43 } })
		local normal_gd = vim.api.nvim_buf_call(normal, function()
			return vim.fn.maparg("gd", "n", false, true)
		end)
		assert(normal_gd.desc == "Go to definition")
		assert(navic_attaches == 1, "normal source buffer no longer receives navic")
	end, debug.traceback)
	vim.lsp.get_clients = originals.get_clients
	vim.lsp.get_client_by_id = originals.get_client_by_id
	vim.lsp.buf_detach_client = originals.buf_detach_client
	package.loaded.lazy = originals.lazy
	package.loaded["nvim-navic"] = originals.navic
	package.loaded["nvim-navic.lib"] = originals.navic_lib
	vim.api.nvim_buf_delete(snapshot, { force = true })
	vim.api.nvim_buf_delete(normal, { force = true })
	assert(ok, err)
end)

test("line mapping accepts only unchanged regions", function()
	local snapshot = { "one", "two", "three", "four" }
	local current = { "zero", "one", "changed", "three", "four" }
	assert(review_lsp.map_line(snapshot, current, 1) == 2)
	local mapped, err = review_lsp.map_line(snapshot, current, 2)
	assert(mapped == nil and err:find("changed hunk", 1, true))
	assert(review_lsp.map_line(snapshot, current, 3) == 4)
end)

test("historical-new gd maps before opening current source and old never invokes LSP", function()
	local fixture = vim.fn.tempname()
	assert(vim.fn.mkdir(fixture, "p") == 1)
	local path = fixture .. "/sample.lua"
	assert(vim.fn.writefile({ "one", "changed", "three" }, path) == 0)
	local snapshot = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { "one", "two", "three" })
	local opened
	local definitions = {}
	review_lsp.mark(snapshot, "snapshot", {
		root = fixture,
		path = "sample.lua",
		open = function(opened_path, position)
			opened = { opened_path, position }
		end,
		definition = function(target, line, column)
			definitions[#definitions + 1] = { target, line, column }
		end,
		lsp_ready = function()
			return true
		end,
	})
	local ok, err = review_lsp.goto_definition(snapshot, 3, 7)
	assert(ok, err)
	vim.wait(100, function()
		return #definitions == 1
	end)
	assert(
		opened
			and vim.uv.fs_realpath(opened[1]) == vim.uv.fs_realpath(path)
			and opened[2].lnum == 3
			and opened[2].col == 7
			and vim.deep_equal(definitions, { { vim.fn.bufnr(path), 3, 7 } }),
		vim.inspect({ opened = opened, definitions = definitions })
	)
	local failed, changed_err = review_lsp.goto_definition(snapshot, 2)
	assert(failed == nil and changed_err:find("changed hunk", 1, true))

	local old = vim.api.nvim_create_buf(false, true)
	review_lsp.mark(old, "old", {
		definition = function()
			definitions[#definitions + 1] = { "old" }
		end,
	})
	local old_ok = review_lsp.goto_definition(old, 1)
	assert(old_ok == nil and #definitions == 1)
	vim.api.nvim_buf_delete(snapshot, { force = true })
	vim.api.nvim_buf_delete(old, { force = true })
	vim.fn.delete(fixture, "rf")
end)

test("historical-new gd times out without issuing a request", function()
	local fixture = vim.fn.tempname()
	assert(vim.fn.mkdir(fixture, "p") == 1)
	local path = fixture .. "/sample.lua"
	assert(vim.fn.writefile({ "one" }, path) == 0)
	local snapshot = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { "one" })
	local deferred = {}
	local definitions = 0
	local timed_out = false
	review_lsp.mark(snapshot, "snapshot", {
		root = fixture,
		path = "sample.lua",
		open = function() end,
		definition = function()
			definitions = definitions + 1
		end,
		lsp_ready = function()
			return false
		end,
		lsp_timeout = function()
			timed_out = true
		end,
		defer = function(callback)
			deferred[#deferred + 1] = callback
		end,
	})
	assert(review_lsp.goto_definition(snapshot, 1, 1))
	for _ = 1, 39 do
		assert(#deferred == 1)
		table.remove(deferred, 1)()
	end
	assert(vim.wait(100, function()
		return timed_out
	end))
	assert(definitions == 0 and #deferred == 0)
	vim.api.nvim_buf_delete(snapshot, { force = true })
	vim.fn.delete(fixture, "rf")
end)

test("explicit definition requests keep their target buffer and per-client encoding", function()
	local target = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(target, 0, -1, false, { "aéz" })
	local other = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(other)
	local clients = {
		{ id = 31, offset_encoding = "utf-8" },
		{ id = 32, offset_encoding = "utf-16" },
	}
	local originals = {
		get_clients = vim.lsp.get_clients,
		get_client_by_id = vim.lsp.get_client_by_id,
		buf_request_all = vim.lsp.buf_request_all,
		locations_to_items = vim.lsp.util.locations_to_items,
		snacks = package.loaded.snacks,
	}
	local picked
	local encodings = {}
	local ok, err = xpcall(function()
		vim.lsp.get_clients = function(options)
			assert(options.bufnr == target and options.method == "textDocument/definition")
			return clients
		end
		vim.lsp.get_client_by_id = function(id)
			return id == 31 and clients[1] or clients[2]
		end
		vim.lsp.buf_request_all = function(buf, method, params, callback)
			assert(buf == target and method == "textDocument/definition")
			local utf8 = params(clients[1])
			local utf16 = params(clients[2])
			assert(utf8.textDocument.uri == vim.uri_from_bufnr(target))
			assert(utf16.textDocument.uri == vim.uri_from_bufnr(target))
			assert(utf8.position.line == 0 and utf8.position.character == 3)
			assert(utf16.position.line == 0 and utf16.position.character == 2)
			callback({
				[31] = { result = { uri = "file:///tmp/first", range = {} } },
				[32] = { result = { uri = "file:///tmp/second", range = {} } },
			})
		end
		vim.lsp.util.locations_to_items = function(_, encoding)
			encodings[#encodings + 1] = encoding
			return { { filename = "/tmp/" .. encoding, lnum = 1, col = 1 } }
		end
		package.loaded.snacks = {
			picker = {
				pick = function(options)
					picked = options
				end,
			},
		}
		assert(lsp_navigation.definition_at(target, 1, 4))
		assert(vim.api.nvim_get_current_buf() == other)
		assert(picked and #picked.items == 2)
		table.sort(encodings)
		assert(vim.deep_equal(encodings, { "utf-16", "utf-8" }))
	end, debug.traceback)
	vim.lsp.get_clients = originals.get_clients
	vim.lsp.get_client_by_id = originals.get_client_by_id
	vim.lsp.buf_request_all = originals.buf_request_all
	vim.lsp.util.locations_to_items = originals.locations_to_items
	package.loaded.snacks = originals.snacks
	vim.api.nvim_buf_delete(target, { force = true })
	vim.api.nvim_buf_delete(other, { force = true })
	assert(ok, err)
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end
print(("review_lsp_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
