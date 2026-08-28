local M = {}

local cmake_filetypes = {
	c = true,
	cmake = true,
	cpp = true,
}

local blocked_edit_buftypes = {
	help = true,
	prompt = true,
	quickfix = true,
	terminal = true,
}

local palette_only = { palette = true, context = false }

local function editable(context)
	return context.modifiable and not blocked_edit_buftypes[context.buftype]
end

local function visual_editable(context)
	return context.visual and editable(context)
end

local function is_filetype(filetype)
	return function(context)
		return context.filetype == filetype
	end
end

local function supports_diagrams(context)
	return context.filetype == "markdown" or context.filetype == "plantuml"
end

local function descriptor(dispatch, id, label, hint, when, metadata)
	metadata = metadata or {}
	local item = {
		id = id,
		label = label,
		run = function()
			return dispatch(id)
		end,
		surfaces = metadata.surfaces,
		palette_label = metadata.palette_label,
		keywords = metadata.keywords,
	}
	if hint then
		item.hint = hint
	end
	if when then
		item.when = when
	end
	return item
end

local function section(id, label, items, when, metadata)
	metadata = metadata or {}
	return {
		id = id,
		label = label,
		items = items,
		when = when,
		surfaces = metadata.surfaces,
		palette_label = metadata.palette_label,
	}
end

local function supports_surface(candidate, surface)
	return not surface or candidate.surfaces == nil or candidate.surfaces[surface] == true
end

