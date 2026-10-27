-- All md-render v3.10.3 runtime adaptations live here. The stock checkout is
-- verified before touching private entrypoints; no installed file is changed.
local M = { PIN = "cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74" }
local tables = require("markdown_view.tables")
local layout = require("markdown_view.layout")
local media = require("markdown_view.media")

local render, wrap, image, original_image
local adaptations = {}
local active
local rebuilding = 0
local always_expanded = {
	__index = function()
		return true
	end,
}

local function checkout_ok(engine, images)
	local image_path = debug.getinfo(images._set_kitty_supported, "S").source:match("^@(.+)$")
	local preview_path = debug.getinfo(engine.preview.toggle, "S").source:match("^@(.+)$")
	if not image_path or not preview_path then
		return nil, "renderer source path is unavailable"
	end
	local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(image_path))))
	if
		vim.fs.normalize(image_path) ~= vim.fs.joinpath(root, "lua", "md-render", "image.lua")
		or vim.fs.normalize(preview_path) ~= vim.fs.joinpath(root, "lua", "md-render", "preview.lua")
	then
		return nil, "renderer modules came from different checkouts"
	end
	local head = vim.system({ "git", "-C", root, "rev-parse", "--verify", "HEAD" }, { text = true }):wait()
	if head.code ~= 0 or vim.trim(head.stdout or "") ~= M.PIN then
		return nil, "loaded renderer checkout differs from the v3.10.3 pin; restore md-render.nvim and restart"
	end
	local status = vim.system({ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" }, { text = true })
		:wait()
	if status.code ~= 0 or vim.trim(status.stdout or "") ~= "" then
		return nil, "loaded renderer checkout has local changes"
	end
	return true
end

local function replace(module, name, fn)
	module[name] = fn
	adaptations[#adaptations + 1] = { module, name, fn }
end

local function style_values(groups)
	local values = {}
	for _, group in ipairs(groups or {}) do
		values[#values + 1] = { group.col, group.end_col, group.hl }
	end
	return values
end

-- Exact pre-wrap byte spans from the public builder's emitted text. Captures
-- attach to this builder instance, never to shared methods during a snapshot.
local function prose_spans(text, method, args, first)
	local indent = args[1] or ""
	if method == "add_simple_markdown" then
		return { { line = first, col = #indent, first = 0, last = #text } }
	end
	local quote, marker = args[3] or "", args[4] or ""
	local offset = #quote + #marker
	local width = math.max(1, args[2] - vim.api.nvim_strwidth(quote) - vim.api.nvim_strwidth(marker))
	local wrapped, starts = wrap.wrap_words(text:sub(offset + 1), width)
	local spans = {}
	if offset > 0 then
		spans[#spans + 1] = { line = first, col = #indent, first = 0, last = offset }
	end
	for index, line in ipairs(wrapped) do
		local prefix = index == 1 and #marker or vim.api.nvim_strwidth(marker)
		spans[#spans + 1] = {
			line = first + (index - 1) * (1 + (args[5] or 0)),
			col = #indent + #quote + prefix,
			first = offset + starts[index],
			last = offset + starts[index] + #line,
		}
	end
	return spans
end

local function capture_builder(builder, context)
	for _, method in ipairs({ "add_simple_markdown", "add_wrapped_markdown" }) do
		local original = builder[method]
		builder[method] = function(self, text, highlights, links, ...)
			local first, args = #self.lines + 1, { ... }
			local value = original(self, text, highlights, links, ...)
			context.captures[#context.captures + 1] = {
				first = first,
				last = #self.lines,
				text = text,
				collapse_whitespace = method == "add_wrapped_markdown",
				styles = style_values(highlights),
				spans = prose_spans(text, method, args, first),
			}
			return value
		end
	end
	local original = builder.add_table
	builder.add_table = function(self, lines, ...)
		local parsed = render.MarkdownTable.parse(lines)
		local frame = { first = #self.lines + 1, source = self._current_source_line }
		local previous = context.current_table
		context.current_table = frame
		local value = original(self, lines, ...)
		context.current_table = previous
		if parsed then
			frame.cells = {}
			for row, values in ipairs(vim.list_extend({ parsed.headers }, parsed.rows)) do
				for column, cell in ipairs(values) do
					frame.cells[#frame.cells + 1] = {
						text = cell.text,
						styles = style_values(cell.highlights),
						row = row,
						column = column,
						spans = {},
					}
				end
			end
			frame.last = #self.lines
			frame.structure = { "table", #parsed.headers, #parsed.rows, parsed.alignments }
			context.captures[#context.captures + 1] = frame
		end
		return value
	end
end

function M.configure(engine, wrapping, images, preferences, rebuild_document)
	if type(engine) ~= "table" or type(images) ~= "table" or type(wrapping) ~= "table" then
		return nil, "md-render.nvim could not load"
	end
	if
		type(images._set_kitty_supported) ~= "function"
		or type(images.set_download_fn) ~= "function"
		or type(engine.preview) ~= "table"
		or type(engine.preview.toggle) ~= "function"
		or type(engine.preview._toggle_sessions) ~= "table"
		or type(engine.preview.build_content) ~= "function"
		or type(engine.MarkdownTable) ~= "table"
		or type(engine.ContentBuilder) ~= "table"
		or type(engine.MarkdownTable.parse) ~= "function"
		or type(engine.MarkdownTable.render) ~= "function"
		or type(engine.ContentBuilder.new) ~= "function"
		or type(wrapping.split_ascii_syllables) ~= "function"
		or type(wrapping.wrap_words) ~= "function"
	then
		return nil, "v3.10.3 media guard contract changed"
	end
	local ok, err = checkout_ok(engine, images)
	if not ok then
		return nil, err
	end
	if render then
		if render ~= engine or wrap ~= wrapping or image ~= images then
			return nil, "renderer modules changed after configuration"
		end
		for _, adaptation in ipairs(adaptations) do
			if adaptation[1][adaptation[2]] ~= adaptation[3] then
				return nil, "renderer changed after configuration: " .. adaptation[2]
			end
		end
		media.configure(original_image, preferences, rebuild_document)
		return true
	end
	original_image = {}
	for _, name in ipairs({
		"is_url",
		"is_badge_url",
		"resolve",
		"get_cached",
		"download_async",
		"set_download_fn",
		"has_mmdc",
		"has_plantuml",
		"is_video_file",
		"is_video_content",
		"download_video_async",
		"supports_kitty",
		"_set_kitty_supported",
	}) do
		if type(images[name]) ~= "function" then
			return nil, "v3.10.3 image contract changed: " .. name
		end
		original_image[name] = images[name]
	end
	render, wrap, image = engine, wrapping, images
	original_image.set_supported = original_image._set_kitty_supported
	media.configure(original_image, preferences, rebuild_document)
	image.set_download_fn(media.download)
	replace(image, "is_url", media.is_url)
	replace(image, "resolve", media.resolve)
	for _, name in ipairs({ "has_mmdc", "has_plantuml", "is_video_file", "is_video_content" }) do
		replace(image, name, function()
			return false
		end)
	end
	replace(image, "download_video_async", function(_, callback)
		callback(nil)
	end)
	image._set_kitty_supported(false)
	local split = wrap.split_ascii_syllables
	replace(wrap, "split_ascii_syllables", function(word, ...)
		return (word:find("[\128-\255]") and split or tables.split_ascii_characters)(word, ...)
	end)
	local parse, render_table = render.MarkdownTable.parse, render.MarkdownTable.render
	replace(render.MarkdownTable, "parse", function(...)
		local parsed = parse(...)
		return parsed and tables.restore_links(parsed) or nil
	end)
	replace(render.MarkdownTable, "render", function(...)
		return tables.render(render_table, active, ...)
	end)
	local new = render.ContentBuilder.new
	replace(render.ContentBuilder, "new", function(...)
		local builder = new(...)
		if active and active.captures then
			capture_builder(builder, active)
		end
		return builder
	end)
	local build = render.preview.build_content
	replace(render.preview, "build_content", function(lines, opts)
		opts = opts or {}
		opts.expand_state = opts.expand_state or {}
		if getmetatable(opts.expand_state) == nil then
			setmetatable(opts.expand_state, always_expanded)
		end
		local width = opts.nvim_config_page_width or opts.nvim_config_block_width
		local context = {
			wrap = opts.nvim_config_wrap ~= false,
			extra = type(width) == "number" and math.max(0, math.floor(width) - (opts.max_width or 80)) or 0,
			captures = opts.nvim_config_review and {} or nil,
		}
		context.table_layout = function(stacked)
			if context.current_table then
				context.current_table.stacked = stacked
			end
		end
		local previous = active
		active = context
		local image_scope = media.begin(opts)
		local built, content = pcall(build, lines, opts)
		active = previous
		media.finish(image_scope, built)
		if not built then
			error(content, 0)
		end
		content.expandable_regions = {}
		return layout.center_content(content, opts), context.captures
	end)
	return true
end

function M.snapshot(lines, opts)
	media.reassert()
	local ok, content, captures = pcall(render.preview.build_content, lines, opts)
	return ok and content or nil,
		not ok and tostring(content) or nil,
		captures,
		{ Markdown = render.Markdown, resolve_language = render.display_utils._resolve_lang }
end

function M.session(source_buf)
	return render and render.preview._toggle_sessions[source_buf]
end

function M.toggle(opts)
	media.reassert()
	return render.preview.toggle(opts)
end

function M.window_state(win)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local ok, state = pcall(vim.api.nvim_win_get_var, win, "md_render_state")
	if
		ok
		and type(state) == "table"
		and state.mode == "render"
		and vim.api.nvim_win_get_buf(win) == state.render_buf
		and state.source_buf
		and vim.api.nvim_buf_is_valid(state.source_buf)
	then
		return state
	end
end

function M.rebuilding()
	return rebuilding > 0
end

-- One session boundary owns readonly restoration and every post-build effect.
-- The callback draws decorations/margins and restores window options together.
function M.protect(session, after)
	if session.markdown_view_protected then
		return
	end
	-- Image placeholders are updated outside rebuild; lift readonly for that write.
	vim.api.nvim_create_autocmd("FileChangedRO", {
		buffer = session.buf,
		callback = function(args)
			vim.bo[args.buf].readonly = false
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(args.buf) then
					vim.bo[args.buf].readonly = true
					vim.bo[args.buf].modified = false
				end
			end)
		end,
	})
	local rebuild = session.rebuild
	session.rebuild = function(self, ...)
		local readonly = vim.bo[self.buf].readonly
		vim.bo[self.buf].readonly = false
		rebuilding = rebuilding + 1
		local ok, result = pcall(function(...)
			local value = rebuild(self, ...)
			after(self)
			return value
		end, ...)
		rebuilding = rebuilding - 1
		if vim.api.nvim_buf_is_valid(self.buf) then
			vim.bo[self.buf].readonly = readonly
		end
		if not ok then
			error(result, 0)
		end
		return result
	end
	session.markdown_view_protected = true
end

return M
