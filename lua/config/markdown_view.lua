local usage_map = require("config.usage").mapper("config.markdown_view")
-- Compose the standalone reader with host locks, theme, navigation and profiles.
local M = {}
local view = require("markdown_view")
local deferred = require("config.deferred")
local lazy_lock = require("config.lazy_lock")
local images = require("config.markdown_images")
local pager = require("config.pager")
local palette = require("config.palette")
local navigation = not pager.active and not vim.g.vscode and require("config.markdown_render_navigation") or nil
local source = assert(debug.getinfo(1, "S").source:match("^@(.+)$"))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
M.PIN = view.PIN
local configure_error, notified_error
local function fail(message)
	if notified_error ~= message then
		vim.notify(message, vim.log.levels.ERROR, { title = "Markdown" })
		notified_error = message
	end
	return nil, message
end

local function disable_upstream_entrypoints()
	for _, name in ipairs({
		"MdRender",
		"MdRenderTab",
		"MdRenderToggle",
		"MdRenderSplit",
		"MdRenderPager",
		"MdRenderDemo",
		"MdRenderAuto",
	}) do
		pcall(vim.api.nvim_del_user_command, name)
	end
	for _, name in ipairs({ "preview", "preview-tab", "toggle", "auto", "split", "demo" }) do
		pcall(vim.keymap.del, "n", "<Plug>(md-render-" .. name .. ")")
	end
end

-- Lazy rewrites the shared lock from installed plugins only, so a restore
-- while md-render is missing prunes its entry and disables the spec.
local function lock_unavailable(lock_err)
	return (
		"Markdown reading view unavailable: %s; run git -C %s checkout -- lazy-lock.json, "
		.. "then :Lazy install md-render.nvim and restart"
	):format(tostring(lock_err), repo_root)
end

function M.lock_ok()
	local entry, lock_err = lazy_lock.plugin(repo_root, "md-render.nvim")
	if not entry then
		return nil, lock_err
	end
	if entry.commit ~= M.PIN then
		return nil, ("md-render.nvim must be pinned to v3.10.3 (%s); lock has %s"):format(M.PIN, entry.commit)
	end
	return true
end

local function attach(session)
	navigation.attach(session)
	usage_map("n", "<leader>mv", M.toggle, { buffer = session.buf, desc = "Close Markdown reading view" })
	usage_map("n", "<leader>md", "<cmd>DiagramShow<cr>", { buffer = session.buf, desc = "Show diagram (SVG/ASCII)" })
	usage_map("x", "<leader>md", ":<C-U>'<,'>DiagramShow<CR>", { buffer = session.buf, desc = "Show selected diagram" })
end

function M.configure_renderer()
	local locked, err = M.lock_ok()
	local ok
	if locked then
		local loaded, engine = deferred.try("md-render")
		local image_ok, image = deferred.try("md-render.image")
		local wrap_ok, wrap = deferred.try("md-render.wrap")
		if loaded and image_ok and wrap_ok then
			ok, err = view.setup({
				engine = engine,
				image = image,
				wrap = wrap,
				preferences = images.preferences,
				theme = palette.apply_markdown,
				pager = function()
					return pager.active
				end,
				attach = attach,
			})
		else
			err = "md-render.nvim could not load"
		end
	end
	configure_error = not ok
			and (locked and "Markdown reading view unavailable: " .. tostring(err) or lock_unavailable(err))
		or nil
	if not ok then
		disable_upstream_entrypoints()
		-- Startup stays quiet: the reading view reports this when it is used, and
		-- :checkhealth nvimconfig lists it.
		return nil, configure_error
	end
	return true
end

---Copied renderer state for :checkhealth nvimconfig.
function M.status()
	return { configured = view.status().configured == true and configure_error == nil, error = configure_error }
end

local function ensure_renderer()
	if view.status().configured and not configure_error then
		return true
	end
	notified_error = nil
	if configure_error then
		return fail(configure_error)
	end
	local locked, err = M.lock_ok()
	if not locked then
		return fail(lock_unavailable(err))
	end
	return fail(
		"Markdown reading view unavailable: md-render.nvim is not installed or was not loaded; "
			.. "run :Lazy install md-render.nvim (or scripts/provision-runtime --allow-network) and restart"
	)
end

function M.toggle()
	if ensure_renderer() then
		return view.toggle()
	end
end
function M.images()
	if ensure_renderer() then
		return view.images()
	end
end
function M.build_snapshot(lines, opts)
	local ok, err = ensure_renderer()
	if not ok then
		return nil, err
	end
	return view.build_snapshot(lines, opts)
end
M.set_wrap = view.set_wrap
function M.pager_show_source(win)
	if pager.active then
		return view.pager_show_source(win)
	end
end
M.pager_filetype_changed = view.pager_filetype_changed
M.pager_initial_render = view.pager_initial_render
M.diagram_target = view.diagram_target

function M.setup()
	if vim.g.vscode then
		return
	end
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("MarkdownViewPalette", { clear = true }),
		callback = palette.apply_markdown,
	})
	vim.api.nvim_create_user_command("MarkdownView", M.toggle, { desc = "Toggle rendered Markdown reading view" })
	vim.api.nvim_create_user_command("MarkdownImages", M.images, {
		desc = "Choose whether this Markdown document loads remote images",
	})
	if pager.active then
		pager.set_markdown_view(M)
		usage_map("n", "<leader>mv", M.toggle, { desc = "Toggle Markdown reading/source view" })
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "markdown",
			group = vim.api.nvim_create_augroup("PagerMarkdownView", { clear = true }),
			callback = function(args)
				M.pager_filetype_changed(args.buf)
			end,
		})
		vim.api.nvim_create_autocmd("VimEnter", {
			group = vim.api.nvim_create_augroup("PagerMarkdownInitialView", { clear = true }),
			once = true,
			callback = M.pager_initial_render,
		})
	else
		local function map(buf)
			usage_map("n", "<leader>mv", M.toggle, { buffer = buf, desc = "Toggle Markdown reading view" })
		end
		vim.api.nvim_create_autocmd("FileType", {
			pattern = "markdown",
			group = vim.api.nvim_create_augroup("MarkdownViewKeymap", { clear = true }),
			callback = function(args)
				map(args.buf)
			end,
		})
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
				map(buf)
			end
		end
	end
end

return M
