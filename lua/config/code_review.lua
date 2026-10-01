local M = {}

local deferred = require("config.deferred")

-- Global review commands and mappings belong to the host. Keeping this small,
-- side-effect-free catalogue here lets init.lua publish the complete UI without
-- loading the native-review runtime.
local HELP_GROUPS = { common = "review", diff_line = "review_diff", file = "review_file" }
local MAPPINGS = {
	{ lhs = "<leader>rr", rhs = "<cmd>ReviewPanel<cr>", desc = "Toggle review panel", help = "common" },
	{ lhs = "<leader>ro", rhs = "<cmd>ReviewOpen<cr>", desc = "Open default review", help = "common" },
	{ lhs = "<leader>rm", rhs = "<cmd>ReviewMode<cr>", desc = "Toggle review mode", help = "common" },
	{ lhs = "<leader>rs", rhs = "<cmd>ReviewScope<cr>", desc = "Review scope/session", help = "common" },
	{ lhs = "<leader>rb", rhs = "<cmd>ReviewScopeBack<cr>", desc = "Return to parent review scope", help = "common" },
	{ lhs = "<leader>rf", rhs = "<cmd>ReviewFiles<cr>", desc = "Focus review files", help = "common" },
	{ lhs = "<leader>rh", rhs = "<cmd>ReviewCommits<cr>", desc = "Focus review commits", help = "common" },
	{ lhs = "<leader>rl", rhs = "<cmd>ReviewComments<cr>", desc = "Focus review comments", help = "common" },
	{ lhs = "<leader>rv", rhs = "<cmd>ReviewLayout<cr>", desc = "Toggle review layout", help = "common" },
	{ lhs = "<leader>rw", rhs = "<cmd>ReviewContext<cr>", desc = "Toggle review context", help = "common" },
	{ lhs = "<leader>ri", rhs = "<cmd>ReviewInlineComments<cr>", desc = "Toggle inline comments", help = "common" },
	{ lhs = "<leader>rg", rhs = "<cmd>ReviewCode<cr>", desc = "Focus reviewed code", help = "common" },
	{ lhs = "<leader>ra", rhs = "<cmd>ReviewComment<cr>", desc = "Add line/range comment", help = "diff_line" },
	{ lhs = "<leader>rA", rhs = "<cmd>ReviewFileComment<cr>", desc = "Add file comment", help = "file" },
	{ lhs = "<leader>rR", rhs = "<cmd>ReviewGeneralComment<cr>", desc = "Add review-level comment", help = "common" },
	{ lhs = "<leader>re", rhs = "<cmd>ReviewEdit<cr>", desc = "Edit review comment", help = "common" },
	{ lhs = "<leader>rc", rhs = "<cmd>ReviewChangeType<cr>", desc = "Change comment type", help = "diff_line" },
	{ lhs = "<leader>rd", rhs = "<cmd>ReviewDeleteDraft<cr>", desc = "Delete review comment", help = "diff_line" },
	{ lhs = "<leader>rp", rhs = "<cmd>ReviewReply<cr>", desc = "Reply to review comment", help = "common" },
	{ lhs = "<leader>rt", rhs = "<cmd>ReviewToggleResolve<cr>", desc = "Resolve or reopen comment", help = "common" },
	{ lhs = "<leader>rE", rhs = "<cmd>ReviewExport<cr>", desc = "Export review", help = "common" },
	{ lhs = "<leader>ru", rhs = "<cmd>ReviewRefresh<cr>", desc = "Refresh review", help = "common" },
	{ lhs = "<leader>rq", rhs = "<cmd>ReviewClose<cr>", desc = "Close review", help = "common" },
	{ lhs = "]r", rhs = "<cmd>ReviewNext<cr>", desc = "Next review comment", help = "common" },
	{ lhs = "[r", rhs = "<cmd>ReviewPrev<cr>", desc = "Previous review comment", help = "common" },
}

local setup_done = false
local runtime

