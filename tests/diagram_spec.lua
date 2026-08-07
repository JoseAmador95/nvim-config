vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local test_cache_home = vim.fn.tempname()
vim.fn.mkdir(test_cache_home, "p")
vim.env.XDG_CACHE_HOME = test_cache_home

package.loaded["config.local_config"] = {
	get = function(_, default)
		return default
	end,
}

local failures = {}
local count = 0

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
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

local function make_buffer(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

local function delete_buffer(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

local blocks = require("config.diagram_blocks")

test("diagram scanner accepts homogeneous backtick and tilde fences", function()
	local buf = make_buffer({
		"````Mermaid title",
		"flowchart LR",
		"  A --> B",
		"`````",
		"~~~plantuml",
		"@startuml",
		"A -> B",
		"@enduml",
		"~~~~",
	})

	local found = blocks.find(buf, { mermaid = true, plantuml = true })
	equal(2, #found, "expected both diagram blocks")
	equal({ s0 = 0, e0 = 3, lang = "mermaid", src = "flowchart LR\n  A --> B" }, found[1], "backtick block")
	equal({ s0 = 4, e0 = 8, lang = "plantuml", src = "@startuml\nA -> B\n@enduml" }, found[2], "tilde block")

	delete_buffer(buf)
end)

test("diagram scanner rejects malformed closes and shields unsupported outer fences", function()
	local buf = make_buffer({
		"````mermaid",
		"flowchart TD",
		"```", -- too short
		"```~", -- non-empty trailing text, not a close
		"````",
		"~~~text",
		"```mermaid",
		"hidden --> diagram",
		"```",
		"~~~",
		"`~`mermaid", -- mixed opening characters
		"ignored",
		"`~`",
		"```~text", -- malformed mixed outer fence must not shield the valid block
		"```mermaid",
		"visible",
		"```",
		"```~",
	})

	local found = blocks.find(buf, { mermaid = true })
	equal(2, #found, "valid diagrams around malformed and unsupported fences")
	equal("flowchart TD\n```\n```~", found[1].src, "short and malformed closes should remain source text")
	equal("visible", found[2].src, "a malformed mixed outer fence must not shield a valid diagram")

	delete_buffer(buf)
end)

test("diagram cursor lookup follows the source window and hidden-buffer mark", function()
	local source = make_buffer({
		"```mermaid",
		"first",
		"```",
		"between",
		"```mermaid",
		"second",
		"```",
	})
	vim.api.nvim_set_current_buf(source)
	local first_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(first_win, { 2, 0 })

	vim.cmd("vsplit")
	local second_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(second_win, { 6, 0 })

	local first = blocks.under_cursor(source, { mermaid = true }, first_win)
	local second = blocks.under_cursor(source, { mermaid = true }, second_win)
	equal("first", first and first.src, "explicit first source window")
	equal("second", second and second.src, "explicit second source window")
	equal("second", blocks.under_cursor(source, { mermaid = true }).src, "current source window")

	local other = make_buffer({ "unrelated" })
	vim.api.nvim_win_set_buf(second_win, other)
	vim.api.nvim_win_set_cursor(first_win, { 6, 0 })
	local fallback = blocks.under_cursor(source, { mermaid = true }, second_win)
	equal("second", fallback and fallback.src, "unrelated explicit window must fall back to a source window")

	-- Leaving the source window records line 6 in the buffer's special '"'
	-- mark. No edit should be needed: '.' is the last-change mark, not a cursor.
	vim.api.nvim_set_current_win(first_win)
	vim.api.nvim_win_set_cursor(first_win, { 6, 0 })
	vim.api.nvim_set_current_win(second_win)
	vim.api.nvim_win_close(first_win, true)
	local last_cursor = vim.api.nvim_buf_get_mark(source, '"')
	equal(6, last_cursor[1], "hidden source did not retain its last cursor position")
	local hidden = blocks.under_cursor(source, { mermaid = true })
	equal("second", hidden and hidden.src, "hidden source buffer should use its last cursor mark")

	delete_buffer(other)
	delete_buffer(source)
end)

test("binary writer preserves embedded NUL bytes and replaces atomically", function()
	local fs = require("config.fs")
	local path = vim.fn.tempname()
	local first = "\137PNG\r\n\26\n\0first\0payload"
	local second = "\137PNG\r\n\26\n\0second\0payload"

	local ok, err = fs.write_binary_atomic(path, first)
	assert(ok, err)
	ok, err = fs.write_binary_atomic(path, second)
	assert(ok, err)

	local fd, open_err = vim.uv.fs_open(path, "r", 0)
	assert(fd, open_err)
	local stat, stat_err = vim.uv.fs_fstat(fd)
	assert(stat, stat_err)
	local actual, read_err = vim.uv.fs_read(fd, stat.size, 0)
	assert(actual, read_err)
	assert(vim.uv.fs_close(fd))
	equal(second, actual, "binary contents changed")
	equal({}, vim.fn.glob(path .. ".tmp.*", false, true), "temporary files were left behind")
	assert(fs.temp_path(path) ~= fs.temp_path(path), "renderer temporary paths collided")

	vim.fn.delete(path)
end)

test("async runner ignores stale results, cancels safely, and coalesces pending work", function()
	local callbacks = {}
	local started = {}
	local killed = {}
	local delivered = {}
	local finished = {}
	local function spawn(command, _, callback)
		started[#started + 1] = command[1]
		callbacks[command[1]] = callback
		local handle = {}
		function handle:kill(signal)
			killed[#killed + 1] = { command[1], signal }
		end
		return handle
	end
	local runner = require("config.async_runner").new({
		spawn = spawn,
		schedule = function(callback)
			callback()
		end,
	})
	local function request(name)
		runner:request({
			command = { name },
			on_result = function()
				delivered[#delivered + 1] = name
			end,
			on_finish = function(_, current, reason)
				finished[#finished + 1] = { name, current, reason }
			end,
		})
	end

	request("first")
	request("second")
	request("third")
	equal({ "first" }, started, "superseded requests started concurrently")
	equal({ { "first", 15 } }, killed, "active process was not cancelled exactly once")
	callbacks.first({ code = 143 })
	equal({ "first", "third" }, started, "latest queued request did not start")
	callbacks.third({ code = 0, stdout = "newest" })
	equal({ "third" }, delivered, "stale process result was delivered")
	equal("second", finished[1][1], "superseded pending request was not cleaned up")
	equal(false, finished[1][2], "superseded pending request was marked current")

	request("late")
	runner:close()
	callbacks.late({ code = 0 })
	equal({ "third" }, delivered, "closed runner delivered a late callback")
end)

test("async runner invalidates active work at debounce time", function()
	local process_callbacks = {}
	local timer_callback
	local delivered = {}
	local runner = require("config.async_runner").new({
		spawn = function(command, _, callback)
			process_callbacks[command[1]] = callback
			return { kill = function() end }
		end,
		schedule = function(callback)
			callback()
		end,
		new_timer = function()
			return {
				start = function(_, _, _, callback)
					timer_callback = callback
				end,
				stop = function() end,
				is_closing = function()
					return false
				end,
				close = function() end,
			}
		end,
	})
	runner:request({
		command = { "old" },
		on_result = function()
			delivered[#delivered + 1] = "old"
		end,
	})
	runner:debounce(10, function()
		return {
			command = { "new" },
			on_result = function()
				delivered[#delivered + 1] = "new"
			end,
		}
	end)
	process_callbacks.old({ code = 0 })
	equal({}, delivered, "old result landed during the debounce window")
	timer_callback()
	assert(
		vim.wait(1000, function()
			return process_callbacks["new"] ~= nil
		end, 10),
		"debounced process did not start"
	)
	process_callbacks["new"]({ code = 0 })
	equal({ "new" }, delivered, "debounced latest render was not delivered")
end)

test("diagram cache identity covers source, mode, argv, and renderer signal", function()
	local cache = require("config.diagram_cache")
	local base = { source = "A --> B", mode = "mermaid:svg", argv = { "mmdflux", "-f", "svg" }, version_signal = "v1" }
	local first = cache.key(base)
	equal(first, cache.key(base), "identical cache material changed key")
	assert(first ~= cache.key(vim.tbl_extend("force", base, { source = "A --> C" })), "source was omitted from key")
	assert(first ~= cache.key(vim.tbl_extend("force", base, { mode = "mermaid:ascii" })), "mode was omitted from key")
	assert(
		first ~= cache.key(vim.tbl_extend("force", base, { argv = { "mmdflux" } })),
		"renderer argv was omitted from key"
	)
	assert(
		first ~= cache.key(vim.tbl_extend("force", base, { version_signal = "v2" })),
		"renderer version signal was omitted from key"
	)
end)

test("diagram cache validates PNGs and never prunes retained images", function()
	local cache = require("config.diagram_cache")
	local fs = require("config.fs")
	local dir = cache.dir()
	local png = "\137PNG\r\n\26\n"
		.. "\0\0\0\13IHDR"
		.. "\0\0\0\1\0\0\0\1\8\6\0\0\0"
		.. "\0\0\0\0"
		.. "\0\0\0\0IEND\0\0\0\0"
	local valid = dir .. "/valid.png"
	local invalid = dir .. "/invalid.png"
	assert(fs.write_binary_atomic(valid, png))
	assert(fs.write_binary_atomic(invalid, png:sub(1, 20)))
	equal(true, cache.is_valid_png(valid), "valid PNG was rejected")
	equal(false, cache.is_valid_png(invalid), "truncated PNG was accepted")

	local old = dir .. "/old.txt"
	local retained = dir .. "/retained.png"
	local newer = dir .. "/newer.txt"
	assert(fs.write_binary_atomic(old, string.rep("o", 12)))
	assert(fs.write_binary_atomic(retained, png))
	assert(fs.write_binary_atomic(newer, string.rep("n", 12)))
	local now = os.time()
	assert(vim.uv.fs_utime(old, now - 100, now - 100))
	assert(vim.uv.fs_utime(retained, now - 100, now - 100))
	assert(vim.uv.fs_utime(valid, now - 2, now - 2))
	assert(vim.uv.fs_utime(newer, now - 1, now - 1))
	cache.retain(retained)
	cache.prune({ max_age_seconds = 10, max_bytes = #png + 15 })
	equal(0, vim.fn.filereadable(old), "expired cache entry survived")
	equal(1, vim.fn.filereadable(retained), "retained image was pruned")
	equal(1, vim.fn.filereadable(newer), "newest entry was removed before older entries")

	cache.release(retained)
	cache.prune({ max_age_seconds = 10, max_bytes = 1024 })
	equal(0, vim.fn.filereadable(retained), "released expired image was not pruned")
end)

test("pager restores mutability only for input buffers", function()
	local pager = require("config.pager")
	local buf = make_buffer({ "result" })
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "diagram_result"
	equal(false, pager.is_input_buffer(buf), "result buffer classified as input")

	vim.bo[buf].buftype = "prompt"
	equal(true, pager.is_input_buffer(buf), "prompt buffer not classified as input")

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "snacks_picker_input"
	equal(true, pager.is_input_buffer(buf), "Snacks picker input not classified as input")

	delete_buffer(buf)
	equal(false, pager.is_input_buffer(buf), "invalid buffer classified as input")
end)

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(string.format("diagram_spec: %d tests passed", count))
vim.fn.delete(test_cache_home, "rf")
vim.cmd("quitall!")
