local M = {}
local native_review = require("config.native_review")
local controller = native_review.controller

local REVIEW_TYPES = native_review.comment_types.ids()
local setup_done = false

local function notify(message, level)
	vim.notify(tostring(message), level or vim.log.levels.INFO, { title = "Review" })
end

local function command(name, callback, options)
	if vim.fn.exists(":" .. name) == 2 then
		vim.api.nvim_del_user_command(name)
	end
	vim.api.nvim_create_user_command(name, callback, options or {})
end

local function setup_commands()
	command("ReviewOpen", function(value)
		local request = controller._parse_open(vim.split(value.args, "%s+", { trimempty = true }))
		if request then
			controller.open(request)
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
		local root = controller._root_for_command()
		if root then
			controller._open_scope_picker(root)
		else
			notify("Current buffer is not inside a Git repository", vim.log.levels.ERROR)
		end
	end)
	command("ReviewScopeBack", function()
		controller.scope_back()
	end)
	command("ReviewSessions", function()
		local root = controller._root_for_command()
		if root then
			controller._choose_saved(root)
		end
	end)
	command("ReviewMode", function(value)
		controller.mode(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
	command("ReviewPanel", function(value)
		controller.panel(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "toggle", "open", "close", "files", "commits", "comments" }
		end,
	})
	for name, callback in pairs({
		ReviewFiles = controller.files,
		ReviewCommits = controller.commits,
		ReviewComments = controller.comments,
		ReviewThreads = controller.comments,
		ReviewCode = controller.code,
		ReviewNext = controller.next,
		ReviewPrev = controller.prev,
		ReviewRefresh = controller.refresh,
	}) do
		command(name, callback)
	end
	command("ReviewLayout", function(value)
		controller.layout(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "inline", "split" }
		end,
	})
	command("ReviewContext", function(value)
		controller.context(value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "hunks", "full" }
		end,
	})
	command("ReviewInlineComments", function(value)
		controller.inline_comments(value.args ~= "" and value.args or "toggle")
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
	command("ReviewComment", function(value)
		controller.comment(value.line1, value.line2, value.args ~= "" and value.args or nil)
	end, {
		nargs = "?",
		range = true,
		complete = function()
			return vim.deepcopy(REVIEW_TYPES)
		end,
	})
	for name, method in pairs({
		ReviewFileComment = "file_comment",
		ReviewGeneralComment = "general_comment",
	}) do
		command(name, function(value)
			controller[method](value.args ~= "" and value.args or nil)
		end, {
			nargs = "?",
			complete = function()
				return vim.deepcopy(REVIEW_TYPES)
			end,
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
			controller[method](value.args)
		end, { nargs = "?" })
	end
	command("ReviewExport", function(value)
		controller.export(value.bang)
	end, { bang = true })
	command("ReviewClose", function(value)
		controller.close(value.bang)
	end, { bang = true })
end

local function setup_mappings()
	for _, mapping in ipairs(controller.mapping_specs()) do
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
	controller.setup()
	setup_commands()
	setup_mappings()
end

setmetatable(M, {
	__index = controller,
	__newindex = function(_, name, value)
		controller[name] = value
	end,
})

return M