local function loaded_runtime()
	if type(runtime) == "table" then
		return runtime
	end
	local loaded = package.loaded["config.native_review"]
	if type(loaded) == "table" then
		runtime = loaded
		return runtime
	end
	return nil
end

local function activate()
	local loaded = loaded_runtime()
	if loaded then
		return loaded
	end
	loaded = deferred.load("config.native_review")
	assert(type(loaded) == "table" and type(loaded.controller) == "table", "native review returned no controller")
	runtime = loaded
	return runtime
end

local function controller()
	return activate().controller
end

local function loaded_controller()
	local loaded = loaded_runtime()
	return loaded and type(loaded.controller) == "table" and loaded.controller or nil
end

local function loaded_lsp()
	local loaded = loaded_runtime()
	return loaded and type(loaded.lsp) == "table" and loaded.lsp or nil
end

local function notify(message, level)
	vim.notify(tostring(message), level or vim.log.levels.INFO, { title = "Review" })
end

local function command(name, callback, options)
	if vim.fn.exists(":" .. name) == 2 then
		vim.api.nvim_del_user_command(name)
	end
	vim.api.nvim_create_user_command(name, callback, options or {})
end

local function review_types()
	local comment_types = activate().comment_types
	return type(comment_types) == "table" and type(comment_types.ids) == "function" and comment_types.ids() or {}
end

local function setup_commands()
	command("ReviewOpen", function(value)
		local review_controller = controller()
		local request = review_controller._parse_open(vim.split(value.args, "%s+", { trimempty = true }))
		if request then
			review_controller.open_async(request)
		else
			notify("Usage: ReviewOpen [working|commit [REV]|range FROM TO|branch [BASE [HEAD]]]", vim.log.levels.ERROR)
		end
	end, {
		nargs = "*",
		complete = function()
			return { "working", "commit", "range", "branch" }
		end,
	})
	command("ReviewScope", function()
		local review_controller = controller()
		local root = review_controller._root_for_command()
		if root then
			review_controller._open_scope_picker(root)
		else
			notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		end
	end)
	command("ReviewScopeBack", function()
		controller().scope_back()
	end)
	command("ReviewSessions", function()
		local review_controller = controller()
		local root = review_controller._root_for_command()
		if root then
			review_controller._choose_saved(root)
		end
	end)
	command("ReviewMode", function(value)
		controller().mode(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
	command("ReviewPanel", function(value)
		controller().panel(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "toggle", "open", "close", "files", "commits", "comments" }
		end,
	})
	for name, method in pairs({
		ReviewFiles = "files",
		ReviewCommits = "commits",
		ReviewComments = "comments",
		ReviewThreads = "comments",
		ReviewCode = "code",
		ReviewNext = "next",
		ReviewPrev = "prev",
	}) do
		command(name, function()
			controller()[method]()
		end)
	end
	command("ReviewRefresh", function()
		controller().refresh_async()
	end)
	command("ReviewStructuralDiff", function()
		controller().structural_diff()
	end)
	command("ReviewLayout", function(value)
		controller().layout(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "inline", "split" }
		end,
	})
	command("ReviewContext", function(value)
		controller().context(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "hunks", "full" }
		end,
	})
	command("ReviewInlineComments", function(value)
		controller().inline_comments(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
	command("ReviewComment", function(value)
		controller().comment(value.line1, value.line2, value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		range = true,
		complete = review_types,
	})
	for name, method in pairs({
		ReviewFileComment = "file_comment",
		ReviewGeneralComment = "general_comment",
	}) do
		command(name, function(value)
			controller()[method](value.args ~= "" and value.args or nil)
		end, {
			nargs = "?",
			complete = review_types,
		})
	end
	for name, method in pairs({
		ReviewEdit = "edit",
		ReviewDeleteDraft = "delete",
		ReviewChangeType = "change_type",
		ReviewReply = "reply",
		ReviewResolve = "resolve",
		ReviewReopen = "reopen",
		ReviewToggleResolve = "toggle_resolution",
		ReviewReanchor = "reanchor",
	}) do
		command(name, function(value)
			controller()[method](value.args)
		end, { nargs = "?" })
	end
	command("ReviewExport", function(value)
		controller().export(value.bang)
	end, { bang = true })
	command("ReviewClose", function(value)
		controller().close(value.bang)
	end, { bang = true })
end

local function setup_mappings()
	for _, mapping in ipairs(MAPPINGS) do
		vim.keymap.set("n", mapping.lhs, mapping.rhs, { silent = true, desc = mapping.desc })
	end
	vim.keymap.set("x", "<leader>ra", ":<C-U>'<,'>ReviewComment<CR>", {
		silent = true,
		desc = "Add review comment for selected lines",
	})
end

function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	setup_commands()
	setup_mappings()
end

function M.mapping_specs()
	return vim.deepcopy(MAPPINGS)
end

function M.help_groups()
	return vim.deepcopy(HELP_GROUPS)
end

function M.help_mappings(group)
	local values = {}
	for _, mapping in ipairs(MAPPINGS) do
		if mapping.help == group then
			values[#values + 1] = { "n", mapping.lhs, mapping.rhs, { desc = mapping.desc } }
		end
	end
	return values
end

-- Observers must not activate review merely to discover that it is inactive.
function M.status()
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.status) ~= "function" then
		return { active = false, mode_on = false }
	end
	return review_controller.status()
end

function M.snapshot(...)
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.snapshot) ~= "function" then
		return nil
	end
	return review_controller.snapshot(...)
end

function M.comment_type(id)
	local loaded = loaded_runtime()
	local catalogue = loaded and loaded.comment_types
	if not catalogue or type(catalogue.get) ~= "function" then
		return nil
	end
	return catalogue.get(id)
end

function M.suspend_for_session(...)
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.suspend_for_session) ~= "function" then
		return true
	end
	return review_controller.suspend_for_session(...)
