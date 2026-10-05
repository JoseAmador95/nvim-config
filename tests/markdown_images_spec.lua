vim.o.shadafile = "NONE"
vim.o.swapfile = false
vim.o.hidden = true
vim.g.mapleader = " "

local repo = vim.fn.getcwd()
local plugin_root = vim.env.NVIM_CONFIG_MD_RENDER_ROOT
	or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "md-render.nvim")
assert(vim.uv.fs_stat(plugin_root), "md-render.nvim checkout is required for markdown_images_spec")
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin_root)
package.path = table.concat({
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	plugin_root .. "/lua/?.lua",
	plugin_root .. "/lua/?/init.lua",
	package.path,
}, ";")

package.loaded["config.lazy_lock"] = {
	plugin = function()
		return { branch = "main", commit = "cb79d5a1c4cd929fe0144c4d75be50a1ad4c2c74" }
	end,
}

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

-- A complete 1x1 RGBA PNG.
local PNG = vim.text.hexdecode(
	"89504E470D0A1A0A0000000D4948445200000001000000010806000000"
		.. "1F15C4890000000D49444154789C63000100000500010D0A2DB40000000049454E44AE426082"
)

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local state_path = vim.fs.joinpath(root, "state", "markdown-images.json")
local run_id = tostring(vim.uv.hrtime())

