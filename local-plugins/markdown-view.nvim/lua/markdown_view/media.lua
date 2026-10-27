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

local preferences, persistent_preferences

local MAX_PARALLEL = 4
local CURL_TIMEOUT = "15"
local MAX_BYTES = "20000000"

local originals
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
local function notify(message, level)
	vim.notify(message, level or vim.log.levels.WARN, { title = "Markdown images" })
end

local function document(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	local real = name ~= "" and vim.uv.fs_realpath(name) or nil
	local key = real or ("buffer:" .. buf)
	local doc = documents[key]
	if not doc then
		doc = {
			key = key,
			label = real and vim.fn.fnamemodify(real, ":~:.") or "this document",
			blocked = {},
			pending = {},
			failed = {},
			loading = 0,
			arrived = false,
		}
		documents[key] = doc
	end
	doc.persistent = real ~= nil and persistent_preferences
	doc.buf = buf
	return doc
end

local function saved(doc)
	return doc.persistent and preferences.get(doc.key) == true
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
	local doc = current and current.document
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
function M.download(url, path, callback)
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
			preferences.set(doc.key, true)
		end
		rebuild(doc)
	elseif choice == "revoke" then
		preferences.set(doc.key, nil)
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
	originals.set_supported(nil)
	local ok, value = pcall(originals.supports_kitty)
	if ok and value == true then
		return true, nil
	end
	return false, "the terminal does not support the Kitty graphics protocol"
end

-- The compatibility boundary supplies the verified stock image API. Host
-- preferences own persistence; the standalone default keeps approvals local.
function M.configure(api, callbacks, rebuild_callback)
	originals = api
	persistent_preferences = callbacks ~= nil
	preferences = callbacks or { get = function() end, set = function() end }
	rebuild_document = rebuild_callback
end

function M.is_url(value)
	if type(value) ~= "string" or not originals.is_url(value) then
		return false
	end
	-- md-render skips badges before it resolves or fetches them.
	if originals.is_badge_url(value) then
		return true
	end
	return remote_allowed(value)
end

function M.resolve(src, base_dir)
	if current and current.references_only then
		return nil
	end
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
	originals.set_supported(supported)
end

function M.supported()
	if not originals then
		return false, "the reading view is not configured"
	end
	M.reassert()
	return supported, unsupported_reason
end

-- Build scope is restored by compat's single protected build boundary, also
-- on failure and for nested snapshots. A review never acquires live media.
function M.begin(opts)
	local previous = current
	local buf = opts.nvim_config_image_doc
	local doc = type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and document(buf) or nil
	if doc then
		doc.blocked, doc.pending = {}, {}
	end
	current = { document = doc, references_only = opts.nvim_config_review or previous and previous.references_only }
	return previous
end

function M.finish(previous, success)
	local doc = current.document
	current = previous
	if success and doc then
		after_build(doc)
	end
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
		originals.set_supported(supported)
	end
end

return M
