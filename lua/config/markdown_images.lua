-- Image policy for the md-render v3.10.3 reading view.
--
-- Local images render whenever the terminal speaks the Kitty graphics
-- protocol. Remote images render only over https and only after the user
-- approves the document, either for this session or persistently. Mermaid,
-- PlantUML and video stay disabled: diagrams belong to :DiagramShow.
--
-- md-render passes document-controlled paths to vim.fn.expand(), which runs
-- `backtick` commands. Every such path is checked here before upstream sees
-- it, whether or not images are displayed.
local M = {}

local fs = require("config.fs")

local STATE_VERSION = 1
local MAX_PARALLEL = 4
local CURL_TIMEOUT = "15"
local MAX_BYTES = "20000000"

local REQUIRED = {
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
}

local installed_module
local originals
local wrappers
local rebuild_document
-- Detected on first use: md-render's probe may wait on the terminal.
local supported
local unsupported_reason

-- Document whose content md-render is building. Builds are synchronous, so
-- this is set only for the duration of one build.
local current
local documents = {}
local waiting = {}
local queue = {}
local active = 0
local fetching = {}
local failed = {}
local store
local store_path_override
local store_warned = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "Markdown images" })
end

local function store_path()
	return store_path_override or vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "markdown-images.json")
end

local function load_store()
	if store then
		return store
	end
	store = { version = STATE_VERSION, documents = {} }
	local path = store_path()
	if not vim.uv.fs_stat(path) then
		return store
	end
	local data, read_err = fs.read_binary(path)
	local ok, decoded = pcall(vim.json.decode, data or "")
	if not data or not ok or type(decoded) ~= "table" or decoded.version ~= STATE_VERSION then
		if not store_warned then
			store_warned = true
			notify(("Ignoring unreadable image approvals at %s: %s"):format(path, tostring(read_err or decoded)))
		end
		return store
	end
	if type(decoded.documents) == "table" then
		for key, value in pairs(decoded.documents) do
			if type(key) == "string" and key:sub(1, 1) == "/" and value == true then
				store.documents[key] = true
			end
		end
	end
	return store
end

