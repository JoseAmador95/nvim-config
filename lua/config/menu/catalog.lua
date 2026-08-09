local M = {}

local cmake_filetypes = {
	c = true,
	cmake = true,
	cpp = true,
}

local function is_filetype(filetype)
	return function(context)
		return context.filetype == filetype
	end
end

local function descriptor(dispatch, id, label, hint, when)
	local item = {
		id = id,
		label = label,
		run = function()
			return dispatch(id)
		end,
	}
	if hint then
		item.hint = hint
	end
	if when then
		item.when = when
	end
	return item
end

local function section(id, label, items, when)
	return {
		id = id,
		label = label,
		items = items,
		when = when,
	}
end

---Return every menu descriptor before context filtering.
---@param dispatch fun(id: string): any
---@return table[]
function M.definitions(dispatch)
	assert(type(dispatch) == "function", "menu dispatch must be a function")
	local item = function(id, label, hint, when)
		return descriptor(dispatch, id, label, hint, when)
	end

	return {
		section("search", "Search / Replace", {
			item("search.open", "Search & Replace: Open"),
			item("search.word", "Search & Replace: Search Word"),
			item("search.selection", "Search & Replace: Search Selection", nil, function(context)
				return context.visual
			end),
			item("search.file", "Search & Replace: Search in File"),
			item("picker.live_grep", "Live Grep"),
			item("picker.grep_string", "Grep String (cursor)"),
		}),
		section("navigation", "Navigation", {
			item("picker.find_files", "Find Files"),
			item("picker.oldfiles", "Recent Files"),
			item("picker.buffers", "Buffers"),
			item("picker.help_tags", "Help Tags"),
			item("picker.command_history", "Command History"),
			item("picker.git_commits", "Git Commits"),
			item("picker.git_bcommits", "File History"),
		}),
		section("lsp", "LSP", {
			item("lsp.definition", "Go to Definition", "gd"),
			item("lsp.declaration", "Go to Declaration", "gD"),
			item("picker.lsp_references", "References"),
			item("picker.lsp_implementations", "Implementation"),
			item("picker.lsp_type_definitions", "Type Definition"),
			item("picker.lsp_document_symbols", "Document Symbols"),
			item("picker.lsp_workspace_symbols", "Workspace Symbols"),
			item("lsp.incoming_calls", "Incoming Calls"),
			item("lsp.outgoing_calls", "Outgoing Calls"),
			item("lsp.rename", "Rename"),
			item("lsp.code_action", "Code Actions"),
			item("command.toggle_inlay_hints", "Toggle Inlay Hints"),
			item("command.toggle_inline_diagnostics", "Toggle Inline Diagnostics"),
			item("lsp.format", "Format"),
		}),
		section("git", "Git", {
			item("gitsigns.preview_hunk", "Preview Hunk"),
			item("gitsigns.stage_hunk", "Stage/Unstage Hunk"),
			item("gitsigns.reset_hunk", "Reset Hunk"),
			item("gitsigns.stage_buffer", "Stage Buffer"),
			item("gitsigns.reset_buffer", "Reset Buffer"),
			item("gitsigns.diffthis", "Diff This"),
			item("gitsigns.toggle_deleted", "Toggle Deleted"),
			item("gitsigns.toggle_current_line_blame", "Toggle Line Blame"),
			item("gitsigns.next_hunk", "Next Hunk", "]h"),
			item("gitsigns.prev_hunk", "Prev Hunk", "[h"),
			item("command.lazygit", "LazyGit", "<leader>gl"),
			item("command.diffview_open", "Diffview Open"),
			item("command.diffview_file_history", "Diffview File History"),
		}),
		section("tests", "Tests", {
			item("test.nearest", "Run Nearest"),
			item("test.file", "Run File", nil, function(context)
				return not cmake_filetypes[context.filetype]
			end),
			item("test.last", "Run Last"),
			item("test.stop", "Stop"),
			item("test.output_panel", "Toggle Output Panel"),
			item("test.summary", "Toggle Summary"),
			item("test.next_failed", "Next Failed"),
			item("test.prev_failed", "Prev Failed"),
		}),
		section("cmake", "CMake", {
			item("command.cmake_generate", "Generate"),
			item("command.cmake_build", "Build"),
			item("command.cmake_run", "Run"),
			item("command.cmake_debug", "Debug"),
			item("command.cmake_test", "Run Tests (CTest)"),
			item("command.cmake_build_target", "Select Build Target"),
			item("command.cmake_launch_target", "Select Launch Target"),
			item("command.cmake_build_type", "Select Build Type"),
			item("command.cmake_configure_preset", "Select Configure Preset"),
		}, function(context)
			return cmake_filetypes[context.filetype] == true
		end),
		section("debug", "Debug", {
			item("dap.continue", "Continue", "F5"),
			item("dap.toggle_breakpoint", "Toggle Breakpoint", "<leader>db"),
			item("dap.conditional_breakpoint", "Conditional Breakpoint"),
			item("dap.run_to_cursor", "Run to Cursor"),
			item("dap.run_last", "Run Last"),
			item("dap.step_over", "Step Over", "F10"),
			item("dap.step_into", "Step Into", "F11"),
			item("dap.step_out", "Step Out", "F12"),
			item("dap.terminate", "Terminate"),
			item("dap.clear_breakpoints", "Clear Breakpoints"),
			item("dapui.toggle", "Toggle DAP UI", "<leader>du"),
			item("dapui.eval", "Eval Expression"),
		}),
		section("format", "Format", {
			item("format.buffer", "Format Buffer"),
			item("command.format_toggle", "Toggle Autoformat (global)"),
			item("command.format_toggle_buffer", "Toggle Autoformat (buffer)"),
			item("command.conform_info", "Conform Info"),
		}),
		section("sessions", "Sessions", {
			item("session.save", "Save Current Project", "<leader>Ss"),
			item("session.restore", "Restore Current Project", "<leader>Sr"),
			item("session.search", "Search and Restore", "<leader>Sp"),
			item("session.delete", "Delete Session", "<leader>Sd"),
		}),
		section("just", "Just", {
			item("command.just_run", "Run Recipe"),
			item("command.just_import_last", "Import Last Locations"),
		}),
		section("log_highlights", "Log Highlights", {
			item("log.highlight_exact", "Add Highlight (exact)"),
			item("log.highlight_regex", "Add Highlight (regex)"),
			item("command.log_highlight_clear", "Clear All Highlights"),
		}),
		section("devcontainer", "Devcontainer", {
			item("command.devcontainer_shell", "Shell"),
			item("command.devcontainer_workspace", "Set Workspace"),
		}),
		section("file.plantuml", "File (plantuml)", {
			item("command.diagram_show", "Show Diagram", "<leader>md"),
		}, is_filetype("plantuml")),
		section("file.json", "File (json)", {
			item("command.json_tree", "JSON Tree"),
			item("json.jqx_query", "JQX Query"),
		}, is_filetype("json")),
		section("file.markdown", "File (markdown)", {
			item("command.diagram_show", "Show Diagram", "<leader>md"),
			item("command.markdown_preview", "Markdown Preview Toggle"),
			item("markdown.render_toggle", "Render Markdown Toggle"),
		}, is_filetype("markdown")),
		section("view", "View / Utils", {
			item("view.oil", "File Explorer (oil)"),
			item("view.terminal", "Terminal", "<leader>t"),
			item("command.scratch", "Project Scratch", "<leader>."),
			item("picker.diagnostics", "Diagnostics"),
			item("command.fold_open", "Fold Open All"),
			item("command.fold_close", "Fold Close All"),
			item("view.peek_fold", "Peek Fold"),
			item("view.toggle_wrap", "Toggle Wrap"),
			item("view.toggle_spell", "Toggle Spell"),
			item("view.toggle_relative_number", "Toggle Relative Number"),
			item("view.toggle_paste", "Toggle Paste"),
			item("command.reload_config", "Reload Config"),
			item("command.mason", "Mason"),
		}),
	}
end

---Filter descriptors without mutating the catalogue or context.
---@param sections table[]
---@param context table
---@return table[]
function M.filter(sections, context)
	local visible = {}
	for _, candidate in ipairs(sections) do
		if not candidate.when or candidate.when(context) then
			local items = {}
			for _, item in ipairs(candidate.items) do
				if not item.when or item.when(context) then
					table.insert(items, item)
				end
			end
			if #items > 0 then
				table.insert(visible, {
					id = candidate.id,
					label = candidate.label,
					items = items,
				})
			end
		end
	end
	return visible
end

---@param context table
---@param dispatch fun(id: string): any
---@return table[]
function M.build(context, dispatch)
	return M.filter(M.definitions(dispatch), context)
end

return M
