local equal = require("tests.helpers").equal
local sources = require("config.diagram_rex_source")
local extract = require("diagram_view.source").extract
local T = MiniTest.new_set()
local buffers, watchers = {}, {}

local function document(lines, filetype)
	local buf = vim.api.nvim_create_buf(false, true)
	buffers[#buffers + 1] = buf
	vim.bo[buf].filetype = filetype or "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return { bufnr = buf, row = 2 }
end

local function watch(target, callback)
	local diagram = assert(extract(target))
	local watcher = sources.watch(target, diagram, callback or function() end)
	watchers[#watchers + 1] = watcher
	return watcher
end

T["live source follows its extmarks, not cursor or neighbouring fences"] = function()
	local target = document({ "```mermaid", "A --> B", "```", "", "```mermaid", "OTHER", "```" })
	local observed = {}
	local watcher = watch(target, function(item, err)
		observed[#observed + 1] = { item, err }
	end)
	vim.api.nvim_set_current_buf(target.bufnr)
	vim.api.nvim_win_set_cursor(0, { 6, 0 })
	vim.api.nvim_buf_set_lines(target.bufnr, 0, 0, false, { "Heading", "" })
	vim.api.nvim_buf_set_text(target.bufnr, 3, 6, 3, 7, { "C" })
	assert(vim.wait(600, function()
		return #observed == 1
	end))
	equal("A --> C", observed[1][1].source)
	equal(3, watcher:read().origin.start_row)
	assert(watcher:matches({ bufnr = target.bufnr, row = 4 }, assert(extract({ bufnr = target.bufnr, row = 4 }))))
	assert(not watcher:matches({ bufnr = target.bufnr, row = 8 }, assert(extract({ bufnr = target.bufnr, row = 8 }))))
end

T["incomplete fences keep their identity and recover after correction"] = function()
	local target = document({ "```mermaid", "A --> B", "```", "", "```mermaid", "OTHER", "```" })
	local watcher = watch(target)
	vim.api.nvim_buf_set_text(target.bufnr, 2, 0, 2, 3, { "xx" })
	local item, err = watcher:read()
	assert(item == nil and err:find("fence"))
	vim.api.nvim_buf_set_text(target.bufnr, 2, 0, 2, 2, { "```" })
	equal("A --> B", assert(watcher:read()).source)
	vim.api.nvim_buf_set_lines(target.bufnr, 0, 3, false, {})
	assert(watcher:read() == nil, "a removed diagram switched to a different block")
end

T["selections and PlantUML buffers observe unsaved content; review snapshots stay frozen"] = function()
	local target = document({ "intro", "A --> B", "B --> C", "tail" })
	target.selection = { start_row = 2, end_row = 3 }
	local selected = watch(target)
	vim.api.nvim_buf_set_text(target.bufnr, 2, 6, 2, 7, { "D" })
	equal("A --> B\nB --> D", selected:read().source)
	local uml = document({ "@startuml", "A -> B", "@enduml" }, "plantuml")
	local whole = watch(uml)
	vim.api.nvim_buf_set_lines(uml.bufnr, 1, 2, false, { "A -> C", "C -> D" })
	equal("@startuml\nA -> C\nC -> D\n@enduml", whole:read().source)
	local snapshot =
		{ bufnr = uml.bufnr, filetype = "plantuml", lines = { "@startuml", "FROZEN", "@enduml" }, frozen = true }
	local frozen = watch(snapshot)
	vim.api.nvim_buf_set_lines(uml.bufnr, 0, -1, false, { "changed" })
	equal("@startuml\nFROZEN\n@enduml", frozen:read().source)
end

T["stopping an observer suppresses queued edits"] = function()
	local target = document({ "```mermaid", "A --> B", "```" })
	local calls = 0
	local watcher = watch(target, function()
		calls = calls + 1
	end)
	vim.api.nvim_buf_set_text(target.bufnr, 1, 6, 1, 7, { "C" })
	watcher:stop()
	vim.wait(250, function()
		return calls > 0
	end)
	equal(0, calls)
end

T["identical diagrams in different frozen documents have different source identities"] = function()
	local target = {
		frozen = true,
		path = "one.md",
		side = "new",
		filetype = "markdown",
		row = 2,
		lines = { "```mermaid", "A --> B", "```" },
	}
	local watcher = watch(target)
	assert(watcher:matches(vim.deepcopy(target), assert(extract(target))))
	for _, change in ipairs({
		{ path = "two.md" },
		{ side = "old" },
		{ lines = { "```mermaid", "A --> B", "```", "Different snapshot" } },
	}) do
		local other = vim.tbl_extend("force", target, change)
		assert(not watcher:matches(other, assert(extract(other))), "a different review source preserved zoom")
	end
end

T["undo restores a deleted source range"] = function()
	local target = document({ "```mermaid", "A --> B", "```", "tail" })
	vim.bo[target.bufnr].undolevels = -1
	vim.api.nvim_buf_set_lines(target.bufnr, 3, 4, false, { "tail" })
	vim.bo[target.bufnr].undolevels = 1000
	local watcher = watch(target)
	vim.api.nvim_buf_set_lines(target.bufnr, 0, 3, false, {})
	assert(watcher:read() == nil)
	vim.api.nvim_buf_call(target.bufnr, function()
		vim.cmd("silent undo")
	end)
	equal("A --> B", assert(watcher:read()).source)
end

T["host reuses one viewer and sends structured updates without stealing focus"] = function()
	local original_rex, original_paths = package.loaded.rex, package.loaded["config.tool_paths"]
	local original_runtime, original_connect, original_notify =
		vim.api.nvim_get_runtime_file, vim.fn.sockconnect, vim.rpcnotify
	local requests, messages, focus, closed = {}, {}, 0, false
	package.loaded.rex = {
		setup = function()
			return true
		end,
		context = function(callback)
			callback(nil, { session_id = "source-session", window_id = "source-window", block_id = "source-block" })
		end,
		open_float = function(options, callback)
			requests[#requests + 1] = options
			callback(nil, { layer_id = "owned-layer" })
		end,
		focus = function(_, callback)
			focus = focus + 1
			callback()
		end,
		close = function(_, callback)
			requests[1].on_close()
			callback()
		end,
		teardown = function()
			closed = true
			requests[1].on_close()
		end,
		status = function()
			return { pending = 0, records = closed and {} or { {} } }
		end,
	}
	package.loaded["config.tool_paths"] = {
		external_executable = function()
			return "/rex"
		end,
	}
	vim.api.nvim_get_runtime_file = function(path)
		return { "/installed/" .. path }
	end
	vim.fn.sockconnect = function()
		return 999
	end
	vim.rpcnotify = function(_, method, code, args)
		equal("nvim_exec_lua", method)
		equal("NvimRexDiagram.update(...)", code)
		messages[#messages + 1] = vim.deepcopy(args[1])
	end
	package.loaded["config.diagram_rex"] = nil
	local adapter = require("config.diagram_rex")
	local ok, err = xpcall(function()
		local target = document({ "```mermaid", "A --> B", "```" })
		local options = {
			config = { max_stage_output_bytes = 16777216 },
			cache_root = "/tmp/cache",
			resolve_executable = function(name)
				return "/tools/" .. name
			end,
			fallback = function()
				error("unexpected fallback")
			end,
		}
		adapter.show(target, assert(extract(target)), "svg", options)
		assert(vim.wait(600, function()
			return #messages == 1
		end))
		equal(1, #requests)
		equal("source-window", requests[1].context.window_id)
		assert(not table.concat(requests[1].command, " "):find("A --> B", 1, true))
		local directory = vim.fs.dirname(adapter.status().socket)
		equal(448, vim.uv.fs_stat(directory).mode % 512)
		equal(384, vim.uv.fs_stat(directory .. "/profile.json").mode % 512)
		vim.api.nvim_buf_set_text(target.bufnr, 1, 6, 1, 7, { "C" })
		assert(vim.wait(600, function()
			return #messages == 2
		end))
		equal("A --> C", messages[2].diagram.source)
		equal(false, messages[2].reset)
		equal(0, focus)
		adapter.show(target, assert(extract(target)), "svg", options)
		equal(1, #requests)
		equal(1, focus)
		equal(false, messages[3].reset)
		local other = document({ "```mermaid", "NEW --> DIAGRAM", "```" })
		adapter.show(other, assert(extract(other)), "ascii", options)
		equal(true, messages[4].reset)
		equal(1, #requests)
		requests[1].on_close()
		assert(adapter.status() == nil)
		assert(vim.uv.fs_stat(directory) == nil, "private IPC directory was left behind")
	end, debug.traceback)
	adapter.teardown()
	vim.api.nvim_get_runtime_file, vim.fn.sockconnect, vim.rpcnotify =
		original_runtime, original_connect, original_notify
	package.loaded.rex, package.loaded["config.tool_paths"] = original_rex, original_paths
	assert(ok, err)
end

T.hooks = {
	post_once = function()
		for _, watcher in ipairs(watchers) do
			watcher:stop()
		end
		for _, buf in ipairs(buffers) do
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end,
}
return T