end

function M.restore_after_session(...)
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.restore_after_session) ~= "function" then
		return true
	end
	return review_controller.restore_after_session(...)
end

function M.capture_location()
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.capture_location) ~= "function" then
		return nil
	end
	return review_controller.capture_location()
end

function M.restore_location(entry)
	local review_controller = loaded_controller()
	if not review_controller or type(review_controller.restore_location) ~= "function" then
		return false
	end
	return review_controller.restore_location(entry)
end

function M.lsp_blocked(bufnr)
	local lsp = loaded_lsp()
	return lsp ~= nil and type(lsp.blocked) == "function" and lsp.blocked(bufnr) == true
end

function M.enforce_lsp_blocked(bufnr, client_id)
	local lsp = loaded_lsp()
	return lsp ~= nil and type(lsp.enforce_blocked) == "function" and lsp.enforce_blocked(bufnr, client_id) == true
end

function M.lsp_definition_options(bufnr, winid)
	local lsp = loaded_lsp()
	if not lsp or type(lsp.definition_options) ~= "function" then
		return nil
	end
	return lsp.definition_options(bufnr, winid)
end

function M.wrap_lsp_root_dir(upstream, root_markers)
	local wrapped
	return function(bufnr, on_dir)
		local lsp = loaded_lsp()
		if lsp and type(lsp.wrap_root_dir) == "function" then
			wrapped = wrapped or lsp.wrap_root_dir(upstream, root_markers)
			return wrapped(bufnr, on_dir)
		end
		if type(upstream) == "function" then
			return upstream(bufnr, on_dir)
		elseif type(upstream) == "string" then
			return on_dir(upstream)
		end
		return on_dir(root_markers and vim.fs.root(bufnr, root_markers) or nil)
	end
end

setmetatable(M, {
	__index = function(_, name)
		return controller()[name]
	end,
	__newindex = function(_, name, value)
		controller()[name] = value
	end,
})

return M