local function write(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end

local function remote(name)
	return ("https://images.example.invalid/%s/%s.png"):format(run_id, name)
end

-- Requests reach a fake network: curl writes the PNG it was asked for. The
-- offline switch is exercised by its own test.
vim.env.NVIM_CONFIG_OFFLINE = nil
local system = vim.system
local curls = {}
vim.system = function(argv, opts, callback)
	if argv[1] ~= "curl" then
		return system(argv, opts, callback)
	end
	curls[#curls + 1] = argv
	local output
	for index, value in ipairs(argv) do
		if value == "--output" then
			output = argv[index + 1]
		end
	end
	write(assert(output, "curl was not given an output path"), PNG)
	vim.schedule(function()
		callback({ code = 0, stdout = "", stderr = "" })
	end)
	return {}
end

local selects = {}
vim.ui.select = function(items, opts, on_choice)
	selects[#selects + 1] = { items = items, opts = opts, on_choice = on_choice }
end

local notices = {}
local notify = vim.notify
vim.notify = function(message, level, opts)
	notices[#notices + 1] = message
	return notify(message, level, opts)
end

local pager = require("config.pager")
pager.active = false
local view = require("config.markdown_view")
local images = require("config.markdown_images")
require("config.markdown_navigation").setup({
	allowed = function()
		return true
	end,
	definition = function()
		return false
	end,
	marksman = function()
		return false
	end,
})
assert(view.configure_renderer(), "pinned renderer could not initialize")
require("config.viewer_commands")
local image = require("md-render.image")
local preview = require("md-render").preview

local function reset()
	images._reset({ supported = true, state_path = state_path })
	selects = {}
	curls = {}
	notices = {}
end

local function choose(id)
	local request = assert(selects[#selects], "no image choice was offered")
	for _, item in ipairs(request.items) do
		if item.id == id then
			request.on_choice(item)
			return
		end
	end
	error("image choice is missing: " .. id)
end

local function offered(id)
	for _, item in ipairs(selects[#selects].items) do
		if item.id == id then
			return true
		end
	end
	return false
end

local function placement_for(session, predicate)
	for _, placement in ipairs(session.content.image_placements or {}) do
		if predicate(placement) then
			return placement
		end
	end
	return nil
end

local function open(name, lines)
	vim.cmd("tabonly")
	vim.cmd("only")
	local path = vim.fs.joinpath(root, name)
	write(path, table.concat(lines, "\n") .. "\n")
	vim.cmd.edit(vim.fn.fnameescape(path))
	local source = vim.api.nvim_get_current_buf()
	vim.bo[source].filetype = "markdown"
	view.toggle()
	local session = assert(preview._toggle_sessions[source], "reading view did not open")
	return source, session
end

local function close(source)
	if vim.b[vim.api.nvim_get_current_buf()].md_render then
		view.toggle()
	end
	vim.api.nvim_buf_delete(source, { force = true })
end

local function forget_cache(url)
	local cached = image.get_cached(url)
	if cached then
		os.remove(cached)
	end
end

write(vim.fs.joinpath(root, "pixel.png"), PNG)

test("guard keeps diagrams, video and document paths inert", function()
	reset()
	assert(not image.has_mmdc() and not image.has_plantuml(), "diagram fences may render automatically")
	assert(not image.is_video_file("clip.mp4"), "video files may render automatically")
	local sentinel = vim.fs.joinpath(root, "SENTINEL")
	for _, lines in ipairs({
		{ ("![a](`touch${IFS}%s`)"):format(sentinel) },
		{ ("![a](<`touch %s`>)"):format(sentinel) },
		{ "| image |", "|---|", ("| ![a](`touch${IFS}%s`) |"):format(sentinel) },
		{ ("![a](`touch${IFS}%s`.mp4)"):format(sentinel) },
	}) do
		pcall(preview.build_content, lines, { buf_dir = root })
	end
	assert(not vim.uv.fs_stat(sentinel), "a Markdown image path ran a shell command")
	assert(image.resolve("$HOME/pixel.png", root) == nil, "an image path expanded an environment variable")
	assert(image.resolve("*.png", root) == nil, "an image path expanded a glob")
	assert(image.resolve("pixel.png", root), "a plain relative image path did not resolve")
	assert(#curls == 0, "a build without a document fetched an image")
end)

test("unapproved remote images stay text and ask once", function()
	reset()
	local url = remote("blocked")
	local source, session = open("blocked.md", {
		"# Images",
		"![local](pixel.png)",
		("![remote](%s)"):format(url),
		"![plain](http://images.example.invalid/plain.png)",
		"```mermaid",
		"graph LR; A-->B",
		"```",
	})
	assert(
		vim.wait(1000, function()
			return #selects == 1
		end),
		"remote images did not ask for approval"
	)
	local prompt = selects[1].opts.prompt
	assert(
		prompt:find("1 remote image from images.example.invalid", 1, true),
		"prompt lacks count and host: " .. prompt
	)
	assert(offered("always"), "a file-backed document cannot be approved persistently")
	assert(
		placement_for(session, function(placement)
			return placement.path and placement.path:find("pixel.png", 1, true)
		end),
		"local image was not placed"
	)
	assert(not placement_for(session, function(placement)
		return placement.src_url ~= nil
	end), "an unapproved remote image reserved space")
	assert(#session.content.image_placements == 1, "a diagram fence or http image was placed")
	choose("deny")
	vim.api.nvim_buf_set_lines(source, 0, 1, false, { "# Images edited" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
	vim.wait(400)
	assert(#selects == 1, "a denied document asked again")
	assert(#curls == 0, "an unapproved document fetched an image")
	assert(
		vim.wait(500, function()
			return vim.bo[session.buf].readonly and not vim.bo[session.buf].modifiable
		end),
		"image placement left the reading view writable"
	)
	assert(not vim.fn.execute("messages"):find("W10", 1, true), "image placement raised a readonly warning")
	close(source)
end)

test("load this time fetches over https once and renders images and table cells", function()
	reset()
	local url = remote("once")
	local cell = remote("cell")
	local source, session = open("once.md", {
		("![remote](%s)"):format(url),
		"![plain](http://images.example.invalid/plain.png)",
		"",
		"| image |",
		"|---|",
		("| ![cell](%s) |"):format(cell),
	})
	assert(
		vim.wait(1000, function()
			return #selects == 1
		end),
		"remote images did not ask for approval"
	)
	assert(selects[1].opts.prompt:find("2 remote images", 1, true), "prompt did not count the table image")
	choose("load")
	assert(
		vim.wait(2000, function()
			return placement_for(session, function(placement)
				return placement.src_url == url and placement.path ~= nil
			end) ~= nil
		end),
		"approved remote image was not placed after its download"
	)
	assert(#curls == 2, "expected exactly one download per https image, got " .. #curls)
	for _, argv in ipairs(curls) do
		local joined = table.concat(argv, " ")
		assert(joined:find("--proto =https", 1, true), "download may leave https")
		assert(joined:find("--proto-redir =https", 1, true), "a redirect may leave https")
		assert(joined:find("--max-filesize", 1, true), "download size is unbounded")
		assert(not joined:find("http://", 1, true), "an http image was fetched")
	end
	assert(#selects == 1, "an approved document asked again")
	close(source)
	forget_cache(url)
	forget_cache(cell)
end)

test("always persists an owner-only approval that survives a restart and can be revoked", function()
	reset()
	local url = remote("always")
	local source, session = open("always.md", { ("![remote](%s)"):format(url) })
	assert(
		vim.wait(1000, function()
			return #selects == 1
		end),
		"remote images did not ask for approval"
	)
	choose("always")
	assert(
		vim.wait(2000, function()
			return placement_for(session, function(placement)
				return placement.src_url == url
			end) ~= nil
		end),
		"saved approval did not render the image"
	)
	local stat = assert(vim.uv.fs_stat(state_path), "approval was not saved")
	assert(stat.mode % 512 == tonumber("600", 8), "approval state is not owner-only")
	local saved = vim.json.decode(table.concat(vim.fn.readfile(state_path), "\n"))
	assert(saved.documents[vim.uv.fs_realpath(vim.fs.joinpath(root, "always.md"))], "approval names another file")
	close(source)

	reset()
	source, session = open("always.md", { ("![remote](%s)"):format(url) })
	vim.wait(300)
	assert(#selects == 0, "a saved approval asked again after a restart")
	assert(
		placement_for(session, function(placement)
			return placement.src_url == url
		end),
		"a saved approval did not place its cached image"
	)
	assert(#curls == 0, "a cached image was downloaded again")

	vim.cmd("MarkdownImages")
	assert(#selects == 1 and offered("revoke"), "saved approval cannot be revoked")
	choose("revoke")
	saved = vim.json.decode(table.concat(vim.fn.readfile(state_path), "\n"))
	assert(vim.tbl_isempty(saved.documents), "revocation left the saved approval")
	assert(not placement_for(session, function(placement)
		return placement.src_url ~= nil
	end), "a revoked document still shows its remote image")
	close(source)
	forget_cache(url)
end)

test("offline mode refuses downloads and reports them", function()
	reset()
	vim.env.NVIM_CONFIG_OFFLINE = "1"
	local url = remote("offline")
	local source, session = open("offline.md", { ("![remote](%s)"):format(url) })
	assert(
		vim.wait(1000, function()
			return #selects == 1
		end),
		"remote images did not ask for approval"
	)
	choose("load")
	assert(
		vim.wait(1000, function()
			for _, message in ipairs(notices) do
				if message:find("could not be loaded", 1, true) then
					return true
				end
			end
			return false
		end),
		"an offline failure was silent"
	)
	vim.env.NVIM_CONFIG_OFFLINE = nil
	assert(#curls == 0, "offline mode reached the network")
	assert(not placement_for(session, function(placement)
		return placement.src_url ~= nil
	end), "a failed download left a placeholder")
	close(source)
end)

test("tmux and terminals without Kitty graphics keep images as text", function()
	local tmux = vim.env.TMUX
	local ghostty = vim.env.GHOSTTY_RESOURCES_DIR
	vim.env.TMUX = "/tmp/tmux-test,1,0"
	vim.env.GHOSTTY_RESOURCES_DIR = "/Applications/Ghostty.app/Contents/Resources/ghostty"
	images._reset({ redetect = true, state_path = state_path })
	local supported, reason = images.supported()
	assert(not supported and reason:find("tmux", 1, true), "tmux was treated as an image terminal")
	assert(not image.supports_kitty(), "md-render still draws images inside tmux")
	selects = {}
	vim.cmd("enew")
	vim.bo.filetype = "markdown"
	vim.cmd("MarkdownImages")
	assert(#selects == 0, "an unsupported terminal offered to load images")
	vim.env.TMUX = tmux
	vim.env.GHOSTTY_RESOURCES_DIR = ghostty
	vim.cmd("bwipeout!")
end)

vim.fn.delete(root, "rf")
if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("markdown_images_spec: %d tests passed", count))
vim.cmd("quitall!")