---Return every menu descriptor before context filtering.
---@param dispatch fun(id: string): any
---@return table[]
function M.definitions(dispatch)
	assert(type(dispatch) == "function", "menu dispatch must be a function")
	local item = function(id, label, hint, when, metadata)
		return descriptor(dispatch, id, label, hint, when, metadata)
	end
	local palette_item = function(id, label, hint, when, keywords)
		return descriptor(dispatch, id, label, hint, when, {
			surfaces = palette_only,
			keywords = keywords,
		})
	end

	return {
		section("file", "File", {
			palette_item("file.new", "New Untitled File", nil, nil, { "enew", "new buffer" }),
			palette_item("file.save", "Save", "<leader>w", nil, { "write" }),
			palette_item("file.save_as", "Save As...", nil, nil, { "saveas", "rename" }),
			palette_item("file.save_all", "Save All", nil, nil, { "wall" }),
			palette_item("file.revert", "Revert File...", nil, nil, { "reload", "discard changes" }),
			palette_item("file.close_tab", "Close Tab", "<leader>q"),
			palette_item("file.close_all", "Close All...", "<leader>Q", nil, { "quit all" }),
			palette_item("file.open_under_cursor", "Open File Under Cursor", "gf"),
			palette_item("file.set_filetype", "Set File Type...", nil, nil, { "setfiletype", "set ft" }),
		}),
		section("edit", "Edit", {
			palette_item("edit.undo", "Undo", "u"),
			palette_item("edit.redo", "Redo", "<C-r>"),
			palette_item("picker.undo", "Show Undo History", "<leader>u"),
			palette_item("edit.clear_search", "Clear Search Highlight", "<leader><CR>", nil, { "nohlsearch" }),
			palette_item("edit.join_line", "Join Line", "J", editable),
			palette_item("edit.duplicate_line", "Duplicate Line", nil, editable),
			palette_item("edit.trim_whitespace", "Trim Trailing Whitespace", nil, editable),
		}),
		section("transform", "Transform", {
			palette_item("transform.upper_word", "Uppercase Word", nil, editable, { "case", "gU" }),
			palette_item("transform.upper_line", "Uppercase Line", nil, editable, { "case", "gUU" }),
			palette_item("transform.upper_selection", "Uppercase Selection", nil, visual_editable, { "case" }),
			palette_item("transform.lower_word", "Lowercase Word", nil, editable, { "case", "gu" }),
			palette_item("transform.lower_line", "Lowercase Line", nil, editable, { "case", "guu" }),
			palette_item("transform.lower_selection", "Lowercase Selection", nil, visual_editable, { "case" }),
			palette_item("transform.toggle_word", "Toggle Case of Word", nil, editable, { "case", "g~" }),
			palette_item("transform.toggle_line", "Toggle Case of Line", nil, editable, { "case", "g~~" }),
			palette_item("transform.toggle_selection", "Toggle Case of Selection", nil, visual_editable, { "case" }),
			palette_item("transform.title_word", "Title Case Word", nil, editable, { "case" }),
			palette_item("transform.title_line", "Title Case Line", nil, editable, { "case" }),
			palette_item("transform.title_selection", "Title Case Selection", nil, visual_editable, { "case" }),
			palette_item("transform.camel_word", "camelCase Word", nil, editable, { "case" }),
			palette_item("transform.camel_line", "camelCase Line", nil, editable, { "case" }),
			palette_item("transform.camel_selection", "camelCase Selection", nil, visual_editable, { "case" }),
			palette_item("transform.pascal_word", "PascalCase Word", nil, editable, { "case" }),
			palette_item("transform.pascal_line", "PascalCase Line", nil, editable, { "case" }),
			palette_item("transform.pascal_selection", "PascalCase Selection", nil, visual_editable, { "case" }),
			palette_item("transform.snake_word", "snake_case Word", nil, editable, { "case" }),
			palette_item("transform.snake_line", "snake_case Line", nil, editable, { "case" }),
			palette_item("transform.snake_selection", "snake_case Selection", nil, visual_editable, { "case" }),
			palette_item("transform.kebab_word", "kebab-case Word", nil, editable, { "case" }),
			palette_item("transform.kebab_line", "kebab-case Line", nil, editable, { "case" }),
			palette_item("transform.kebab_selection", "kebab-case Selection", nil, visual_editable, { "case" }),
		}),
		section("go", "Go", {
			palette_item("go.line", "Go to Line...", nil, nil, { "jump" }),
			palette_item("go.matching_bracket", "Go to Matching Bracket", "%"),
			palette_item("go.todo_next", "Next TODO", "]t"),
			palette_item("go.todo_prev", "Previous TODO", "[t"),
			palette_item("go.reference_next", "Next Semantic Reference", "<A-*>"),
			palette_item("go.reference_prev", "Previous Semantic Reference", "<A-#>"),
			palette_item("go.reference_freeze", "Toggle Frozen Reference Highlight", "<leader>li"),
			palette_item("go.function_next", "Next Function", "]f"),
			palette_item("go.function_prev", "Previous Function", "[f"),
			palette_item("go.class_next", "Next Class", "]c"),
			palette_item("go.class_prev", "Previous Class", "[c"),
		}),
		section("window", "Window", {
			palette_item("window.split_horizontal", "Split Horizontal"),
			palette_item("window.split_vertical", "Split Vertical"),
			palette_item("window.close", "Close Split"),
			palette_item("window.only", "Close Other Splits"),
			palette_item("window.equalize", "Equalize Splits", "<C-w>="),
			palette_item("window.focus_left", "Focus Left", "<A-h>"),
			palette_item("window.focus_down", "Focus Down", "<A-j>"),
			palette_item("window.focus_up", "Focus Up", "<A-k>"),
			palette_item("window.focus_right", "Focus Right", "<A-l>"),
			palette_item("window.resize_left", "Resize Left", "<A-Left>"),
			palette_item("window.resize_down", "Resize Down", "<A-Down>"),
			palette_item("window.resize_up", "Resize Up", "<A-Up>"),
			palette_item("window.resize_right", "Resize Right", "<A-Right>"),
		}),
		section("tabs", "Tabs", {
			palette_item("tab.new", "New Tab"),
			palette_item("tab.previous", "Previous Tab", "<leader>j"),
			palette_item("tab.next", "Next Tab", "<leader>k"),
			palette_item("tab.first", "First Tab"),
			palette_item("tab.last", "Last Tab"),
			palette_item("tab.move_left", "Move Tab Left"),
			palette_item("tab.move_right", "Move Tab Right"),
		}),
		section("search", "Search / Replace", {
			item("search.open", "Search & Replace: Open", nil, nil, { palette_label = "Open" }),
			item("search.word", "Search & Replace: Search Word", nil, nil, { palette_label = "Search Word" }),
			item("search.selection", "Search & Replace: Search Selection", nil, function(context)
				return context.visual
			end, { palette_label = "Search Selection" }),
			item("search.file", "Search & Replace: Search in File", nil, nil, { palette_label = "Search in File" }),
			item("picker.live_grep", "Live Grep"),
			item("picker.grep_string", "Grep String (cursor)"),
		}),
		section("render", "Render", {
			item("command.diagram_show", "Diagram (Automatic SVG/ASCII)", "<leader>md", supports_diagrams),
			palette_item("command.diagram_show_svg", "Diagram as SVG", nil, supports_diagrams, {
				"mermaid",
				"plantuml",
				"image",
			}),
			palette_item("command.diagram_show_ascii", "Diagram as ASCII", nil, supports_diagrams, {
				"mermaid",
				"plantuml",
				"text",
			}),
			item("markdown.render_toggle", "Toggle Markdown Inline Rendering", "<leader>mr", is_filetype("markdown")),
			palette_item(
				"command.markdown_render_enable",
				"Enable Markdown Inline Rendering",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_render_disable",
				"Disable Markdown Inline Rendering",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_render_buffer_toggle",
				"Toggle Markdown Rendering in Buffer",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_render_buffer_enable",
				"Enable Markdown Rendering in Buffer",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_render_buffer_disable",
				"Disable Markdown Rendering in Buffer",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_render_preview",
				"Preview Markdown Inline Rendering",
				nil,
				is_filetype("markdown")
			),
			palette_item("command.markdown_render_expand", "Expand Markdown Decorations", nil, is_filetype("markdown")),
			palette_item(
				"command.markdown_render_contract",
				"Contract Markdown Decorations",
				nil,
				is_filetype("markdown")
			),
			item("command.markdown_preview", "Toggle Markdown Browser Preview", "<leader>mp", is_filetype("markdown")),
			palette_item(
				"command.markdown_preview_open",
				"Open Markdown Browser Preview",
				nil,
				is_filetype("markdown")
			),
			palette_item(
				"command.markdown_preview_stop",
				"Stop Markdown Browser Preview",
				nil,
				is_filetype("markdown")
			),
		}),
		section("navigation", "Navigation", {
			palette_item("navigation.back", "Back", "<C-o>", nil, { "history", "previous location" }),
			palette_item("navigation.forward", "Forward", "<C-i>", nil, { "history", "next location" }),
			palette_item("navigation.history", "Show History...", "<leader>nh", nil, { "locations", "back forward" }),
			item("picker.find_files", "Find Files"),
			item("picker.oldfiles", "Recent Files"),
			item("picker.buffers", "Buffers"),
			item("picker.help_tags", "Help Tags"),
			item("picker.command_history", "Command History"),
			item("picker.git_commits", "Git Commits"),
			item("picker.git_bcommits", "File History"),
			palette_item("picker.todo", "TODO Comments"),
			palette_item("flash.jump", "Flash Jump", "s"),
			palette_item("flash.treesitter", "Flash Treesitter", "S"),
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
			item("lsp.rename", "Rename", "<leader>lr"),
			item("lsp.code_action", "Code Actions"),
			palette_item("lsp.hover", "Hover Documentation", "K"),
			palette_item("lsp.signature_help", "Signature Help", "<C-k>"),
			item("command.toggle_inlay_hints", "Toggle Inlay Hints"),
			item("command.toggle_inline_diagnostics", "Toggle Inline Diagnostics", "<leader>xi"),
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
			palette_item("gitsigns.blame_line", "Blame Current Line", "<leader>hb"),
			palette_item("gitsigns.stage_selection", "Stage/Unstage Selection", "<leader>hs", visual_editable),
			palette_item("gitsigns.reset_selection", "Reset Selection", "<leader>hr", visual_editable),
			palette_item("command.diffview_close", "Close Diffview"),
			palette_item("picker.git_branches", "Branches"),
			palette_item("picker.git_status", "Status"),
			palette_item("picker.git_stash", "Stash"),
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
			palette_item("test.debug_nearest", "Debug Nearest", "<leader>Td"),
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
			palette_item("command.cmake_build_preset", "Select Build Preset"),
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
		section("tmux", "Tmux", {
			palette_item("tmux.refresh_dev_session", "Refresh Dev Session...", nil, nil, {
				"tp",
				"layout dev",
				"reload tmux",
				"restart windows",
				"save session",
			}),
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
		section("devpod", "DevPod", {
			item("command.devpod_up", "Open Container Editor"),
			item("command.devpod_recreate", "Recreate Container Editor"),
			item("command.devpod_status", "Show Status"),
			item("command.devpod_host", "Return to Host Editor"),
			palette_item("command.devpod_log", "Open Bootstrap Log"),
		}),
		section("problems", "Problems", {
			palette_item("diagnostic.float", "Show Diagnostic at Cursor", "<leader>ld"),
			palette_item("diagnostic.next", "Next Diagnostic", "]d"),
			palette_item("diagnostic.prev", "Previous Diagnostic", "[d"),
			palette_item("diagnostic.loclist", "Send Diagnostics to Location List", "<leader>lq"),
			palette_item("command.trouble_diagnostics", "Toggle Workspace Diagnostics", "<leader>xx"),
			palette_item("command.trouble_buffer", "Toggle Buffer Diagnostics", "<leader>xd"),
			palette_item("command.trouble_quickfix", "Toggle Quickfix List", "<leader>xq"),
			palette_item("command.trouble_loclist", "Toggle Location List", "<leader>xl"),
			palette_item("command.trouble_references", "Toggle LSP References", "<leader>xr"),
			palette_item("command.trouble_todos", "Toggle TODOs", "<leader>xt"),
		}),
		section("python", "Python", {
			palette_item("command.venv_select", "Select Environment...", nil, is_filetype("python")),
			palette_item("command.venv_cached", "Use Cached Environment", nil, is_filetype("python")),
			palette_item("python.repl", "Toggle REPL", "<leader>pr", is_filetype("python")),
			palette_item("python.send_line", "Send Line to REPL", "<leader>ps", is_filetype("python")),
			palette_item("python.send_selection", "Send Selection to REPL", "<leader>ps", function(context)
				return context.filetype == "python" and context.visual
			end),
		}),
		section("multicursor", "Multicursor", {
			palette_item("multicursor.match_all", "Add Cursors to All Matches", "mM"),
			palette_item("multicursor.flash_cursor", "Flash Cursor", "mcs"),
			palette_item("multicursor.flash_word_selection", "Flash Word Selection", "mcw"),
			palette_item("multicursor.clear", "Clear All Cursors", "mcc"),
			palette_item("multicursor.next", "Go to Next Cursor", "]mc"),
			palette_item("multicursor.prev", "Go to Previous Cursor", "[mc"),
		}),
		section("coverage", "Coverage", {
			palette_item("coverage.load_report", "Load Report..."),
			palette_item("command.coverage_load", "Load Default Report"),
			palette_item("command.coverage_summary", "Show Summary"),
			palette_item("command.coverage_clear", "Clear Loaded Coverage"),
		}),
		section("logs", "Logs", {
			palette_item("command.log_watch", "Toggle Follow Current File"),
			palette_item("command.log_watch_enable", "Start Following Current File"),
			palette_item("command.log_watch_disable", "Stop Following Current File"),
			palette_item("command.toggle_log_highlight", "Toggle Log Highlight", "<leader>lh"),
		}),
		section("review", "Review", {
			palette_item("command.review_panel", "Toggle Review Panel", "<leader>rr"),
			palette_item("command.review_open", "Open Default Code Review", "<leader>ro"),
			palette_item("command.review_mode", "Toggle Read-only Review Mode", "<leader>rm"),
			palette_item("command.review_scope", "Choose Review Scope or Session", "<leader>rs"),
			palette_item("command.review_scope_back", "Return to Parent Review Scope", "<leader>rb"),
			palette_item("command.review_sessions", "Open Saved Review Session"),
			palette_item("command.review_files", "Focus Review Files", "<leader>rf"),
			palette_item("command.review_commits", "Focus Review Commits", "<leader>rh"),
			palette_item("command.review_code", "Focus Reviewed Code", "<leader>rg"),
			palette_item(
				"command.review_layout",
				"Toggle Side-by-side / Unified Inline Diff",
				"<leader>rv",
				nil,
				{ "layout", "interleaved", "inline", "unified" }
			),
			palette_item(
				"command.review_context",
				"Toggle Hunks / Full File Context",
				"<leader>rw",
				nil,
				{ "context", "hunks", "full", "whole file", "folds" }
			),
			palette_item("command.review_inline_comments", "Toggle Inline Comment Previews", "<leader>ri"),
			palette_item("command.review_comments", "Focus Review Comments", "<leader>rl"),
			palette_item("command.review_comment", "Add Review Comment", "<leader>ra"),
			palette_item("command.review_file_comment", "Add File-level Review Comment", "<leader>rA"),
			palette_item("command.review_general_comment", "Add Review-level Comment", "<leader>rR"),
			palette_item("command.review_edit", "Edit Review Comment", "<leader>re"),
			palette_item("command.review_change_type", "Change Comment Type at Current Line", "<leader>rc"),
			palette_item("command.review_delete", "Delete Comment at Current Line", "<leader>rd"),
			palette_item("command.review_reply", "Reply to Review Comment", "<leader>rp"),
			palette_item("command.review_toggle_resolve", "Resolve or Reopen Review Comment", "<leader>rt"),
			palette_item("command.review_reanchor", "Reanchor Review Comment"),
			palette_item("command.review_export", "Export Complete Review", "<leader>rE"),
			palette_item("command.review_publish", "Publish Open Comments to TUICR"),
			palette_item("command.review_refresh", "Refresh Review", "<leader>ru"),
			palette_item("command.review_next", "Next Review Comment", "]r"),
			palette_item("command.review_prev", "Previous Review Comment", "[r"),
			palette_item("command.review_link_tuicr", "Link Review to TUICR..."),
			palette_item("command.review_close", "Close Review", "<leader>rq"),
			palette_item("command.review_start", "Start TUICR Round"),
			palette_item("review.open", "Open TUICR TUI..."),
			palette_item("agent.context", "Copy Agent Context"),
			palette_item("agent.results", "Import Agent Results..."),
		}),
		section("tools", "Tools", {
			palette_item("command.theme", "Select Theme..."),
			palette_item("command.theme_reset", "Reset Theme"),
			palette_item("clangd.compile_commands", "Set clangd Compile Database...", nil, function(context)
				return cmake_filetypes[context.filetype] == true
			end),
			palette_item("command.clangd_switch", "Switch Source/Header", nil, function(context)
				return context.filetype == "c" or context.filetype == "cpp"
			end),
			palette_item("command.hex_toggle", "Toggle Hex View"),
			palette_item("command.hex_dump", "Convert Buffer to Hex"),
			palette_item("command.hex_assemble", "Assemble Hex Buffer..."),
			palette_item("command.nvim_config_dump", "Show Effective Local Config"),
			palette_item("command.nvim_config_edit", "Edit Local Config"),
			palette_item("command.nvim_config_reload", "Reload Local Config Cache"),
			palette_item("command.nvim_config_init", "Create Local Config Template..."),
			palette_item("command.tools_install", "Install Managed Tools..."),
			palette_item("command.parsers_install", "Install Tree-sitter Parsers..."),
		}),
		section("help", "Help", {
			palette_item("picker.keymaps", "Show Keyboard Shortcuts", nil, nil, { "cheatsheet", "bindings" }),
			palette_item("picker.commands", "Show User Commands", nil, nil, { "cheatsheet", "command palette" }),
			palette_item("command.messages", "Show Messages", "<leader>fn"),
			palette_item("notification.dismiss", "Dismiss Notifications", "<leader>fN"),
			palette_item("notification.history", "Show Notification History"),
			palette_item("picker.marks", "Show Marks"),
			palette_item("picker.jumps", "Show Jump List"),
			palette_item("picker.registers", "Show Registers"),
		}),
		section("file.json", "File (json)", {
			item("command.json_tree", "JSON Tree"),
			item("json.jqx_query", "JQX Query"),
		}, is_filetype("json")),
		section("view", "View / Utils", {
			item("view.oil", "File Explorer (oil)"),
			item("view.terminal", "Terminal", "<leader>t"),
			item("command.scratch", "Project Scratch", "<leader>."),
			item("picker.diagnostics", "Diagnostics"),
			item("command.fold_open", "Fold Open All"),
			item("command.fold_close", "Fold Close All"),
			item("view.peek_fold", "Peek Fold"),
			item("view.toggle_wrap", "Toggle Wrap"),
			palette_item("view.enable_wrap", "Enable Word Wrap", nil, nil, { "soft wrap" }),
			palette_item("view.disable_wrap", "Disable Word Wrap", nil, nil, { "soft wrap" }),
			item("view.toggle_spell", "Toggle Spell"),
			palette_item("view.enable_spell", "Enable Spell Checking"),
			palette_item("view.disable_spell", "Disable Spell Checking"),
			palette_item("view.toggle_number", "Toggle Line Numbers"),
			item("view.toggle_relative_number", "Toggle Relative Number"),
			palette_item("view.enable_relative_number", "Enable Relative Line Numbers"),
			palette_item("view.disable_relative_number", "Disable Relative Line Numbers"),
			palette_item("view.toggle_cursorline", "Toggle Cursor Line"),
			palette_item("view.toggle_list", "Toggle Invisible Characters", nil, nil, { "whitespace", "listchars" }),
			item("view.toggle_paste", "Toggle Paste"),
			item("command.reload_config", "Reload Config"),
			item("command.mason", "Mason"),
		}, nil, { palette_label = "View" }),
	}
end

---Filter descriptors without mutating the catalogue or context.
---@param sections table[]
---@param context table
---@param surface? "palette"|"context"
---@return table[]
function M.filter(sections, context, surface)
	local visible = {}
	for _, candidate in ipairs(sections) do
		if supports_surface(candidate, surface) and (not candidate.when or candidate.when(context)) then
			local items = {}
			for _, item in ipairs(candidate.items) do
				if supports_surface(item, surface) and (not item.when or item.when(context)) then
					table.insert(items, item)
				end
			end
			if #items > 0 then
				table.insert(visible, {
					id = candidate.id,
					label = candidate.label,
					palette_label = candidate.palette_label,
					items = items,
				})
			end
		end
	end
	return visible
end

---@param context table
---@param dispatch fun(id: string): any
---@param surface? "palette"|"context"
---@return table[]
function M.build(context, dispatch, surface)
	return M.filter(M.definitions(dispatch), context, surface)
end

return M
