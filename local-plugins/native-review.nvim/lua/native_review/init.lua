local comment_types = require("native_review.comment_types")

local M = {}

local DEFAULTS = {
	hunk_context = 3,
	max_files = 2000,
	max_file_bytes = 4 * 1024 * 1024,
	max_model_bytes = 64 * 1024 * 1024,
	layout = "inline",
	context = "hunks",
	inline_comments = true,
	comment_types = {},
	composer = { style = "card" },
	panel = { max_width = 200, max_height = 48 },
}
local effective = vim.deepcopy(DEFAULTS)
local configured = false

local ALLOWED = {
	repo = true,
	fs = true,
	editor = true,
	tabs = true,
	clipboard = true,
	lsp_navigation = true,
	structural_diff = true,
	gumtree = true,
	event = true,
	hunk_context = true,
	max_files = true,
	max_file_bytes = true,
	max_model_bytes = true,
	layout = true,
	context = true,
	inline_comments = true,
	comment_types = true,
	composer = true,
	panel = true,
}

local MODULES = {
	changes = "native_review.changes",
	comment_types = "native_review.comment_types",
	controller = "native_review.controller",
	editor = "native_review.editor",
	export = "native_review.export",
	engines = "native_review.engines",
	lsp = "native_review.lsp",
	mode = "native_review.mode",
	panel = "native_review.panel",
	presenter = "native_review.presenter",
	projection = "native_review.projection",
	scope = "native_review.scope",
	store = "native_review.store",
	structural = "native_review.structural",
}

---Inject host services and load the standalone review runtime.
---@param opts table
---@return table
function M.setup(opts)
	if opts == nil then
		opts = {}
	end
	assert(
		type(opts) == "table" and (next(opts) == nil or not vim.islist(opts)),
		"native-review setup options must be an object"
	)
	for key in pairs(opts) do
		assert(ALLOWED[key], "native-review setup contains an unknown option: " .. tostring(key))
	end
	local hunk_context = opts.hunk_context
	if hunk_context == nil then
		hunk_context = DEFAULTS.hunk_context
	end
	assert(
		type(hunk_context) == "number" and hunk_context % 1 == 0 and hunk_context >= 0,
		"native-review hunk_context must be a non-negative integer"
	)
	local limits = {}
	for _, name in ipairs({ "max_files", "max_file_bytes", "max_model_bytes" }) do
		local value = opts[name]
		if value == nil then
			value = DEFAULTS[name]
		end
		assert(
			type(value) == "number" and value % 1 == 0 and value > 0,
			"native-review " .. name .. " must be a positive integer"
		)
		limits[name] = value
	end
	assert(
		opts.layout == nil or opts.layout == "inline" or opts.layout == "split",
		"native-review layout must be inline or split"
	)
	assert(
		opts.context == nil or opts.context == "hunks" or opts.context == "full",
		"native-review context must be hunks or full"
	)
	assert(
		opts.inline_comments == nil or type(opts.inline_comments) == "boolean",
		"native-review inline_comments must be boolean"
	)
	local extra_comment_types = comment_types.validate(opts.comment_types)
	local composer = opts.composer
	if composer == nil then
		composer = {}
	end
	assert(
		type(composer) == "table" and (next(composer) == nil or not vim.islist(composer)),
		"native-review composer must be an object"
	)
	for key in pairs(composer) do
		assert(key == "style", "native-review composer contains an unknown option: " .. tostring(key))
	end
	assert(
		composer.style == nil or composer.style == "card" or composer.style == "minimal",
		"native-review composer.style must be card or minimal"
	)
	local panel = opts.panel
	if panel == nil then
		panel = {}
	end
	assert(
		type(panel) == "table" and (next(panel) == nil or not vim.islist(panel)),
		"native-review panel must be an object"
	)
	for key in pairs(panel) do
		assert(
			key == "max_width" or key == "max_height",
			"native-review panel contains an unknown option: " .. tostring(key)
		)
	end
	for _, key in ipairs({ "max_width", "max_height" }) do
		local value = panel[key]
		if value == nil then
			value = DEFAULTS.panel[key]
		end
		assert(
			type(value) == "number" and value % 1 == 0 and value >= 1,
			"native-review panel." .. key .. " must be a positive integer"
		)
	end
	local config = {
		hunk_context = hunk_context,
		max_files = limits.max_files,
		max_file_bytes = limits.max_file_bytes,
		max_model_bytes = limits.max_model_bytes,
		layout = opts.layout or DEFAULTS.layout,
		context = opts.context or DEFAULTS.context,
		inline_comments = opts.inline_comments == nil and DEFAULTS.inline_comments or opts.inline_comments,
		comment_types = extra_comment_types,
		composer = {
			style = composer.style or DEFAULTS.composer.style,
		},
		panel = {
			max_width = panel.max_width == nil and DEFAULTS.panel.max_width or panel.max_width,
			max_height = panel.max_height == nil and DEFAULTS.panel.max_height or panel.max_height,
		},
	}
	require("native_review.dependencies").setup({
		repo = opts.repo,
		fs = opts.fs,
		editor = opts.editor,
		tabs = opts.tabs,
		clipboard = opts.clipboard,
		lsp_navigation = opts.lsp_navigation,
		structural_diff = opts.structural_diff,
		gumtree = opts.gumtree,
		event = opts.event or function() end,
		config = config,
	})
	if M.controller and M.controller.cancel_pending then
		M.controller.cancel_pending("native-review setup replaced its adapters", false)
	end
	comment_types.configure(extra_comment_types)
	effective = vim.deepcopy(config)
	configured = true
	for name, module_name in pairs(MODULES) do
		M[name] = require(module_name)
	end
	M.controller.setup()
	return M
end

function M.effective_config()
	return vim.deepcopy(effective)
end

function M.status()
	local status = M.controller and M.controller.status() or { active = false, mode_on = false }
	status.configured = configured
	status.config = M.effective_config()
	return vim.deepcopy(status)
end

function M.teardown()
	if M.controller and M.controller.teardown then
		M.controller.teardown()
	end
	require("native_review.dependencies").clear()
	comment_types.reset()
	effective = vim.deepcopy(DEFAULTS)
	configured = false
	return true
end

return M