local function save_store()
	local path = store_path()
	vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
	local ok, err = fs.write_binary_atomic(path, vim.json.encode(load_store()))
	if not ok then
		notify("Could not save image approvals: " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

local function document(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	local real = name ~= "" and vim.uv.fs_realpath(name) or nil
	local key = real or ("buffer:" .. buf)
	local doc = documents[key]
	if not doc then
		doc = {
			key = key,
			persistent = real ~= nil,
			label = real and vim.fn.fnamemodify(real, ":~:.") or "this document",
			blocked = {},
			pending = {},
			failed = {},
			loading = 0,
			arrived = false,
		}
		documents[key] = doc
	end
	doc.buf = buf
	return doc
end

local function saved(doc)
	return doc.persistent and load_store().documents[doc.key] == true
end

local function approved(doc)
	return doc.decision == "allow" or (doc.decision == nil and saved(doc))
end

local function https(url)
	return url:match("^https://[^%s]+$") ~= nil
end

-- Whether the build in progress may treat `url` as a remote image. Only an
-- approved document's already downloaded images are placed; the rest stay
-- text until the host downloads them and rebuilds through the session.
local function remote_allowed(url)
	local doc = current
	if not doc or not supported or not https(url) then
		return false
	end
	if not approved(doc) then
		doc.blocked[url] = true
		return false
	end
	if originals.get_cached(url) then
		return true
	end
	if not failed[url] then
		doc.pending[url] = true
	end
	return false
end

-- vim.fn.expand() in md-render runs `cmd`, expands $VARS and globs. Accept
-- only paths that expand to themselves (a leading ~ is still allowed).
local function safe_local(path)
	return path ~= "" and not path:find("[%c`$*?%[{]") and not path:match("^[%%#<]")
end

local function host(url)
	local authority = url:match("^https://([^/?#]+)") or url
	return (authority:gsub("^.*@", ""))
end

local function rebuild(doc)
	if rebuild_document and doc.buf and vim.api.nvim_buf_is_valid(doc.buf) then
		local ok, err = pcall(rebuild_document, doc.buf)
		if not ok then
			notify("Could not refresh the reading view images: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function settle(doc)
	if doc.loading > 0 then
		return
	end
	local count = vim.tbl_count(doc.failed)
	if count > 0 and not doc.failures_reported then
		doc.failures_reported = true
		notify(("%d remote image%s in %s could not be loaded"):format(count, count == 1 and "" or "s", doc.label))
	end
	if doc.arrived then
		doc.arrived = false
		rebuild(doc)
	end
end

local pump

local function finished(url, path)
	fetching[url] = nil
	active = active - 1
	if not path then
		failed[url] = true
	end
	local docs = waiting[url] or {}
	waiting[url] = nil
	for doc in pairs(docs) do
		doc.loading = doc.loading - 1
		if path then
			doc.arrived = true
		else
			doc.failed[url] = true
		end
		settle(doc)
	end
	pump()
end

pump = function()
	while active < MAX_PARALLEL and #queue > 0 do
		local url = table.remove(queue, 1)
		active = active + 1
		fetching[url] = true
		local ok, err = pcall(originals.download_async, url, function(path)
			finished(url, path)
		end)
		if not ok then
			notify("Could not start an image download: " .. tostring(err), vim.log.levels.ERROR)
			finished(url, nil)
		end
	end
end

local function fetch(doc, urls)
	for url in pairs(urls) do
		if not failed[url] and not originals.get_cached(url) then
			if waiting[url] then
				if not waiting[url][doc] then
					waiting[url][doc] = true
					doc.loading = doc.loading + 1
				end
			else
				waiting[url] = { [doc] = true }
				doc.loading = doc.loading + 1
				queue[#queue + 1] = url
			end
		end
	end
	pump()
	settle(doc)
end

-- Only the host's own fetch reaches the network. A download requested from
-- anywhere else, including md-render's curl fallback, is refused.
local function download(url, path, callback)
	if not fetching[url] or vim.env.NVIM_CONFIG_OFFLINE == "1" or vim.fn.executable("curl") ~= 1 then
		callback(false)
		return true
	end
	local ok = pcall(vim.system, {
		"curl",
		"--silent",
		"--fail",
		"--location",
		"--proto",
		"=https",
		"--proto-redir",
		"=https",
		"--max-redirs",
		"5",
		"--max-time",
		CURL_TIMEOUT,
		"--max-filesize",
		MAX_BYTES,
		"--output",
		path,
		url,
	}, { text = true }, function(result)
		vim.schedule(function()
			callback(result.code == 0)
		end)
	end)
	if not ok then
		callback(false)
	end
	return true
end

local function apply(doc, choice)
	doc.prompting = false
	if choice == "load" or choice == "always" then
		doc.decision = "allow"
		for url in pairs(doc.failed) do
			failed[url] = nil
		end
		doc.failed = {}
		doc.failures_reported = false
		if choice == "always" and doc.persistent then
			load_store().documents[doc.key] = true
			save_store()
		end
		rebuild(doc)
	elseif choice == "revoke" then
		load_store().documents[doc.key] = nil
		save_store()
		doc.decision = "deny"
		rebuild(doc)
	else
		doc.decision = "deny"
	end
end

local function choices(doc)
	local items = { { id = "load", text = "Load this time" } }
	if doc.persistent and not saved(doc) then
		items[#items + 1] = { id = "always", text = "Always for this file" }
	end
	items[#items + 1] = { id = "deny", text = "Don't load" }
	if saved(doc) then
		items[#items + 1] = { id = "revoke", text = "Revoke saved approval" }
	end
	return items
end

local function ask(doc, prompt)
	doc.prompting = true
	vim.ui.select(choices(doc), {
		prompt = prompt,
		format_item = function(item)
			return item.text
		end,
	}, function(item)
		apply(doc, item and item.id or nil)
	end)
end

local function prompt_blocked(doc)
	if doc.prompting or doc.decision ~= nil or approved(doc) or not next(doc.blocked) then
		return
	end
	local urls = vim.tbl_keys(doc.blocked)
	local hosts = {}
	for _, url in ipairs(urls) do
		hosts[host(url)] = true
	end
	hosts = vim.tbl_keys(hosts)
	table.sort(hosts)
	ask(
		doc,
		("%s: load %d remote image%s from %s?"):format(
			doc.label,
			#urls,
			#urls == 1 and "" or "s",
			table.concat(hosts, ", ")
		)
	)
end

local function after_build(doc)
	if next(doc.pending) then
		local urls = doc.pending
		doc.pending = {}
		vim.schedule(function()
			fetch(doc, urls)
		end)
	end
	if next(doc.blocked) and doc.decision == nil and not doc.prompting and not approved(doc) then
		vim.schedule(function()
			prompt_blocked(doc)
		end)
	end
end

local function detect()
	if vim.env.TMUX and vim.env.TMUX ~= "" then
		return false, "tmux does not forward the Kitty graphics protocol to md-render"
	end
	originals._set_kitty_supported(nil)
	local ok, value = pcall(originals.supports_kitty)
	if ok and value == true then
		return true, nil
	end
	return false, "the terminal does not support the Kitty graphics protocol"
end

-- Install the policy on md-render's image module. Returns true, or nil plus
-- an error when the pinned contract changed; the caller then fails closed.
function M.install(image_module, rebuild_callback)
	if installed_module == image_module then
		for name, wrapper in pairs(wrappers) do
			if image_module[name] ~= wrapper then
				return nil, "image module changed after configuration: " .. name
			end
		end
		rebuild_document = rebuild_callback
		return true
	end
	if installed_module ~= nil then
		return nil, "a different md-render image module is already guarded"
	end
	for _, name in ipairs(REQUIRED) do
		if type(image_module[name]) ~= "function" then
			return nil, "v3.10.3 image contract changed: " .. name
		end
	end
	originals = {}
	for _, name in ipairs(REQUIRED) do
		originals[name] = image_module[name]
	end
	wrappers = {
		is_url = function(value)
			if type(value) ~= "string" or not originals.is_url(value) then
				return false
			end
			-- md-render skips badges before it resolves or fetches them.
			if originals.is_badge_url(value) then
				return true
			end
			return remote_allowed(value)
		end,
		resolve = function(src, base_dir)
			if type(src) ~= "string" then
				return nil
			end
			if originals.is_url(src) then
				if originals.is_badge_url(src) or not remote_allowed(src) then
					return nil
				end
				return originals.resolve(src, base_dir)
			end
			if not safe_local(src) then
				return nil
			end
			return originals.resolve(src, base_dir)
		end,
		has_mmdc = function()
			return false
		end,
		has_plantuml = function()
			return false
		end,
		is_video_file = function()
			return false
		end,
		is_video_content = function()
			return false
		end,
		download_video_async = function(_, callback)
			callback(nil)
		end,
	}
	local ok, err = pcall(function()
		originals.set_download_fn(download)
		for name, wrapper in pairs(wrappers) do
			image_module[name] = wrapper
		end
	end)
	if not ok then
		return nil, tostring(err)
	end
	installed_module = image_module
	rebuild_document = rebuild_callback
	supported = nil
	originals._set_kitty_supported(false)
	return true
end

-- Detect the capability once, then reassert it in case another consumer reset
-- md-render's cache. Called before every reading-view render.
function M.reassert()
	if not originals then
		return
	end
	if supported == nil then
		supported, unsupported_reason = detect()
	end
	originals._set_kitty_supported(supported)
end

function M.supported()
	if not originals then
		return false, "the reading view is not configured"
	end
	M.reassert()
	return supported, unsupported_reason
end

-- Run one md-render build for the document named by opts.nvim_config_image_doc.
-- Builds without a document never load remote images.
function M.around(opts, build)
	local buf = type(opts) == "table" and opts.nvim_config_image_doc or nil
	local doc
	if originals and type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) then
		doc = document(buf)
		doc.blocked = {}
		doc.pending = {}
	end
	local previous = current
	current = doc
	local ok, content = pcall(build)
	current = previous
	if not ok then
		error(content, 0)
	end
	if doc then
		after_build(doc)
	end
	return content
end

-- :MarkdownImages for the document shown in or rendered from `buf`.
function M.choose(buf)
	if not originals then
		notify("Markdown images are unavailable: the reading view is not configured")
		return
	end
	if not M.supported() then
		notify("Markdown images are unavailable: " .. tostring(unsupported_reason))
		return
	end
	local doc = document(buf)
	local count = vim.tbl_count(doc.blocked)
	local status = approved(doc) and "remote images allowed"
		or count > 0 and ("%d remote image%s blocked"):format(count, count == 1 and "" or "s")
		or "remote images not allowed"
	ask(doc, ("%s: %s%s"):format(doc.label, status, saved(doc) and " (saved)" or ""))
end

-- Test seam: isolate persisted approvals and capability detection.
function M._reset(options)
	options = options or {}
	store = nil
	store_warned = false
	store_path_override = options.state_path
	documents = {}
	waiting = {}
	queue = {}
	active = 0
	fetching = {}
	failed = {}
	current = nil
	if options.redetect and originals then
		supported = nil
		M.reassert()
	elseif options.supported ~= nil and originals then
		supported = options.supported
		unsupported_reason = supported and nil or "disabled by test"
		originals._set_kitty_supported(supported)
	end
end

return M
