vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")
require("config.local_plugins").setup()

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
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

local function temp_dir()
	local path = vim.fn.tempname()
	assert(vim.fn.mkdir(path, "p", 448) == 1)
	return path
end

test("Markdown gd follows public Tree-sitter injections and routes targets conservatively", function()
	local original_editor = package.loaded["config.editor"]
	local original_pager = package.loaded["config.pager"]
	local original_clipboard = package.loaded["config.clipboard"]
	local original_navigation = package.loaded["config.markdown_navigation"]
	local original_open = vim.ui.open
	local original_notify = vim.notify
	local original_setreg = vim.fn.setreg
	local original_ssh_tty = vim.env.SSH_TTY
	local original_ssh_connection = vim.env.SSH_CONNECTION
	local opened_files = {}
	local opened_urls = {}
	local copied = {}
	local marksman = {}
	local definitions = 0
	local notifications = {}
	local allowed = true
	local function buffer_mapping(bufnr, lhs)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if mapping.lhs == lhs then
				return mapping
			end
		end
	end

	package.loaded["config.editor"] = {
		open_file_in_tab = function(path)
			opened_files[#opened_files + 1] = path
		end,
	}
	package.loaded["config.clipboard"] = {
		copy_text = function(value, register)
			copied[#copied + 1] = { register, value, "v" }
			return true
		end,
	}
	package.loaded["config.pager"] = { active = true }
	package.loaded["config.markdown_navigation"] = nil
	local disabled = require("config.markdown_navigation")
	assert(not disabled.setup({
		allowed = function()
			return true
		end,
		definition = function() end,
		marksman = function() end,
	}), "Markdown navigation leaked into pager")

	package.loaded["config.pager"] = { active = false }
	package.loaded["config.markdown_navigation"] = nil
	vim.g.vscode = true
	disabled = require("config.markdown_navigation")
	assert(not disabled.setup({
		allowed = function()
			return true
		end,
		definition = function() end,
		marksman = function() end,
	}), "Markdown navigation leaked into VSCode")
	vim.g.vscode = nil

	package.loaded["config.markdown_navigation"] = nil
	local navigation = require("config.markdown_navigation")
	local review_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[review_buf].filetype = "markdown"
	vim.b[review_buf].nvim_review_role = "snapshot"
	local review_definition = function() end
	vim.keymap.set("n", "gd", review_definition, {
		buffer = review_buf,
		desc = "Review definition in current source",
	})
	navigation.setup({
		allowed = function()
			return allowed
		end,
		eligible = function(bufnr)
			return vim.b[bufnr].nvim_review_role ~= "snapshot"
		end,
		definition = function()
			definitions = definitions + 1
			return true
		end,
		marksman = function(bufnr, line, column)
			marksman[#marksman + 1] = { bufnr = bufnr, line = line, column = column }
			return true
		end,
	})
	equal(
		"Review definition in current source",
		buffer_mapping(review_buf, "gd").desc,
		"late Markdown setup replaced the reviewer CURRENT-only bridge"
	)

	local root = temp_dir()
	local guide = vim.fs.joinpath(root, "guide.md")
	local escaped = vim.fs.joinpath(root, "foo(x).md")
	local escaped_hash = vim.fs.joinpath(root, "foo#bar.md")
	local entity = vim.fs.joinpath(root, "foo&bar.md")
	local directory = vim.fs.joinpath(root, "folder")
	assert(vim.fn.writefile({ "# Guide" }, guide) == 0)
	assert(vim.fn.writefile({ "# Escaped" }, escaped) == 0)
	assert(vim.fn.writefile({ "# Escaped hash" }, escaped_hash) == 0)
	assert(vim.fn.writefile({ "# Entity" }, entity) == 0)
	assert(vim.fn.mkdir(directory, "p", 448) == 1)
	local readme = vim.fs.joinpath(root, "README.md")
	local uppercase_file_uri = vim.uri_from_fname(guide):gsub("^file:", "FILE:")
	local line = table.concat({
		"[web](https://example.test/a#part)",
		"[doc](guide.md)",
		"[uri](" .. vim.uri_from_fname(guide) .. ")",
		"[upper-uri](" .. uppercase_file_uri .. ")",
		"[escaped](foo\\(x\\).md)",
		"[escaped-hash](foo\\#bar.md)",
		"[numeric-hash](foo&#35;bar.md)",
		"[entity](foo&amp;bar.md)",
		"[numeric](foo&#38;bar.md)",
		"![image](guide.md)",
		"[anchor](guide.md#part)",
		"[ref][guide]",
		"<mailto:me@example.test>",
		"bare https://bare.test/a.",
		"balanced https://en.wikipedia.org/wiki/Function_(mathematics).",
		"[bad](ftp://example.test)",
		"[dir](folder)",
		"[unknown-entity](foo&copy;.md)",
	}, " ")
	local bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(bufnr, readme)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "plain_symbol" })
	vim.api.nvim_set_current_buf(bufnr)
	vim.bo[bufnr].filetype = "markdown"

	local mapping = vim.fn.maparg("gd", "n", false, true)
	assert(type(mapping.callback) == "function", "Markdown gd mapping is missing")
	assert(mapping.desc == "Open Markdown target or definition", "Markdown gd description changed")
	assert(type(navigation.handler(bufnr)) == "function", "LSP attach cannot recover the Markdown handler")

	vim.ui.open = function(value)
		opened_urls[#opened_urls + 1] = value
		return {}
	end
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	vim.fn.setreg = function(register, value, kind)
		copied[#copied + 1] = { register, value, kind }
		return 0
	end
	vim.env.SSH_TTY = nil
	vim.env.SSH_CONNECTION = nil

	local function follow(needle, offset)
		local first = assert(line:find(needle, 1, true), "missing fixture target: " .. needle)
		vim.api.nvim_win_set_cursor(0, { 1, first - 1 + (offset or 1) })
		return navigation.follow(bufnr)
	end
	local canonical_guide = vim.uv.fs_realpath(guide) or vim.fs.normalize(guide)

	assert(follow("[web]"))
	equal("https://example.test/a#part", opened_urls[#opened_urls], "HTTP fragment did not open locally")
	assert(follow("[doc]"))
	equal(
		canonical_guide,
		vim.uv.fs_realpath(opened_files[#opened_files]),
		"relative file did not use the tab-first editor adapter"
	)
	assert(follow("[uri]"))
	equal(canonical_guide, vim.uv.fs_realpath(opened_files[#opened_files]), "file URI did not use the editor adapter")
	assert(follow("[upper-uri]"))
	equal(canonical_guide, vim.uv.fs_realpath(opened_files[#opened_files]), "uppercase file URI was not normalized")
	assert(follow("[escaped]"))
	equal(
		vim.uv.fs_realpath(escaped),
		vim.uv.fs_realpath(opened_files[#opened_files]),
		"CommonMark backslash escapes were not decoded"
	)
	assert(follow("[escaped-hash]"))
	equal(
		vim.uv.fs_realpath(escaped_hash),
		vim.uv.fs_realpath(opened_files[#opened_files]),
		"escaped hash was mistaken for a Markdown fragment"
	)
	assert(follow("[numeric-hash]"))
	equal(
		vim.uv.fs_realpath(escaped_hash),
		vim.uv.fs_realpath(opened_files[#opened_files]),
		"numeric hash entity was mistaken for a Markdown fragment"
	)
	assert(follow("[entity]"))
	equal(vim.uv.fs_realpath(entity), vim.uv.fs_realpath(opened_files[#opened_files]), "named entity was not decoded")
	assert(follow("[numeric]"))
	equal(vim.uv.fs_realpath(entity), vim.uv.fs_realpath(opened_files[#opened_files]), "numeric entity was not decoded")
	assert(follow("![image]", 3))
	equal(
		canonical_guide,
		vim.uv.fs_realpath(opened_files[#opened_files]),
		"image target did not use the editor adapter"
	)
	assert(follow("[anchor]"))
	assert(follow("[ref]"))
	equal(2, #marksman, "anchor and reference links did not route exclusively through Marksman")
	assert(follow("mailto:me", 2))
	equal("mailto:me@example.test", opened_urls[#opened_urls], "mailto autolink was not normalized")
	assert(follow("https://bare", 3))
	equal("https://bare.test/a", opened_urls[#opened_urls], "bounded bare URL retained punctuation")
	assert(follow("https://en.wikipedia", 3))
	equal(
		"https://en.wikipedia.org/wiki/Function_(mathematics)",
		opened_urls[#opened_urls],
		"balanced trailing parenthesis was stripped from a bare URL"
	)

	local action_count = #opened_urls + #opened_files + #marksman + definitions
	assert(not follow("[bad]"), "unsupported URL scheme was accepted")
	assert(not follow("[dir]"), "directory target was accepted as a file")
	assert(not follow("[unknown-entity]"), "unknown named entity escaped bounded decoding")
	equal(
		action_count,
		#opened_urls + #opened_files + #marksman + definitions,
		"rejected target fell through to another action"
	)
	assert(table.concat(notifications, "\n"):find("Unsupported Markdown link scheme: ftp", 1, true))
	assert(table.concat(notifications, "\n"):find("does not exist: folder", 1, true))
	assert(table.concat(notifications, "\n"):find("unsupported named character reference", 1, true))

	vim.api.nvim_win_set_cursor(0, { 2, 2 })
	assert(navigation.follow(bufnr))
	equal(1, definitions, "plain Markdown text did not use definition fallback")

	vim.env.SSH_TTY = ""
	vim.env.SSH_CONNECTION = ""
	assert(follow("[web]"))
	equal(0, #copied, "empty SSH variables were treated as an SSH session")
	vim.env.SSH_CONNECTION = "client 1 2 3"
	local local_open_count = #opened_urls
	assert(follow("[web]"))
	equal(local_open_count, #opened_urls, "SSH link launched a remote host opener")
	equal(
		{ "+", "https://example.test/a#part", "v" },
		copied[#copied],
		"SSH link did not copy through the clipboard provider"
	)

	allowed = false
	local before_blocked = #opened_urls + #opened_files + #marksman + definitions
	assert(not follow("[web]"), "blocked review content escaped Markdown navigation")
	equal(
		before_blocked,
		#opened_urls + #opened_files + #marksman + definitions,
		"blocked navigation performed an action"
	)

	vim.bo[bufnr].filetype = "text"
	assert(buffer_mapping(bufnr, "gd") == nil, "Markdown gd mapping leaked after a filetype change")
	assert(navigation.handler(bufnr) == nil, "Markdown handler remained available outside Markdown")
	vim.bo[bufnr].filetype = "markdown"
	assert(buffer_mapping(bufnr, "gd") ~= nil, "Markdown gd mapping did not recover after a filetype change")
	local lsp_handler = navigation.handler(bufnr)
	assert(type(lsp_handler) == "function", "LSP attach could not reuse the owned Markdown handler")
	vim.keymap.set("n", "gd", lsp_handler, { buffer = bufnr, silent = true, desc = "Go to definition" })
	vim.bo[bufnr].filetype = "text"
	assert(buffer_mapping(bufnr, "gd") == nil, "LSP attach left an owned Markdown gd mapping after a filetype change")
	vim.bo[bufnr].filetype = "markdown"
	local external_definition = function() end
	vim.keymap.set("n", "gd", external_definition, { buffer = bufnr, desc = "External definition" })
	vim.bo[bufnr].filetype = "text"
	equal("External definition", buffer_mapping(bufnr, "gd").desc, "cleanup deleted a mapping owned by another adapter")
	vim.keymap.del("n", "gd", { buffer = bufnr })

	vim.ui.open = original_open
	vim.notify = original_notify
	vim.fn.setreg = original_setreg
	vim.env.SSH_TTY = original_ssh_tty
	vim.env.SSH_CONNECTION = original_ssh_connection
	vim.fn.delete(root, "rf")
	vim.api.nvim_buf_delete(bufnr, { force = true })
	vim.api.nvim_buf_delete(review_buf, { force = true })
	pcall(vim.api.nvim_del_augroup_by_name, "NvimConfigMarkdownNavigation")
	package.loaded["config.editor"] = original_editor
	package.loaded["config.pager"] = original_pager
	package.loaded["config.clipboard"] = original_clipboard
	package.loaded["config.markdown_navigation"] = original_navigation
end)

test("LSP boundary selects Marksman exactly and reports its absence without fallback", function()
	local saved = {}
	local original_navigation_history = package.loaded["config.navigation_history"]
	for _, name in ipairs({
		"config.editor",
		"config.markdown_navigation",
		"config.native_review",
		"config.lsp_navigation",
	}) do
		saved[name] = package.loaded[name]
	end
	local original_get_clients = vim.lsp.get_clients
	local original_notify = vim.notify
	local opened
	local filters = {}
	local notifications = {}
	local review = {
		blocked = function()
			return false
		end,
		enforce_blocked = function()
			return false
		end,
	}
	package.loaded["config.editor"] = {
		open_file_in_tab = function(path, position)
			opened = { path = path, position = position }
		end,
	}
	package.loaded["config.navigation_history"] = {
		capture = function()
			return nil
		end,
		same_location = function(left, right)
			return vim.deep_equal(left, right)
		end,
		record_transition = function()
			return false
		end,
	}
	local markdown_options
	package.loaded["config.markdown_navigation"] = {
		setup = function(options)
			markdown_options = options
			return true
		end,
		handler = function()
			return nil
		end,
	}
	package.loaded["config.native_review"] = { lsp = review }
	package.loaded["config.lsp_navigation"] = nil
	local lsp_navigation = require("config.lsp_navigation")
	vim.notify = function(message)
		notifications[#notifications + 1] = tostring(message)
	end
	lsp_navigation.setup()
	assert(type(markdown_options.eligible) == "function", "LSP adapter omitted the reviewer eligibility boundary")
	assert(markdown_options.eligible(0), "ordinary Markdown buffer was rejected by the LSP adapter")

	local bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[link](target.md)" })
	vim.lsp.get_clients = function(filter)
		filters[#filters + 1] = vim.deepcopy(filter)
		return {}
	end
	assert(not lsp_navigation.definition_at_for_client("marksman", bufnr, 1, 3, "Markdown link"))
	equal("marksman", filters[#filters].name, "named definition request was not restricted to Marksman")
	assert(table.concat(notifications, "\n"):find("no active marksman client", 1, true), "missing Marksman was silent")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local target = 1", "", "print(target)" })
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 3, 8 })
	assert(lsp_navigation.definition_or_native(bufnr), "missing LSP did not preserve native gd")
	equal(1, vim.api.nvim_win_get_cursor(0)[1], "native gd fallback did not find the local declaration")

	local target = vim.fn.tempname() .. ".md"
	assert(vim.fn.writefile({ "# Target" }, target) == 0)
	local client = {
		id = 73,
		name = "marksman",
		offset_encoding = "utf-16",
		request = function(self, method, params, handler, request_bufnr)
			assert(self.name == "marksman")
			assert(method == "textDocument/definition")
			assert(params.position.line == 0 and request_bufnr == bufnr)
			handler(nil, {
				uri = vim.uri_from_fname(target),
				range = {
					start = { line = 0, character = 0 },
					["end"] = { line = 0, character = 1 },
				},
			})
			return true, 1
		end,
	}
	vim.lsp.get_clients = function(filter)
		filters[#filters + 1] = vim.deepcopy(filter)
		return { client }
	end
	assert(lsp_navigation.definition_at_for_client("marksman", bufnr, 1, 3, "Markdown link"))
	equal(vim.fs.normalize(target), vim.fs.normalize(opened.path), "Marksman result bypassed tab-first opening")
	equal({ lnum = 1, col = 1 }, opened.position, "Marksman result lost its source position")

	review.blocked = function()
		return true
	end
	assert(not markdown_options.eligible(bufnr), "historical review buffer remained eligible for Markdown mapping")
	vim.lsp.get_clients = function()
		error("blocked review buffer queried LSP clients")
	end
	assert(not lsp_navigation.definition_at_for_client("marksman", bufnr, 1, 3, "Markdown link"))
	assert(table.concat(notifications, "\n"):find("historical review content", 1, true), "review block was bypassed")

	vim.fn.delete(target)
	vim.api.nvim_buf_delete(bufnr, { force = true })
	vim.lsp.get_clients = original_get_clients
	vim.notify = original_notify
	pcall(vim.api.nvim_del_augroup_by_name, "LspKeymaps")
	for name, value in pairs(saved) do
		package.loaded[name] = value
	end
	package.loaded["config.navigation_history"] = original_navigation_history
end)

if #failures > 0 then
	error(table.concat(failures, "\n\n"))
end

print(("markdown_spec: %d tests passed"):format(count))
vim.cmd("quitall!")
