vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/diagram-view.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0
local temporary = {}

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
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

local function cache_root()
	local parent = vim.fn.tempname()
	assert(vim.fn.mkdir(parent, "p") == 1)
	temporary[#temporary + 1] = parent
	return parent .. "/diagram-v3"
end

package.loaded["config.local_config"] = {
	plugin = function(_, fallback)
		return fallback
	end,
}
package.loaded["config.pager"] = { active = false }

test("host owns commands, keymaps, renderer commands, and presenters", function()
	local jobs_a = {}
	local jobs_b = {}
	local pending_killed = false
	local function spawn_into(jobs)
		return function(argv, options, callback)
			jobs[#jobs + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
			if not tostring(options.stdin):find("PENDING", 1, true) then
				callback({ code = 0, stdout = "ASCII", stderr = "" })
			end
			return {
				kill = function()
					pending_killed = true
				end,
			}
		end
	end
	local adapter = require("config.diagram")
	assert(package.loaded.diagram_view == nil, "host adapter loaded diagram-view before setup")
	assert(adapter.setup({
		cache_root = cache_root(),
		spawn = spawn_into(jobs_a),
		resolve_executable = function(executable)
			return "/verified/" .. executable
		end,
		schedule = function(callback)
			callback()
		end,
		notify = function() end,
	}))

	equal(2, vim.fn.exists(":DiagramShow"), "host command is missing")
	assert(package.loaded.diagram_view == nil, "host registration initialized diagram-view")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
	local mapping = vim.fn.maparg("<leader>md", "n", false, true)
	vim.api.nvim_set_current_buf(buf)
	mapping = vim.fn.maparg("<leader>md", "n", false, true)
	assert(not vim.tbl_isempty(mapping), "host markdown mapping is missing")
	local visual_mapping = vim.fn.maparg("<leader>md", "x", false, true)
	assert(not vim.tbl_isempty(visual_mapping), "host visual diagram mapping is missing")
	assert(visual_mapping.rhs:find("'<,'>DiagramShow", 1, true), "visual mapping did not preserve its range")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ignored", "A --> B", "B --> C", "ignored" })
	local command_ok, command_err = pcall(vim.cmd, "2,3DiagramShow ascii")
	assert(command_ok, command_err)
	equal("A --> B\nB --> C", jobs_a[#jobs_a].options.stdin, "visual command did not pass the selected lines")
	equal({ "/verified/mmdflux" }, jobs_a[#jobs_a].argv, "renderer did not use the resolved executable path")
	assert(package.loaded.diagram_view ~= nil, "first DiagramShow did not initialize diagram-view")
	assert(package.loaded["config.tool_bootstrap"] == nil, "injected resolver still loaded the tool bootstrap")
	local core = require("diagram_view")
	local status = core.status()
	equal({ "mermaid:ascii", "mermaid:svg", "plantuml:ascii", "plantuml:svg" }, status.renderers)
	equal({ "ascii", "image", "image_frame" }, status.presenters)
	assert(core.register_presenter("pending", {
		open = function()
			return {}
		end,
		deliver = function() end,
	}))
	assert(core.open({
		renderer = "plantuml:ascii",
		presenter = "pending",
		kind = "plantuml",
		source = "@startuml\nPENDING -> B\n@enduml",
		metadata = { executables = { plantuml = "/verified/plantuml" } },
	}))
	assert(adapter.setup({
		cache_root = cache_root(),
		spawn = spawn_into(jobs_b),
		resolve_executable = function(executable)
			return "/verified/" .. executable
		end,
		schedule = function(callback)
			callback()
		end,
		notify = function() end,
	}))
	assert(pending_killed, "second host setup did not let the core cancel its active session")
	local second_ok, second_err = pcall(vim.cmd, "2,3DiagramShow ascii")
	assert(second_ok, second_err)
	equal("A --> B\nB --> C", jobs_b[#jobs_b].options.stdin, "second use did not receive setup B")

	local delivery = {}
	assert(core.register_presenter("capture", {
		open = function()
			return {}
		end,
		deliver = function(_, result)
			delivery.result = result.data
		end,
	}))
	local session = assert(core.open({
		renderer = "plantuml:ascii",
		presenter = "capture",
		kind = "plantuml",
		source = "@startuml\nA -> B\n@enduml",
		metadata = { executables = { plantuml = "/verified/plantuml" } },
	}))
	equal({ "/verified/plantuml", "-ttxt", "-pipe" }, jobs_b[#jobs_b].argv)
	equal("SANDBOX", jobs_b[#jobs_b].options.env.PLANTUML_SECURITY_PROFILE)
	equal("ASCII", delivery.result)
	equal("presented", session:status().state)
end)

test("managed tool resolution stays deferred until an explicit render", function()
	local adapter = require("config.diagram")
	local deferred = require("config.deferred")
	local original_load = deferred.load
	local loads = {}
	local jobs = {}
	local ok, err = xpcall(function()
		deferred.load = function(name)
			loads[#loads + 1] = name
			assert(name == "config.tool_bootstrap", "unexpected deferred module: " .. tostring(name))
			return {
				resolve = function(tool, command)
					equal(tool, command)
					return "/managed/" .. command
				end,
			}
		end
		assert(adapter.setup({
			cache_root = cache_root(),
			spawn = function(argv, _, callback)
				jobs[#jobs + 1] = vim.deepcopy(argv)
				callback({ code = 0, stdout = "ASCII", stderr = "" })
				return { kill = function() end }
			end,
			schedule = function(callback)
				callback()
			end,
			notify = function() end,
		}))
		equal({}, loads, "host setup resolved a managed tool eagerly")

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_set_option_value("filetype", "mermaid", { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "A --> B" })
		assert(adapter.show("ascii"))
		equal({ "config.tool_bootstrap" }, loads)
		equal({ { "/managed/mmdflux" } }, jobs)
	end, debug.traceback)
	deferred.load = original_load
	assert(ok, err)
end)

local function with_image_viewer(callback)
	local original_snacks = _G.Snacks
	local original_notify = vim.notify
	local jobs, placements = {}, {}
	local context = { jobs = jobs, placements = placements }
	local adapter = assert(package.loaded["config.diagram"])
	local function complete(job, output, code)
		job.callback({ code = code or 0, stdout = output or "", stderr = code and "fixture failure" or "" })
	end
	context.complete = complete
	local ok, err = xpcall(function()
		vim.notify = function() end
		_G.Snacks = {
			image = {
				supports_terminal = function()
					return true
				end,
				terminal = {
					size = function()
						return { cell_width = 10, cell_height = 20 }
					end,
				},
				util = {
					dim = function()
						return context.dimensions or { width = 600, height = 300 }
					end,
				},
				placement = {
					new = function(buf, path, options)
						local placement = { buf = buf, path = path, options = options }
						placement.close = function()
							placement.closed = true
						end
						placements[#placements + 1] = placement
						return placement
					end,
				},
			},
		}
		assert(adapter.setup({
			cache_root = cache_root(),
			resolve_executable = function(executable)
				return "/verified/" .. executable
			end,
			spawn = function(argv, options, done)
				local job = { argv = vim.deepcopy(argv), options = vim.deepcopy(options), callback = done }
				jobs[#jobs + 1] = job
				return {
					kill = function()
						if job.fail_kill then
							return false
						end
						job.killed = true
					end,
				}
			end,
			schedule = function(done)
				done()
			end,
			notify = function() end,
		}))
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].filetype = "mermaid"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "graph LR", "A --> B" })
		context.session = assert(adapter.show("svg"))
		context.presentation = context.session.presentation
		context.press = function(lhs)
			vim.api.nvim_buf_call(context.presentation.buf, function()
				local mapping = vim.fn.maparg(lhs, "n", false, true)
				assert(type(mapping.callback) == "function", "missing image mapping: " .. lhs)
				mapping.callback()
			end)
		end
		context.finish = function()
			local source_job = jobs[#jobs]
			complete(source_job, "<svg/>")
			local raster_job = jobs[#jobs]
			assert(raster_job ~= source_job, "renderer never reached raster stage")
			complete(raster_job, "\137PNG\r\n\26\n" .. table.concat(raster_job.argv, "|"))
			return raster_job
		end
		callback(context)
	end, debug.traceback)
	if context.session then
		context.session:cancel("test cleanup")
	end
	_G.Snacks = original_snacks
	vim.notify = original_notify
	assert(ok, err)
end

local function argument(argv, name)
	for index, value in ipairs(argv) do
		if value == name then
			return tonumber(argv[index + 1])
		end
		if value:sub(1, #name + 1) == name .. "=" then
			return tonumber(value:sub(#name + 2))
		end
	end
end

test("image zoom and pan crop the source, cancel obsolete frames, and keep the float", function()
	with_image_viewer(function(context)
		local presentation, jobs = context.presentation, context.jobs
		context.press("+")
		equal(1, #jobs, "zoom before the original image is ready started a render")
		context.finish()
		local original = presentation.path
		local win = presentation.win
		context.press("+")
		local obsolete_job = jobs[#jobs]
		local obsolete_frame = presentation.pending_frame
		context.press("=")
		assert(obsolete_job.killed, "rapid zoom did not cancel the obsolete render")
		local job_count = #jobs
		context.complete(obsolete_job, "<svg/>")
		equal(job_count, #jobs, "obsolete source completion started another raster stage")
		equal("cancelled", obsolete_frame:status().state)
		assert(not context.placements[1].closed, "old image disappeared while zoom was rendering")
		local raster = context.finish()
		equal("graph LR\nA --> B", jobs[#jobs - 1].options.stdin)
		assert(argument(raster.argv, "-w") > argument(raster.argv, "--page-width"))
		assert(argument(raster.argv, "-h") > argument(raster.argv, "--page-height"))
		assert(argument(raster.argv, "--left") < 0 and argument(raster.argv, "--top") < 0)
		equal(win, presentation.win, "zoom opened a different float")
		assert(context.placements[1].closed)
		local displayed = presentation.displayed_frame
		for _ = 1, 20 do
			context.press("<Right>")
			context.press("j")
		end
		raster = context.finish()
		equal(argument(raster.argv, "--page-width") - argument(raster.argv, "-w"), argument(raster.argv, "--left"))
		equal(argument(raster.argv, "--page-height") - argument(raster.argv, "-h"), argument(raster.argv, "--top"))
		equal("cancelled", displayed:status().state, "replaced frame still retained its cache entry")
		displayed = presentation.displayed_frame
		context.press("h")
		local pending = presentation.pending_frame
		context.press("0")
		equal("cancelled", pending:status().state)
		equal("cancelled", displayed:status().state)
		equal(original, context.placements[#context.placements].path)
		equal({ zoom = 1, x = 0.5, y = 0.5 }, presentation.viewport)
		assert(vim.inspect(vim.api.nvim_win_get_config(win).footer):find("100%%"))
	end)
end)

test("cached zoom delivery is synchronous-safe and clipboard keeps the whole diagram", function()
	with_image_viewer(function(context)
		context.finish()
		local presentation = context.presentation
		local original = presentation.path
		context.press("+")
		context.finish()
		local frame_path = context.placements[#context.placements].path
		context.press("-")
		local job_count = #context.jobs
		context.press("+")
		equal(job_count, #context.jobs, "same viewport bypassed the core cache")
		equal(frame_path, context.placements[#context.placements].path)
		assert(presentation.pending_frame == nil, "synchronous delivery left an obsolete pending session")
		assert(presentation.displayed_frame ~= nil)
		equal(original, presentation.path, "zoom replaced the full-diagram clipboard source")
		local original_system = vim.system
		local clipboard_argv
		vim.system = function(argv)
			clipboard_argv = argv
		end
		local ok, err = pcall(context.press, "y")
		vim.system = original_system
		assert(ok, err)
		if clipboard_argv then
			assert(vim.tbl_contains(clipboard_argv, original), "clipboard did not receive the original PNG")
		end
	end)
end)

test("failed and late image frames preserve displayed content and close cancels work", function()
	with_image_viewer(function(context)
		context.finish()
		context.press("+")
		context.finish()
		local presentation = context.presentation
		local shown = context.placements[#context.placements]
		local shown_viewport = vim.deepcopy(presentation.viewport)
		context.press("+")
		context.complete(context.jobs[#context.jobs], "", 1)
		equal(shown_viewport, presentation.viewport, "failure left a zoom level that was never displayed")
		assert(not shown.closed, "failed zoom removed the old image")
		assert(presentation.pending_frame == nil)
		context.press("+")
		local pending = presentation.pending_frame
		local displayed = presentation.displayed_frame
		local late = context.jobs[#context.jobs]
		context.press("q")
		assert(late.killed)
		equal("cancelled", pending:status().state)
		equal("cancelled", displayed:status().state)
		assert(not vim.api.nvim_win_is_valid(presentation.win))
		local placement_count = #context.placements
		context.complete(late, "<svg/>")
		equal(placement_count, #context.placements, "late render reopened a closed diagram")
	end)
end)

test("portrait geometry keeps its pixel aspect and zoom and pan stop at their bounds", function()
	with_image_viewer(function(context)
		context.dimensions = { width = 600, height = 1800 }
		context.finish()
		for _ = 1, 12 do
			context.press("+")
		end
		equal(8, context.presentation.viewport.zoom)
		local count_before = #context.jobs
		context.press("+")
		equal(count_before, #context.jobs, "zoom above its bound started another render")
		local raster = context.finish()
		local width = argument(raster.argv, "-w")
		local height = argument(raster.argv, "-h")
		local page_width = argument(raster.argv, "--page-width")
		local page_height = argument(raster.argv, "--page-height")
		assert(math.abs(width * 3 - height) < 3, "portrait render lost its aspect to terminal-cell rounding")
		equal(vim.api.nvim_win_get_width(context.presentation.win) * 10, page_width, "viewport omits float columns")
		equal(vim.api.nvim_win_get_height(context.presentation.win) * 20, page_height, "viewport omits float rows")
		for _ = 1, 40 do
			context.press("h")
			context.press("<Up>")
		end
		raster = context.finish()
		equal(0, argument(raster.argv, "--left"))
		equal(0, argument(raster.argv, "--top"))
		context.press("0")
		count_before = #context.jobs
		context.press("-")
		context.press("l")
		equal(count_before, #context.jobs, "fit image panned or zoomed below its bound")
	end)
end)

test("zoom uses the full float and centers axes that still fit", function()
	for _, dimensions in ipairs({ { width = 600, height = 1800 }, { width = 3600, height = 300 } }) do
		with_image_viewer(function(context)
			context.dimensions = dimensions
			context.finish()
			local win = context.presentation.win
			local width, height = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
			local fit = context.placements[#context.placements].options
			context.press("+")
			context.press("+")
			local raster = context.finish()
			local options = context.placements[#context.placements].options
			equal({ 1, 0 }, options.pos, "zoom retains the fitted image's inset")
			equal(width, options.max_width, "zoom is constrained to the fitted image width")
			equal(height, options.max_height, "zoom is constrained to the fitted image height")
			assert(options.conceal, "image does not overlay its buffer canvas")
			equal({ 1, 0, height, 0 }, options.range, "image canvas does not cover the full float")
			equal(
				height,
				vim.api.nvim_buf_line_count(context.presentation.buf),
				"last image row falls outside the canvas"
			)
			equal(width * 10, argument(raster.argv, "--page-width"), "raster viewport is narrower than the float")
			equal(height * 20, argument(raster.argv, "--page-height"), "raster viewport is shorter than the float")
			local portrait = dimensions.height > dimensions.width
			local page = argument(raster.argv, portrait and "--page-width" or "--page-height")
			local content = argument(raster.argv, portrait and "-w" or "-h")
			local offset = argument(raster.argv, portrait and "--left" or "--top")
			assert(content < page, "fixture does not exercise a non-overflowing axis")
			equal(math.floor((page - content) / 2 + 0.5), offset, "non-overflowing content is not centered")
			local jobs_before = #context.jobs
			context.press(portrait and "h" or "j")
			equal(jobs_before, #context.jobs, "pan moved an axis that already fits")
			for _ = 1, 40 do
				context.press(portrait and "j" or "l")
			end
			raster = context.finish()
			local page_end = argument(raster.argv, portrait and "--page-height" or "--page-width")
			local content_end = argument(raster.argv, portrait and "-h" or "-w")
			equal(page_end - content_end, argument(raster.argv, portrait and "--top" or "--left"))
			context.press("0")
			equal(fit, context.placements[#context.placements].options, "fit reset retained the full zoom canvas")
		end)
	end
end)

test("failed cancellation retains the pending frame for a close retry", function()
	with_image_viewer(function(context)
		context.finish()
		context.press("+")
		local job = context.jobs[#context.jobs]
		local frame = context.presentation.pending_frame
		job.fail_kill = true
		context.press("+")
		equal(frame, context.presentation.pending_frame, "failed cancellation lost the owned process")
		equal(1, context.presentation.viewport.zoom)
		context.press("q")
		assert(vim.api.nvim_win_is_valid(context.presentation.win), "failed close lost the retry interface")
		equal("cancel-failed", context.session:status().state)
		job.fail_kill = false
		context.press("q")
		assert(job.killed)
		assert(not vim.api.nvim_win_is_valid(context.presentation.win))
		equal("cancelled", frame:status().state)
	end)
end)

test("local plugin contains no host imports, global commands, or mappings", function()
	local files = vim.fn.glob(plugin .. "/lua/**/*.lua", false, true)
	assert(#files > 0)
	for _, path in ipairs(files) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(not contents:match([[require%s*%(%s*["']config%.]]), path .. " imports config.*")
		assert(not contents:find("nvim_create_user_command", 1, true), path .. " creates a global command")
		assert(not contents:find("vim.keymap.set", 1, true), path .. " creates a mapping")
	end
	local host = table.concat(vim.fn.readfile(repo .. "/lua/config/diagram.lua"), "\n")
	assert(host:find("nvim_create_user_command", 1, true), "command did not remain in the host adapter")
	assert(host:find("vim.keymap.set", 1, true), "mappings did not remain in the host adapter")
	assert(host:find("Snacks.image.placement.new", 1, true), "Snacks presenter did not remain in the host adapter")
end)

for _, path in ipairs(temporary) do
	vim.fn.delete(path, "rf")
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("diagram_view_spec: %d host contract tests passed"):format(count))
vim.cmd("quitall!")
