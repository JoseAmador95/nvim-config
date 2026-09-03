-- Host-adapter contract coverage for the extracted native review runtime.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/local-plugins/native-review.nvim")
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

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

local review_lsp = require("config.native_review").lsp
local lsp_navigation = require("config.lsp_navigation")
local review_projection = require("config.native_review").projection

local function write_file(path, value)
	local handle = assert(vim.uv.fs_open(path, "w", 420))
	assert(vim.uv.fs_write(handle, value, 0))
	assert(vim.uv.fs_close(handle))
end

local function unified_fixture(options)
	local directory = vim.fn.tempname()
	assert(vim.fn.mkdir(directory, "p") == 1)
	local path = directory .. "/sample.lua"
	write_file(path, options.current_text or options.new_text)
	if options.prepare_source then
		options.prepare_source(path)
	end
	local projection = assert(review_projection.build({
		hunks = options.hunks,
		new_path = "sample.lua",
		new_text = options.new_text,
		old_path = "sample.lua",
		old_text = options.old_text,
	}))
	local display = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(
		display,
		0,
		-1,
		false,
		vim.tbl_map(function(row)
			return row.text
		end, projection.rows)
	)
	local generation = options.generation or 1
	vim.b[display].nvim_review_projection_generation = generation
	local metadata = {
		bridge = true,
		context = options.context or "full",
		current_path = "sample.lua",
		generation = generation,
		projection = projection,
		root = directory,
		visible_sections = options.visible_sections,
	}
	for key, value in pairs(options.metadata or {}) do
		metadata[key] = value
	end
	assert(review_lsp.mark(display, "unified", metadata))
	local source = vim.fn.bufnr(path)
	assert(source > 0 and vim.api.nvim_buf_is_loaded(source))
	return {
		directory = directory,
		display = display,
		metadata = metadata,
		path = path,
		projection = projection,
		source = source,
	}
end

local function clear_unified_fixture(fixture)
	review_lsp.clear(fixture.display)
	if vim.api.nvim_buf_is_valid(fixture.display) then
		vim.api.nvim_buf_delete(fixture.display, { force = true })
	end
	if vim.api.nvim_buf_is_valid(fixture.source) then
		vim.api.nvim_buf_delete(fixture.source, { force = true })
	end
	vim.fn.delete(fixture.directory, "rf")
end

test("roles gate root discovery and racing attachments", function()
	local old = vim.api.nvim_create_buf(false, true)
	assert(review_lsp.mark(old, "old"))
	assert(review_lsp.blocked(old))
	local called = false
	review_lsp.wrap_root_dir(function()
		called = true
	end)(old, function() end)
	assert(not called, "blocked buffer reached native root resolution")
	local unified = vim.api.nvim_create_buf(false, true)
	local projection_metadata = {
		bridge = false,
		generation = 7,
		projection = { rows = { { display_line = 1, side = "old", source_line = 1 } } },
	}
	assert(review_lsp.mark(unified, "unified", projection_metadata))
	assert(review_lsp._role(unified) == "unified" and review_lsp.blocked(unified))
	review_lsp.wrap_root_dir(function()
		called = true
	end)(unified, function() end)
	assert(not called, "unified projection reached native root resolution")
	vim.bo[unified].filetype = "lua"
	assert(review_lsp.enforce_blocked(unified))
	local unified_gd = vim.api.nvim_buf_call(unified, function()
		return vim.fn.maparg("gd", "n", false, true)
	end)
	assert(unified_gd.desc == "Historical review buffer has no LSP", vim.inspect(unified_gd))
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
	vim.api.nvim_buf_delete(unified, { force = true })
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
	assert(review_lsp.map_current_line(snapshot, current, 2) == 1)
	local reverse, reverse_err = review_lsp.map_current_line(snapshot, current, 3)
	assert(reverse == nil and reverse_err:find("changed hunk", 1, true))
	assert(review_lsp.map_current_line(snapshot, current, 4) == 3)
end)

test("review definition options supersede older and unrouted requests and clear with their buffer", function()
	local current = vim.api.nvim_create_buf(false, true)
	local available = true
	local routed
	assert(review_lsp.mark(current, "current", {
		definition_options = function(win)
			assert(win == 17)
			return {
				valid = function()
					return available
				end,
				route = function(location)
					routed = location
					return true
				end,
			}
		end,
	}))
	local first = assert(review_lsp.definition_options(current, 17))
	assert(first.valid())
	local second = assert(review_lsp.definition_options(current, 17))
	assert(not first.valid() and second.valid(), "a newer gd did not supersede the previous request")
	assert(second.route({ path = "/tmp/target.lua", lnum = 2, col = 3 }))
	assert(routed.path == "/tmp/target.lua")
	available = false
	assert(not second.valid())
	available = true
	local metadata = assert(review_lsp._metadata[current])
	local provider = metadata.definition_options
	metadata.definition_options = function()
		return nil
	end
	assert(review_lsp.definition_options(current, 18) == nil)
	assert(not second.valid(), "an ordinary-window gd left the prior review request live")
	metadata.definition_options = provider
	local third = assert(review_lsp.definition_options(current, 17))
	assert(third.valid())
	review_lsp.clear(current)
	assert(not third.valid(), "clearing the review buffer left a definition request live")
	vim.api.nvim_buf_delete(current, { force = true })
end)

