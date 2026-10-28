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

local temporary = {}

local equal = require("tests.helpers").equal

local hooks = {}
local T = MiniTest.new_set({ hooks = hooks })

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

T["host owns commands, keymaps, renderer commands, and presenters"] = function()
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
	assert(package.loaded["config.native_review"] == nil, "diagram registration initialized native review")
	local render_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(render_buf)
	vim.bo[render_buf].filetype = "md-render"
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "n", false, true)), "rendered diagram mapping is missing")
	assert(not vim.tbl_isempty(vim.fn.maparg("<leader>md", "x", false, true)), "rendered visual mapping is missing")

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
	assert(package.loaded["config.native_review"] == nil, "ordinary DiagramShow initialized native review")
	local core = require("diagram_view")
	local status = core.status()
	equal({ "image:svg", "mermaid:ascii", "mermaid:svg", "plantuml:ascii", "plantuml:svg" }, status.renderers)
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
end

T["managed tool resolution stays deferred until an explicit render"] = function()
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
end

local function with_image_viewer(callback, options)
	options = options or {}
	local original_snacks = _G.Snacks
	local original_notify = vim.notify
	local jobs, placements = {}, {}
	local context = { jobs = jobs, placements = placements }
	local timers, images = {}, {}
	context.requests = {}
	context.uploads = 0
	local next_id = 0
	local function new_image(path)
		if not images[path] then
			context.uploads = context.uploads + 1
			images[path] = {
				id = context.uploads + 100,
				ready = function()
					return true
				end,
				place = function(_, placement)
					if not placement.id then
						next_id = next_id + 1
						placement.id = next_id
					end
				end,
				del = function() end,
			}
		end
		return images[path]
	end
	context.idle = function()
		for _, timer in ipairs(timers) do
			if timer.ms == 100 and not timer.closed then
				timer.closed = true
				timer.callback()
			end
		end
	end
	context.present = function()
		for _, placement in ipairs(placements) do
			if not placement.closed and placement.opts.on_update then
				placement.opts.on_update(placement)
			end
		end
	end
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
					env = function()
						return { placeholders = options.placeholders == true }
					end,
					detect = function(callback)
						callback({ terminal = options.terminal or "ghostty", version = options.version or "1.4.0" })
					end,
					request = function(request)
						context.requests[#context.requests + 1] = vim.deepcopy(request)
					end,
					size = function()
						return { cell_width = 10, cell_height = 20 }
					end,
				},
				image = { new = new_image },
				util = {
					dim = function()
						return context.dimensions or { width = 600, height = 300 }
					end,
				},
				placement = {
					new = function(buf, path, opts)
						local placement = {
							buf = buf,
							path = path,
							options = opts,
							opts = opts,
							img = new_image(path),
						}
						placement.img:place(placement)
						placement.ready = function()
							return not placement.closed
						end
						placement.wins = function()
							return vim.fn.win_findbuf(buf)
						end
						placement.render_grid = function(_, loc)
							if placement.hidden then
								placement.grid = nil
							else
								placement.grid = vim.deepcopy(loc)
							end
						end
						placement.show = function()
							placement.hidden = false
						end
						placement.hide = function()
							placement.hidden = true
						end
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
			defer = function(done, ms)
				local timer = { callback = done, ms = ms }
				timer.stop = function() end
				timer.close = function()
					timer.closed = true
				end
				timer.is_closing = function()
					return timer.closed == true
				end
				timers[#timers + 1] = timer
				return timer
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
			if source_job.argv[1] == "/verified/mmdflux" then
				complete(source_job, "<svg/>")
			end
			local raster_job = jobs[#jobs]
			equal("/verified/rsvg-convert", raster_job.argv[1], "renderer never reached raster stage")
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

T["placeholder zoom and pan respond before rendering and refine only after a pause"] = function()
	with_image_viewer(function(context)
		context.finish()
		local presentation = context.presentation
		local base = presentation.preview
		local original = presentation.path
		equal(2, context.uploads)
		context.press("+")
		for _ = 1, 20 do
			context.press("l")
			context.press("h")
		end
		equal(2, #context.jobs, "input started renderer processes before the pause")
		equal(2, context.uploads, "pan retransmitted the base image")
		equal(1, #context.placements, "pan recreated the placement")
		local crop = context.requests[#context.requests]
		equal(presentation.preview_source.id, crop.i)
		equal(presentation.preview_owner.id, crop.p)
		equal(base.img.id, crop.P)
		equal(base.id, crop.Q)
		assert(not crop.U, "Ghostty ignores cropping on virtual placements")
		assert(crop.w < presentation.dimensions.width, "preview did not crop the image")
		context.idle()
		equal(3, #context.jobs, "the pause did not run exactly one rasterizer")
		equal("/verified/rsvg-convert", context.jobs[3].argv[1])
		equal("<svg/>", context.jobs[3].options.stdin)
		context.finish()
		assert(not base.hidden, "preview was hidden before the sharp image was ready")
		context.present()
		assert(base.hidden and not base.grid, "sharp image did not hide the preview")
		context.press("l")
		assert(not base.hidden and base.grid, "pan did not restore the uploaded preview")
		equal(3, #context.jobs)
		equal(3, context.uploads, "pan uploaded another PNG")
		context.press("0")
		context.idle()
		equal(3, #context.jobs, "fit did not cancel the refinement timer")
		equal(original, presentation.path, "preview changed the whole-diagram clipboard image")
		context.press("+")
		context.idle()
		equal(3, #context.jobs, "cached refinement reran its renderer")
		assert(presentation.pending_frame == nil, "synchronous cached refinement left pending work")
	end, { placeholders = true })
end

T["preview retains the requested view on failure and cancels late work on movement or close"] = function()
	with_image_viewer(function(context)
		context.finish()
		context.press("+")
		context.idle()
		local obsolete = context.jobs[#context.jobs]
		context.press("+")
		assert(obsolete.killed)
		local count = #context.placements
		context.complete(obsolete, "\137PNG\r\n\26\nlate")
		equal(count, #context.placements, "late raster replaced the current preview")
		context.idle()
		context.complete(context.jobs[#context.jobs], "", 1)
		equal(2.25, context.presentation.viewport.zoom, "refinement failure jumped back to an old viewport")
		assert(context.presentation.preview.grid)
		context.press("l")
		context.idle()
		local pending = context.jobs[#context.jobs]
		pending.fail_kill = true
		context.press("q")
		assert(vim.api.nvim_win_is_valid(context.presentation.win), "failed cancellation lost its retry UI")
		pending.fail_kill = false
		context.press("q")
		assert(not vim.api.nvim_win_is_valid(context.presentation.win))
		context.complete(pending, "\137PNG\r\n\26\nlate")
		context.idle()
		equal(count, #context.placements, "late work recreated a closed image")
	end, { placeholders = true })
end

T["preview geometry keeps centred axes, bounds and the resized viewport"] = function()
	for _, dimensions in ipairs({ { width = 600, height = 1800 }, { width = 3600, height = 300 } }) do
		with_image_viewer(function(context)
			context.dimensions = dimensions
			context.finish()
			context.press("+")
			local presentation = context.presentation
			local portrait = dimensions.height > dimensions.width
			local before = #context.requests
			context.press(portrait and "l" or "j")
			equal(before, #context.requests, "a fitting axis moved")
			for _ = 1, 40 do
				context.press(portrait and "j" or "l")
			end
			local crop = context.requests[#context.requests]
			assert(crop.x >= 0 and crop.x + crop.w <= dimensions.width)
			assert(crop.y >= 0 and crop.y + crop.h <= dimensions.height)
			assert(
				portrait and crop.c < vim.api.nvim_win_get_width(presentation.win)
					or not portrait and crop.r < vim.api.nvim_win_get_height(presentation.win)
			)
			vim.api.nvim_win_set_config(presentation.win, { width = 55, height = 14 })
			vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
			crop = context.requests[#context.requests]
			assert(crop.c <= 55 and crop.r <= 14)
			equal(14, vim.api.nvim_buf_line_count(presentation.buf))
			context.press("q")
			context.idle()
			equal(2, #context.jobs, "closing did not cancel resized refinement")
		end, { placeholders = true })
	end
end

T["terminal version reports select only compatible relative placements"] = function()
	for _, case in ipairs({
		{ "ghostty", "1.3.0", false },
		{ "ghostty", "unknown", false },
		{ "kitty(0.30.0)\27\\", "", false },
		{ "kitty(0.31.0)\27\\", "", true },
		{ "ghostty", "1.4.0\27\\", true },
	}) do
		with_image_viewer(function(context)
			context.finish()
			equal(case[3], context.presentation.preview ~= nil)
			context.press("+")
			equal(case[3] and 2 or 3, #context.jobs, "incorrect preview or fallback rendering")
			context.idle()
			context.finish()
			if not case[3] then
				equal(0, #context.requests, "unsupported terminal received a relative placement")
			end
		end, { placeholders = true, terminal = case[1], version = case[2] })
	end
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

T["image zoom and pan crop the source, cancel obsolete frames, and keep the float"] = function()
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
		equal("<svg/>", raster.options.stdin, "viewport did not reuse the prepared SVG")
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
end

T["cached zoom delivery is synchronous-safe and clipboard keeps the whole diagram"] = function()
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
end

T["failed and late image frames preserve displayed content and close cancels work"] = function()
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
end

T["portrait geometry keeps its pixel aspect and zoom and pan stop at their bounds"] = function()
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
end

T["zoom uses the full float and centers axes that still fit"] = function()
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
end

T["failed cancellation retains the pending frame for a close retry"] = function()
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
end

local function write_file(path, data)
	local fd = assert(vim.uv.fs_open(path, "w", 420))
	assert(vim.uv.fs_write(fd, data, 0))
	vim.uv.fs_close(fd)
	return path
end

local function be16(value)
	return string.char(math.floor(value / 256), value % 256)
end

local function png_bytes(width, height)
	return "\137PNG\r\n\26\n"
		.. "\0\0\0\13IHDR"
		.. string.char(0, 0, be16(width):byte(1), be16(width):byte(2))
		.. string.char(0, 0, be16(height):byte(1), be16(height):byte(2))
		.. "\8\2\0\0\0"
		.. "payload"
end

T["image references resolve to local files and reject remote or unsupported media"] = function()
	local image = require("config.diagram_image")
	local root = vim.fn.tempname()
	assert(vim.fn.mkdir(root, "p") == 1)
	temporary[#temporary + 1] = root
	local shot = write_file(root .. "/shot.png", png_bytes(640, 480))
	write_file(root .. "/with space.png", png_bytes(8, 4))
	write_file(root .. "/hash#1.png", png_bytes(8, 4))
	write_file(root .. "/vector.svg", '<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>')
	write_file(root .. "/notes.txt", "plain text, not an image")
	assert(vim.fn.mkdir(root .. "/assets", "p") == 1)

	equal(vim.fs.normalize(shot), assert(image.resolve("shot.png", root)))
	equal(vim.fs.normalize(shot), assert(image.resolve("./shot.png", root)))
	equal(vim.fs.normalize(shot), assert(image.resolve("<shot.png>", root)))
	equal(vim.fs.normalize(shot), assert(image.resolve("shot.png#fragment", root)))
	-- A percent-encoded "#" is part of the filename, not a fragment.
	equal(vim.fs.normalize(root .. "/hash#1.png"), assert(image.resolve("hash%231.png", root)))
	-- A percent-encoded space is a real filename, not a scheme.
	equal(vim.fs.normalize(root .. "/with space.png"), assert(image.resolve("with%20space.png", root)))
	equal(vim.fs.normalize(shot), assert(image.resolve(shot, nil)))
	equal(vim.fs.normalize(shot), assert(image.resolve("../shot.png", root .. "/assets")))

	for _, remote in ipairs({
		"https://example.test/a.png",
		"http://example.test/a.png",
		"//example.test/a.png",
		"data:image/png;base64,AAAA",
		"file:///etc/hosts",
	}) do
		local resolved, err = image.resolve(remote, root)
		assert(resolved == nil, "remote reference must not resolve: " .. remote)
		assert(err:find("remote images are not rendered", 1, true), "unexpected rejection: " .. tostring(err))
	end

	local missing, missing_err = image.resolve("absent.png", root)
	assert(missing == nil and missing_err:find("image not found", 1, true), tostring(missing_err))
	local directory, directory_err = image.resolve("assets", root)
	assert(directory == nil and directory_err:find("not a regular file", 1, true), tostring(directory_err))
	local relative, relative_err = image.resolve("shot.png", nil)
	assert(relative == nil and relative_err:find("no directory", 1, true), tostring(relative_err))

	equal({ "png", 640, 480 }, { image.identify(png_bytes(640, 480)) })
	equal({ "gif", 12, 7 }, { image.identify("GIF89a" .. "\12\0\7\0" .. "rest") })
	equal({ "jpeg", 300, 200 }, { image.identify("\255\216\255\192\0\17\8" .. be16(200) .. be16(300) .. "\3\1\17\0") })
	equal({ "svg" }, { image.identify('<svg xmlns="http://www.w3.org/2000/svg"/>') })
	equal({}, { image.identify("plain text, not an image") })

	local loaded = assert(image.load(shot))
	equal("png", loaded.format)
	equal(640, loaded.width)
	assert(loaded.source:find('viewBox="0 0 640 480"', 1, true), "the wrapper lost the intrinsic size")
	assert(loaded.source:find("data:image/png;base64,", 1, true), "the wrapper did not embed the image")
	assert(loaded.source:find(vim.base64.encode(png_bytes(640, 480)), 1, true), "embedded bytes differ")

	local vector = assert(image.load(root .. "/vector.svg"))
	equal("svg", vector.format)
	assert(vector.source:find("<rect/>", 1, true), "an SVG must reach the renderer unwrapped")

	local unsupported, unsupported_err = image.load(root .. "/notes.txt")
	assert(unsupported == nil and unsupported_err:find("unsupported image format", 1, true), tostring(unsupported_err))
	local oversized, oversized_err = image.load(shot, 8)
	assert(oversized == nil and oversized_err:find("viewer limit", 1, true), tostring(oversized_err))
end

local function with_markdown_image(options, callback)
	local original_snacks = _G.Snacks
	local original_notify = vim.notify
	local jobs, placements, notifications = {}, {}, {}
	local adapter = assert(package.loaded["config.diagram"])
	local root = vim.fn.tempname()
	assert(vim.fn.mkdir(root, "p") == 1)
	temporary[#temporary + 1] = root
	write_file(root .. "/shot.png", png_bytes(600, 300))
	local ok, err = xpcall(function()
		vim.notify = function(message)
			notifications[#notifications + 1] = message
		end
		_G.Snacks = {
			image = {
				supports_terminal = function()
					return options.terminal ~= false
				end,
				terminal = {
					size = function()
						return { cell_width = 10, cell_height = 20 }
					end,
				},
				util = {
					dim = function()
						return { width = 600, height = 300 }
					end,
				},
				placement = {
					new = function(buf, path, placement_options)
						local placement = { buf = buf, path = path, options = placement_options }
						placement.close = function() end
						placements[#placements + 1] = placement
						return placement
					end,
				},
			},
		}
		assert(adapter.setup({
			cache_root = cache_root(),
			resolve_executable = function(executable)
				if options.missing_tool then
					return nil, "not found on the host PATH"
				end
				return "/verified/" .. executable
			end,
			spawn = function(argv, spawn_options, done)
				jobs[#jobs + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(spawn_options), callback = done }
				return { kill = function() end }
			end,
			schedule = function(done)
				done()
			end,
			notify = function() end,
		}))
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, root .. "/doc.md")
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].filetype = "markdown"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Doc", "", "![captura](shot.png)" })
		vim.api.nvim_win_set_cursor(0, { 3, 3 })
		local session, show_err = adapter.show(options.mode or "svg")
		callback({
			session = session,
			error = show_err,
			jobs = jobs,
			placements = placements,
			notifications = notifications,
			root = root,
			complete = function(job, output)
				job.callback({ code = 0, stdout = output, stderr = "" })
			end,
		})
		if session then
			session:cancel("test cleanup")
		end
	end, debug.traceback)
	_G.Snacks = original_snacks
	vim.notify = original_notify
	assert(ok, err)
end

T["a Markdown image renders, zooms, and pans through the SVG pipeline"] = function()
	with_markdown_image({}, function(context)
		local session = assert(context.session, "the image did not open: " .. tostring(context.error))
		equal(1, #context.jobs, "an image needs exactly one rasterizing stage")
		local job = context.jobs[1]
		equal("/verified/rsvg-convert", job.argv[1])
		assert(job.options.stdin:find("data:image/png;base64,", 1, true), "the renderer did not receive the wrapper")
		assert(not job.options.text, "PNG output must not be decoded as text")
		assert(
			vim.api.nvim_win_get_config(session.presentation.win).title[1][1]:find("shot.png", 1, true),
			"the float did not name the image"
		)

		context.complete(job, "\137PNG\r\n\26\n" .. "fit")
		equal(1, #context.placements, "the fitted image was never placed")
		equal(1, session.presentation.viewport.zoom)

		vim.api.nvim_buf_call(session.presentation.buf, function()
			assert(vim.fn.maparg("+", "n", false, true).callback)()
		end)
		equal(2, #context.jobs, "zoom did not render a new frame")
		local zoomed = context.jobs[2]
		local flags = table.concat(zoomed.argv, " ")
		assert(flags:find("--page-width=", 1, true), "the zoomed frame lost its viewport")
		assert(flags:find("--left=", 1, true), "the zoomed frame lost its offset")
		equal(zoomed.options.stdin, job.options.stdin, "zoom re-rendered from different bytes")
		context.complete(zoomed, "\137PNG\r\n\26\n" .. "zoom")
		equal(1.5, session.presentation.viewport.zoom)

		vim.api.nvim_buf_call(session.presentation.buf, function()
			assert(vim.fn.maparg("l", "n", false, true).callback)()
		end)
		equal(3, #context.jobs, "pan did not render a new frame")
	end)
end

T["an image refuses to degrade to ASCII and reports a missing rasterizer"] = function()
	with_markdown_image({ terminal = false }, function(context)
		assert(context.session == nil, "an image must not open without inline image support")
		assert(context.error:find("inline image support", 1, true), tostring(context.error))
		equal(0, #context.jobs, "no renderer may run without image support")
	end)
	with_markdown_image({ mode = "ascii" }, function(context)
		local session = assert(context.session, "an explicit ascii request must still show the image")
		equal(1, #context.jobs, "the image did not reach the rasterizing stage")
		equal("/verified/rsvg-convert", context.jobs[1].argv[1])
		assert(
			vim.iter(context.notifications):any(function(message)
				return message:find("no ASCII rendering", 1, true) ~= nil
			end),
			"the ascii request was silently upgraded: " .. vim.inspect(context.notifications)
		)
		session:cancel("ascii case done")
	end)
	with_markdown_image({ missing_tool = true }, function(context)
		assert(context.session == nil, "a missing rasterizer must not open a window")
		assert(context.error:find("rsvg%-convert"), tostring(context.error))
		assert(context.error:find("shot.png", 1, true), "the failure must name the image")
	end)
end

T["local plugin contains no host imports, global commands, or mappings"] = function()
	local files = vim.fn.glob(plugin .. "/lua/**/*.lua", false, true)
	assert(#files > 0)
	for _, path in ipairs(files) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(not contents:match([[require%s*%(%s*["']config%.]]), path .. " imports config.*")
		assert(not contents:find("nvim_create_user_command", 1, true), path .. " creates a global command")
		assert(not contents:find("vim.keymap.set", 1, true), path .. " creates a mapping")
	end
end

hooks.post_once = function()
	for _, path in ipairs(temporary) do
		vim.fn.delete(path, "rf")
	end
end

return T