test("historical-new gd requests from hidden CURRENT and old never invokes LSP", function()
	local fixture = vim.fn.tempname()
	assert(vim.fn.mkdir(fixture, "p") == 1)
	local path = fixture .. "/sample.lua"
	assert(vim.fn.writefile({ "one", "changed", "three" }, path) == 0)
	local snapshot = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { "one", "two", "three" })
	local definitions = {}
	local routed
	review_lsp.mark(snapshot, "snapshot", {
		root = fixture,
		path = "sample.lua",
		definition_options = function()
			return {
				route = function(location)
					routed = location
					return true
				end,
			}
		end,
		definition = function(target, line, column, options)
			definitions[#definitions + 1] = { target, line, column, options }
			assert(options.valid() and options.route({ path = path, lnum = line, col = column }))
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
	assert(#definitions == 1 and definitions[1][1] == vim.fn.bufnr(path))
	assert(definitions[1][2] == 3 and definitions[1][3] == 7 and type(definitions[1][4]) == "table")
	assert(routed and routed.path == path and routed.lnum == 3 and routed.col == 7)
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
	timed_out = false
	review_lsp.mark(snapshot, "snapshot", {
		root = fixture,
		path = "sample.lua",
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
	assert(review_lsp.goto_definition(snapshot, 1, 1) and #deferred == 1)
	review_lsp.clear(snapshot)
	table.remove(deferred, 1)()
	assert(not timed_out and definitions == 0 and #deferred == 0, "cleared review request reached timeout or LSP")
	vim.api.nvim_buf_delete(snapshot, { force = true })
	vim.fn.delete(fixture, "rf")
end)

test("unified read-only LSP actions map NEW rows and reject OLD rows", function()
	local opened = {}
	local requests = {}
	local fixture = unified_fixture({
		current_text = "one\naéz\nthree\n",
		metadata = {
			lsp_ready = function()
				return true
			end,
			navigate = function(action, buf, line, column)
				requests[#requests + 1] = { action, buf, line, column }
			end,
			open = function(path, position)
				opened[#opened + 1] = { path, position }
			end,
		},
		new_text = "one\naéz\nthree\n",
		old_text = "one\naéx\nthree\n",
	})
	local new_display = fixture.projection.by_source.new[2]
	local old_display = fixture.projection.by_source.old[2]
	assert(new_display == 3 and old_display == 2)
	local position, position_err = review_lsp.resolve_current_position(fixture.display, new_display, 4)
	assert(position and position.buf == fixture.source and position.line == 2 and position.column == 4, position_err)
	local context = assert(review_lsp.resolve_current_position(fixture.display, 1, 2))
	assert(context.line == 1 and context.column == 2)

	for _, action in ipairs({ "definition", "declaration", "implementation", "references", "type_definition", "hover" }) do
		local ok, err = review_lsp.navigate(fixture.display, action, new_display, 4, fixture.metadata)
		assert(ok, err)
	end
	assert(vim.wait(200, function()
		return #requests == 6
	end))
	assert(#opened == 4, vim.inspect(opened))
	for index, action in ipairs({
		"definition",
		"declaration",
		"implementation",
		"references",
		"type_definition",
		"hover",
	}) do
		assert(vim.deep_equal(requests[index], { action, fixture.source, 2, 4 }), vim.inspect(requests))
	end
	local failed, old_err = review_lsp.navigate(fixture.display, "definition", old_display, 1, fixture.metadata)
	assert(failed == nil and old_err:find("OLD review rows", 1, true), old_err)
	assert(#opened == 4 and #requests == 6, "OLD row invoked current-source navigation")

	local expected = {
		K = "Review hover in current source",
		gD = "Review declaration in current source",
		gd = "Review definition in current source",
		gi = "Review implementation in current source",
		gr = "Review references in current source",
		gri = "Review implementation in current source",
		grr = "Review references in current source",
		grt = "Review type definition in current source",
	}
	for lhs, description in pairs(expected) do
		local mapping = vim.api.nvim_buf_call(fixture.display, function()
			return vim.fn.maparg(lhs, "n", false, true)
		end)
		assert(mapping.desc == description, lhs .. ": " .. vim.inspect(mapping))
	end
	for _, lhs in ipairs({ "gO", "grn", "grx", "gra", "<C-k>", "<leader>lr", "<leader>ca" }) do
		local mapping = vim.api.nvim_buf_call(fixture.display, function()
			return vim.fn.maparg(lhs, "n", false, true)
		end)
		assert(mapping.desc == "Historical review buffer has no LSP", lhs .. ": " .. vim.inspect(mapping))
	end
	vim.keymap.set("n", "gd", function() end, { buffer = fixture.display, desc = "Escaped LSP mapping" })
	review_lsp.setup()
	local detached
	local detach_client = vim.lsp.buf_detach_client
	vim.lsp.buf_detach_client = function(buf, client_id)
		detached = { buf, client_id }
		return true
	end
	vim.api.nvim_exec_autocmds("LspAttach", { buffer = fixture.display, data = { client_id = 991 } })
	vim.lsp.buf_detach_client = detach_client
	assert(vim.deep_equal(detached, { fixture.display, 991 }))
	assert(
		vim.wait(100, function()
			local mapping = vim.api.nvim_buf_call(fixture.display, function()
				return vim.fn.maparg("gd", "n", false, true)
			end)
			return mapping.desc == "Review definition in current source"
		end),
		"late LspAttach did not restore the safe unified bridge"
	)
	clear_unified_fixture(fixture)
end)

test("unified historical NEW mapping refuses changed, modified, and disk-diverged current source", function()
	local fixture = unified_fixture({
		current_text = "zero\none\nchanged\nthree\nfour\n",
		new_text = "one\ntwo\nthree\nfour\n",
		old_text = "one\ntwo\nthree\nfour\n",
	})
	local first = fixture.projection.by_source.new[1]
	local changed = fixture.projection.by_source.new[2]
	local third = fixture.projection.by_source.new[3]
	assert(assert(review_lsp.resolve_current_position(fixture.display, first)).line == 2)
	local missing, changed_err = review_lsp.resolve_current_position(fixture.display, changed)
	assert(missing == nil and changed_err:find("differs from the live CURRENT", 1, true), changed_err)
	assert(assert(review_lsp.resolve_current_position(fixture.display, third)).line == 4)

	vim.api.nvim_buf_set_lines(fixture.source, 0, 1, false, { "modified" })
	local modified, modified_err = review_lsp.resolve_current_position(fixture.display, first)
	assert(modified == nil and modified_err:find("unsaved changes", 1, true), modified_err)
	vim.bo[fixture.source].modified = false
	local disagreed, disagreement_err = review_lsp.resolve_current_position(fixture.display, first)
	assert(disagreed == nil and disagreement_err:find("differs from the file on disk", 1, true), disagreement_err)
	clear_unified_fixture(fixture)
end)

test("unified empty rows fail before opening or requesting CURRENT navigation", function()
	local opened = 0
	local requests = 0
	local fixture = unified_fixture({
		current_text = "",
		metadata = {
			lsp_ready = function()
				return true
			end,
			navigate = function()
				requests = requests + 1
			end,
			open = function()
				opened = opened + 1
			end,
		},
		new_text = "",
		old_text = "",
	})
	assert(fixture.projection.rows[1].kind == "empty")
	local ok, err = review_lsp.navigate(fixture.display, "definition", 1, 1, fixture.metadata)
	assert(ok == nil and err:find("no CURRENT source location", 1, true), err)
	assert(opened == 0 and requests == 0)
	clear_unified_fixture(fixture)
end)

test("an invalid later gd supersedes pending unified and snapshot definitions without full polling", function()
	local deferred = {}
	local requests = 0
	local pending_checks = 0
	local full_checks = 0
	local fixture = unified_fixture({
		current_text = "one\nnew\nthree\n",
		metadata = {
			defer = function(callback)
				deferred[#deferred + 1] = callback
			end,
			definition_options = function()
				return {
					pending = function()
						pending_checks = pending_checks + 1
						return true
					end,
					route = function()
						return true
					end,
					valid = function()
						full_checks = full_checks + 1
						return true
					end,
				}
			end,
			lsp_ready = function()
				return false
			end,
			navigate = function()
				requests = requests + 1
			end,
		},
		new_text = "one\nnew\nthree\n",
		old_text = "one\nold\nthree\n",
	})
	local new_display = assert(fixture.projection.by_source.new[2])
	local old_display = assert(fixture.projection.by_source.old[2])
	assert(review_lsp.navigate(fixture.display, "definition", new_display, 1, fixture.metadata))
	assert(#deferred == 1 and pending_checks == 1 and full_checks == 0)
	local rejected, rejected_err = review_lsp.navigate(fixture.display, "definition", old_display, 1, fixture.metadata)
	assert(rejected == nil and rejected_err:find("OLD review rows", 1, true))
	table.remove(deferred, 1)()
	assert(#deferred == 0 and requests == 0 and full_checks == 0)

	local snapshot = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { "one", "new", "three" })
	local snapshot_deferred = {}
	local snapshot_requests = 0
	assert(review_lsp.mark(snapshot, "snapshot", {
		root = fixture.directory,
		path = "sample.lua",
		definition = function()
			snapshot_requests = snapshot_requests + 1
		end,
		lsp_ready = function()
			return false
		end,
		defer = function(callback)
			snapshot_deferred[#snapshot_deferred + 1] = callback
		end,
	}))
	assert(review_lsp.goto_definition(snapshot, 1, 1) and #snapshot_deferred == 1)
	local invalid, invalid_err = review_lsp.goto_definition(snapshot, 0, 1)
	assert(invalid == nil and invalid_err:find("positive integer", 1, true))
	table.remove(snapshot_deferred, 1)()
	assert(#snapshot_deferred == 0 and snapshot_requests == 0)
	vim.api.nvim_buf_delete(snapshot, { force = true })
	clear_unified_fixture(fixture)
end)

test("an invalid later gd supersedes definitions already queued through vim.schedule", function()
	local fixture = unified_fixture({
		current_text = "one\nnew\nthree\n",
		metadata = {
			lsp_ready = function()
				return true
			end,
		},
		new_text = "one\nnew\nthree\n",
		old_text = "one\nold\nthree\n",
	})
	local original_schedule = vim.schedule
	local scheduled = {}
	local unified_requests = 0
	local snapshot_requests = 0
	local snapshot
	local ok, err = xpcall(function()
		fixture.metadata.navigate = function()
			unified_requests = unified_requests + 1
		end
		vim.schedule = function(callback)
			scheduled[#scheduled + 1] = callback
		end

		local new_display = assert(fixture.projection.by_source.new[2])
		local old_display = assert(fixture.projection.by_source.old[2])
		assert(review_lsp.navigate(fixture.display, "definition", new_display, 1, fixture.metadata))
		assert(#scheduled == 1 and unified_requests == 0)
		local rejected, rejected_err =
			review_lsp.navigate(fixture.display, "definition", old_display, 1, fixture.metadata)
		assert(rejected == nil and rejected_err:find("OLD review rows", 1, true))
		table.remove(scheduled, 1)()

		snapshot = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, { "one", "new", "three" })
		assert(review_lsp.mark(snapshot, "snapshot", {
			root = fixture.directory,
			path = "sample.lua",
			definition = function()
				snapshot_requests = snapshot_requests + 1
			end,
			lsp_ready = function()
				return true
			end,
		}))
		assert(review_lsp.goto_definition(snapshot, 1, 1))
		assert(#scheduled == 1 and snapshot_requests == 0)
		local invalid, invalid_err = review_lsp.goto_definition(snapshot, 0, 1)
		assert(invalid == nil and invalid_err:find("positive integer", 1, true))
		table.remove(scheduled, 1)()

		assert(
			unified_requests == 0 and snapshot_requests == 0,
			vim.inspect({ unified_requests = unified_requests, snapshot_requests = snapshot_requests })
		)
	end, debug.traceback)
	vim.schedule = original_schedule
	if snapshot and vim.api.nvim_buf_is_valid(snapshot) then
		review_lsp.clear(snapshot)
		vim.api.nvim_buf_delete(snapshot, { force = true })
	end
	clear_unified_fixture(fixture)
	assert(ok, err)
end)

test("unified LSP bridge revalidates source and mapping after waiting for a client", function()
	local requests = 0
	local opened = 0
	local notifications = {}
	local fixture = unified_fixture({
		current_text = "one\ntwo\n",
		metadata = {
			lsp_ready = function()
				return true
			end,
			navigate = function()
				requests = requests + 1
			end,
			open = function()
				opened = opened + 1
			end,
		},
		new_text = "one\ntwo\n",
		old_text = "one\ntwo\n",
	})
	local notify = vim.notify
	vim.notify = function(message)
		notifications[#notifications + 1] = message
	end
	assert(review_lsp.navigate(fixture.display, "definition", 1, 2, fixture.metadata))
	assert(opened == 0 and requests == 0)
	write_file(fixture.path, "changed\ntwo\n")
	vim.api.nvim_buf_set_lines(fixture.source, 0, 1, false, { "changed" })
	vim.bo[fixture.source].modified = false
	vim.wait(100, function()
		return requests > 0
	end)
	vim.notify = notify
	assert(requests == 0, "LSP request escaped post-wait source revalidation")
	assert(
		vim.iter(notifications):any(function(message)
			return message:find("frozen NEW", 1, true) ~= nil
		end),
		vim.inspect(notifications)
	)
	clear_unified_fixture(fixture)
end)

test("unified diagnostics mirror complete visible NEW ranges and inherit the global toggle", function()
	local source_namespace = vim.api.nvim_create_namespace("NvimReviewLspSpecSource")
	local fixture = unified_fixture({
		context = "hunks",
		current_text = "one\nnew\nthree\nfour\n",
		new_text = "one\nnew\nthree\nfour\n",
		old_text = "one\nold\nthree\nfour\n",
		visible_sections = { { first = 3, last = 4 } },
	})
	vim.diagnostic.set(source_namespace, fixture.source, {
		{
			_tags = { deprecated = true, unnecessary = false },
			code = "E1",
			col = 1,
			end_col = 3,
			end_lnum = 1,
			lnum = 1,
			message = "single",
			severity = vim.diagnostic.severity.ERROR,
			source = "review-lsp-spec",
			user_data = { marker = "preserved" },
		},
		{ col = 0, end_col = 2, end_lnum = 2, lnum = 1, message = "multi" },
		{ col = 0, end_col = 1, end_lnum = 1, lnum = 0, message = "crosses OLD" },
		{ col = 0, end_col = 0, end_lnum = 3, lnum = 1, message = "half open" },
		{ col = 0, end_col = 2, end_lnum = 3, lnum = 3, message = "concealed" },
	})
	local mirrored
	assert(
		vim.wait(300, function()
			mirrored = vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace })
			return #mirrored == 3
		end),
		vim.inspect(mirrored)
	)
	assert(#vim.diagnostic.get(fixture.source, { namespace = source_namespace }) == 5)
	local by_message = {}
	for _, diagnostic in ipairs(mirrored) do
		by_message[diagnostic.message] = diagnostic
	end
	assert(by_message["crosses OLD"] == nil and by_message.concealed == nil, vim.inspect(by_message))
	local single = assert(by_message.single)
	assert(single.lnum == 2 and single.end_lnum == 2 and single.col == 1 and single.end_col == 3)
	assert(single.severity == vim.diagnostic.severity.ERROR and single.source == "review-lsp-spec")
	assert(single.code == "E1" and single.user_data.marker == "preserved", vim.inspect(single))
	assert(single._tags.deprecated and not single._tags.unnecessary, vim.inspect(single))
	local multi = assert(by_message.multi)
	assert(multi.lnum == 2 and multi.end_lnum == 3 and multi.end_col == 2, vim.inspect(multi))
	local half_open = assert(by_message["half open"])
	assert(half_open.lnum == 2 and half_open.end_lnum == 4 and half_open.end_col == 0, vim.inspect(half_open))

	local diagnostic_config = vim.diagnostic.config()
	assert(next(vim.diagnostic.config(nil, review_lsp._diagnostic_namespace)) == nil)
	vim.diagnostic.config({ virtual_lines = false })
	assert(vim.diagnostic.config().virtual_lines == false)
	assert(next(vim.diagnostic.config(nil, review_lsp._diagnostic_namespace)) == nil)
	vim.diagnostic.config({ virtual_lines = true })
	assert(vim.diagnostic.config().virtual_lines == true)
	assert(next(vim.diagnostic.config(nil, review_lsp._diagnostic_namespace)) == nil)
	vim.diagnostic.config(diagnostic_config)

	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 2, end_lnum = 1, lnum = 1, message = "replacement" },
	})
	assert(vim.wait(300, function()
		local values = vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace })
		return #values == 1 and values[1].message == "replacement"
	end))
	vim.b[fixture.display].nvim_review_projection_generation = fixture.metadata.generation + 1
	local refreshed, generation_err = review_lsp.refresh_diagnostics(fixture.display)
	assert(refreshed == nil and generation_err:find("generation changed", 1, true), generation_err)
	assert(#vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace }) == 0)
	vim.b[fixture.display].nvim_review_projection_generation = fixture.metadata.generation
	assert(review_lsp.refresh_diagnostics(fixture.display))
	write_file(fixture.path, "disk drift\n")
	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 1, end_lnum = 1, lnum = 1, message = "must clear" },
	})
	assert(
		vim.wait(300, function()
			return #vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace }) == 0
		end),
		"diagnostic mirror survived disk drift"
	)
	local source_diagnostics = vim.diagnostic.get(fixture.source, { namespace = source_namespace })
	assert(#source_diagnostics == 1 and source_diagnostics[1].message == "must clear")
	vim.diagnostic.reset(source_namespace, fixture.source)
	clear_unified_fixture(fixture)
end)

test("unified diagnostics omit CURRENT ranges that do not map to frozen NEW", function()
	local source_namespace = vim.api.nvim_create_namespace("NvimReviewLspSpecDriftedSource")
	local fixture = unified_fixture({
		current_text = "zero\none\nchanged\nthree\nfour\n",
		new_text = "one\ntwo\nthree\nfour\n",
		old_text = "one\ntwo\nthree\nfour\n",
	})
	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 3, end_lnum = 2, lnum = 2, message = "changed" },
		{ col = 0, end_col = 3, end_lnum = 3, lnum = 3, message = "unchanged" },
	})
	local mirrored
	assert(
		vim.wait(300, function()
			mirrored = vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace })
			return #mirrored == 1
		end),
		vim.inspect(mirrored)
	)
	assert(mirrored[1].message == "unchanged" and mirrored[1].lnum == 2, vim.inspect(mirrored))
	vim.diagnostic.reset(source_namespace, fixture.source)
	clear_unified_fixture(fixture)
end)

test("unified diagnostic mirror recovers after an initially modified CURRENT source is reconciled", function()
	local prepared_source
	local source_namespace = vim.api.nvim_create_namespace("NvimReviewLspSpecRecoveredSource")
	local fixture = unified_fixture({
		current_text = "one\nnew\nthree\n",
		new_text = "one\nnew\nthree\n",
		old_text = "one\nold\nthree\n",
		prepare_source = function(path)
			prepared_source = vim.fn.bufadd(path)
			vim.fn.bufload(prepared_source)
			vim.api.nvim_buf_set_lines(prepared_source, 1, 2, false, { "unsaved" })
			assert(vim.bo[prepared_source].modified)
		end,
	})
	assert(fixture.source == prepared_source and review_lsp._mirrors[fixture.display])
	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 2, end_lnum = 1, lnum = 1, message = "recoverable" },
	})
	vim.wait(100)
	assert(#vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace }) == 0)
	vim.api.nvim_buf_set_lines(fixture.source, 1, 2, false, { "new" })
	vim.bo[fixture.source].modified = false
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = fixture.source })
	assert(
		vim.wait(300, function()
			local values = vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace })
			return #values == 1 and values[1].message == "recoverable"
		end),
		"diagnostic mirror did not recover after CURRENT matched disk again"
	)
	vim.diagnostic.reset(source_namespace, fixture.source)
	clear_unified_fixture(fixture)
end)

test("unified diagnostic refreshes coalesce and clean up on either buffer wipe", function()
	local reads = 0
	local fixture = unified_fixture({
		current_text = "one\n",
		metadata = {
			get_diagnostics = function()
				reads = reads + 1
				return {}
			end,
		},
		new_text = "one\n",
		old_text = "one\n",
	})
	assert(vim.wait(200, function()
		return reads == 1
	end))
	for _ = 1, 4 do
		vim.api.nvim_exec_autocmds("DiagnosticChanged", { buffer = fixture.source })
	end
	assert(
		vim.wait(200, function()
			return reads == 2
		end),
		("expected one coalesced refresh, got %d reads"):format(reads)
	)
	vim.api.nvim_buf_delete(fixture.source, { force = true })
	assert(
		vim.wait(100, function()
			return review_lsp._mirrors[fixture.display] == nil
		end),
		"source wipe retained diagnostic mirror ownership"
	)
	clear_unified_fixture(fixture)

	local destination_fixture = unified_fixture({
		current_text = "one\n",
		new_text = "one\n",
		old_text = "one\n",
	})
	local destination = destination_fixture.display
	assert(review_lsp._mirrors[destination])
	vim.api.nvim_buf_delete(destination, { force = true })
	assert(
		vim.wait(100, function()
			return review_lsp._mirrors[destination] == nil
		end),
		"destination wipe retained diagnostic mirror ownership"
	)
	clear_unified_fixture(destination_fixture)
end)

test("unified diagnostics preserve half-open ranges ending after an empty NEW row", function()
	local source_namespace = vim.api.nvim_create_namespace("NvimReviewLspSpecEmptyRange")
	local fixture = unified_fixture({
		current_text = "head\nstart\n\nend\n",
		new_text = "head\nstart\n\nend\n",
		old_text = "head\nstart\n\nend\n",
	})
	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 0, end_lnum = 3, lnum = 1, message = "through empty" },
	})
	local mirrored
	assert(
		vim.wait(300, function()
			mirrored = vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace })
			return #mirrored == 1
		end),
		vim.inspect(mirrored)
	)
	assert(mirrored[1].lnum == 1 and mirrored[1].end_lnum == 3 and mirrored[1].end_col == 0, vim.inspect(mirrored))
	vim.diagnostic.reset(source_namespace, fixture.source)
	clear_unified_fixture(fixture)
end)

test("unified projection metadata refuses mismatched CURRENT paths and missing hunk visibility", function()
	local fixture = unified_fixture({
		context = "hunks",
		current_text = "one\nnew\nthree\n",
		new_text = "one\nnew\nthree\n",
		old_text = "one\nold\nthree\n",
	})
	local source_namespace = vim.api.nvim_create_namespace("NvimReviewLspSpecVisibility")
	vim.diagnostic.set(source_namespace, fixture.source, {
		{ col = 0, end_col = 2, end_lnum = 1, lnum = 1, message = "hidden without visibility metadata" },
	})
	vim.wait(100)
	assert(#vim.diagnostic.get(fixture.display, { namespace = review_lsp._diagnostic_namespace }) == 0)

	vim.b[fixture.display].nvim_review_projection_generation = nil
	local stale, stale_err =
		review_lsp.resolve_current_position(fixture.display, fixture.projection.by_source.new[2], 1, fixture.metadata)
	assert(stale == nil and stale_err:find("generation changed", 1, true), stale_err)
	vim.b[fixture.display].nvim_review_projection_generation = fixture.metadata.generation
	local other_path = fixture.directory .. "/other.lua"
	write_file(other_path, "one\nnew\nthree\n")
	fixture.metadata.current_path = "other.lua"
	local position, position_err =
		review_lsp.resolve_current_position(fixture.display, fixture.projection.by_source.new[2], 1, fixture.metadata)
	assert(position == nil and position_err:find("NEW path", 1, true), position_err)
	vim.diagnostic.reset(source_namespace, fixture.source)
	clear_unified_fixture(fixture)
end)

test("explicit location requests keep their target buffer and per-client encoding", function()
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
	local picked = {}
	local encodings = {}
	local expected_method
	local expected_references
	local ok, err = xpcall(function()
		vim.lsp.get_clients = function(options)
			assert(options.bufnr == target and options.method == expected_method)
			return clients
		end
		vim.lsp.get_client_by_id = function(id)
			return id == 31 and clients[1] or clients[2]
		end
		vim.lsp.buf_request_all = function(buf, method, params, callback)
			assert(buf == target and method == expected_method)
			local utf8 = params(clients[1])
			local utf16 = params(clients[2])
			assert(utf8.textDocument.uri == vim.uri_from_bufnr(target))
			assert(utf16.textDocument.uri == vim.uri_from_bufnr(target))
			assert(utf8.position.line == 0 and utf8.position.character == 3)
			assert(utf16.position.line == 0 and utf16.position.character == 2)
			assert((utf8.context and utf8.context.includeDeclaration or false) == expected_references)
			assert((utf16.context and utf16.context.includeDeclaration or false) == expected_references)
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
					picked[#picked + 1] = options
				end,
			},
		}
		for action, method in pairs({
			declaration = "textDocument/declaration",
			definition = "textDocument/definition",
			implementation = "textDocument/implementation",
			references = "textDocument/references",
			type_definition = "textDocument/typeDefinition",
		}) do
			expected_method = method
			expected_references = action == "references"
			assert(lsp_navigation.location_at(action, target, 1, 4))
		end
		assert(vim.api.nvim_get_current_buf() == other)
		assert(#picked == 5)
		for _, options in ipairs(picked) do
			assert(#options.items == 2)
		end
		table.sort(encodings)
		assert(vim.deep_equal(encodings, {
			"utf-16",
			"utf-16",
			"utf-16",
			"utf-16",
			"utf-16",
			"utf-8",
			"utf-8",
			"utf-8",
			"utf-8",
			"utf-8",
		}))
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

test("definition results route from CURRENT review panes with picker-time revalidation", function()
	local target = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(target, 0, -1, false, { "definition source" })
	vim.api.nvim_set_current_buf(target)
	local editor = require("config.editor")
	local client = { id = 61, offset_encoding = "utf-16" }
	local originals = {
		definition = vim.lsp.buf.definition,
		get_clients = vim.lsp.get_clients,
		open_file_in_tab = editor.open_file_in_tab,
		snacks = package.loaded.snacks,
	}
	local opened = {}
	local routed = {}
	local picker
	local request_items = {}
	local route_enabled = true
	local route_error
	local route_throws = false
	local route_valid = true
	local validation_calls = 0
	local ok, err = xpcall(function()
		assert(review_lsp.mark(target, "current", {
			definition_options = function(win)
				assert(win == vim.api.nvim_get_current_win())
				return {
					valid = function()
						validation_calls = validation_calls + 1
						return route_valid
					end,
					route = function(location)
						routed[#routed + 1] = location
						if route_throws then
							error("simulated route failure")
						elseif route_error then
							return false, route_error
						end
						return route_enabled
					end,
				}
			end,
		}))
		vim.lsp.get_clients = function(options)
			assert(options.bufnr == target and options.method == "textDocument/definition")
			return { client }
		end
		vim.lsp.buf.definition = function(options)
			options.on_list({ items = request_items })
		end
		editor.open_file_in_tab = function(path, position)
			opened[#opened + 1] = { path = path, position = position }
		end
		package.loaded.snacks = {
			picker = {
				pick = function(options)
					picker = options
				end,
			},
		}

		request_items = { { filename = "/tmp/in-review.lua", lnum = 4, col = 7 } }
		assert(lsp_navigation.definition())
		assert(#routed == 1 and routed[1].path == "/tmp/in-review.lua" and #opened == 0)
		assert(validation_calls == 2, "a direct definition performed redundant full revalidation")

		route_enabled = false
		request_items = { { filename = "/tmp/outside.lua", lnum = 8, col = 2 } }
		assert(lsp_navigation.definition())
		assert(#routed == 2 and #opened == 1)
		assert(opened[1].path == "/tmp/outside.lua" and opened[1].position.lnum == 8)

		route_enabled = true
		route_error = "simulated closed routing failure"
		request_items = { { filename = "/tmp/must-not-fallback.lua", lnum = 3, col = 1 } }
		assert(lsp_navigation.definition())
		assert(#opened == 1, "a reported review routing failure escaped to ordinary navigation")
		route_error = nil
		route_throws = true
		request_items = { { filename = "/tmp/must-not-escape.lua", lnum = 4, col = 1 } }
		assert(lsp_navigation.definition())
		assert(#opened == 1, "a throwing review router escaped to ordinary navigation")
		route_throws = false

		request_items = {
			{ filename = "/tmp/first.lua", lnum = 1, col = 1 },
			{ filename = "/tmp/second.lua", lnum = 9, col = 5 },
		}
		assert(lsp_navigation.definition())
		assert(type(picker.confirm) == "function" and #picker.items == 2)
		local closed = false
		picker.confirm({
			close = function()
				closed = true
			end,
		}, picker.items[2])
		assert(closed and #routed == 5 and routed[5].path == "/tmp/second.lua")

		request_items = {
			{ filename = "/tmp/stale-one.lua", lnum = 1, col = 1 },
			{ filename = "/tmp/stale-two.lua", lnum = 2, col = 1 },
		}
		assert(lsp_navigation.definition())
		local stale_picker = picker
		request_items = { { filename = "/tmp/newer.lua", lnum = 6, col = 2 } }
		assert(lsp_navigation.definition())
		assert(#routed == 6 and routed[6].path == "/tmp/newer.lua")
		stale_picker.confirm({ close = function() end }, stale_picker.items[1])
		assert(#routed == 6 and #opened == 1, "an older picker survived a newer gd")
	end, debug.traceback)
	vim.lsp.buf.definition = originals.definition
	vim.lsp.get_clients = originals.get_clients
	editor.open_file_in_tab = originals.open_file_in_tab
	package.loaded.snacks = originals.snacks
	review_lsp.clear(target)
	vim.api.nvim_buf_delete(target, { force = true })
	assert(ok, err)
end)

test("explicit hover requests source coordinates without leaving the review window", function()
	local source = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "aéz" })
	local review = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(review)
	local review_win = vim.api.nvim_get_current_win()
	local client = { id = 51, name = "hover-client", offset_encoding = "utf-16" }
	local originals = {
		buf_request_all = vim.lsp.buf_request_all,
		convert_input_to_markdown_lines = vim.lsp.util.convert_input_to_markdown_lines,
		get_client_by_id = vim.lsp.get_client_by_id,
		get_clients = vim.lsp.get_clients,
		open_floating_preview = vim.lsp.util.open_floating_preview,
	}
	local floated
	local ok, err = xpcall(function()
		vim.lsp.get_clients = function(options)
			assert(options.bufnr == source and options.method == "textDocument/hover")
			return { client }
		end
		vim.lsp.get_client_by_id = function(id)
			return id == client.id and client or nil
		end
		vim.lsp.buf_request_all = function(buf, method, params, callback)
			assert(buf == source and method == "textDocument/hover")
			local value = params(client)
			assert(value.textDocument.uri == vim.uri_from_bufnr(source))
			assert(value.position.line == 0 and value.position.character == 2)
			callback({ [client.id] = { result = { contents = "hover value" } } })
		end
		vim.lsp.util.convert_input_to_markdown_lines = function()
			return { "hover value" }
		end
		vim.lsp.util.open_floating_preview = function(contents, syntax, options)
			floated = {
				buf = vim.api.nvim_get_current_buf(),
				contents = contents,
				options = options,
				syntax = syntax,
				win = vim.api.nvim_get_current_win(),
			}
		end
		assert(lsp_navigation.hover_at(source, 1, 4, { winid = review_win }))
		assert(vim.api.nvim_get_current_buf() == review)
		assert(floated and floated.win == review_win and floated.buf == review, vim.inspect(floated))
		assert(floated.syntax == "markdown" and floated.options.border == "rounded")
		assert(vim.deep_equal(floated.contents, { "hover value" }))
	end, debug.traceback)
	vim.lsp.buf_request_all = originals.buf_request_all
	vim.lsp.util.convert_input_to_markdown_lines = originals.convert_input_to_markdown_lines
	vim.lsp.get_client_by_id = originals.get_client_by_id
	vim.lsp.get_clients = originals.get_clients
	vim.lsp.util.open_floating_preview = originals.open_floating_preview
	local replacement = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(replacement)
	vim.api.nvim_buf_delete(source, { force = true })
	vim.api.nvim_buf_delete(review, { force = true })
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
