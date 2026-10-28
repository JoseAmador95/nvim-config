local viewport = dofile(vim.env.NVIM_CONFIG_ROOT .. "/lua/config/diagram_viewport.lua")
local T = MiniTest.new_set()

T["pinned Snacks anchors cropped relative placements through hide, pan and tmux transport"] = function()
	local terminal = Snacks.image.terminal
	local images = Snacks.image.image
	local original = {
		env = terminal.env,
		detect = terminal.detect,
		size = terminal.size,
		transform = terminal.transform,
		new = images.new,
		send = vim.api.nvim_ui_send,
	}
	local writes, uploads = {}, 0
	local session, source, cache_root
	terminal.env = function()
		return { supported = true, placeholders = true }
	end
	terminal.detect = function(callback)
		callback({ terminal = "ghostty", version = "1.4.0" })
	end
	terminal.size = function()
		return { cell_width = 10, cell_height = 20, scale = 1 }
	end
	for _, env in ipairs(terminal.envs()) do
		if env.name == "tmux" then
			terminal.transform = env.transform
		end
	end
	vim.api.nvim_ui_send = function(data)
		writes[#writes + 1] = data
	end
	local next_id = 0
	images.new = function(path)
		uploads = uploads + 1
		local anchor = path:match("diagram_anchor%.png$") ~= nil
		return {
			id = 40 + uploads,
			file = path,
			info = {
				size = anchor and { width = 1, height = 1 } or { width = 600, height = 300 },
				dpi = { width = 96, height = 96 },
			},
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
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ string.rep(" ", 40) }, 12))
	local win = vim.api.nvim_open_win(
		buf,
		true,
		{ relative = "editor", row = 0, col = 0, width = 40, height = 12, style = "minimal" }
	)
	local presentation = {
		buf = buf,
		win = win,
		dimensions = { width = 600, height = 300 },
		path = "fixture.png",
		viewport = { zoom = 2, x = 0.5, y = 0.5 },
	}
	MiniTest.finally(function()
		if session then
			session:cancel("test finished")
		end
		if source and vim.api.nvim_buf_is_valid(source) then
			vim.api.nvim_buf_delete(source, { force = true })
		end
		if cache_root then
			vim.fn.delete(cache_root, "rf")
		end
		presentation.closed = true
		viewport.close(presentation)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		vim.wait(30, function()
			return false
		end, 5)
		terminal.env, terminal.size, terminal.transform = original.env, original.size, original.transform
		terminal.detect = original.detect
		images.new, vim.api.nvim_ui_send = original.new, original.send
	end)
	local geometry = { pixel_width = 400, pixel_height = 240 }
	assert(viewport.show(presentation, geometry, 800, 400))
	assert(
		vim.wait(100, function()
			return #writes >= 3
		end, 5),
		"Snacks did not run its initial update"
	)
	local function visible_rows(target_buf)
		local count = 0
		for _, mark in
			ipairs(
				vim.api.nvim_buf_get_extmarks(target_buf or buf, Snacks.image.placement.ns, 0, -1, { details = true })
			)
		do
			if mark[4].virt_text then
				count = count + 1
			end
		end
		return count
	end
	assert(visible_rows() == 1, "preview needs exactly one transparent anchor")
	local request = writes[#writes]
	assert(request:sub(1, 7) == "\27Ptmux;", "preview bypassed Snacks' tmux transport")
	assert(request:find("x=150", 1, true) and request:find("w=300", 1, true), "source crop was not sent")
	assert(not request:find("U=1", 1, true), "Ghostty ignores source cropping on virtual placements")
	assert(request:find("P=41", 1, true) and request:find("Q=1", 1, true), "crop is not relative to the anchor")
	assert(request:find("i=42", 1, true) and request:find("p=2", 1, true), "crop did not address the source placement")
	viewport.hide(presentation)
	assert(visible_rows() == 0, "hidden preview still covers the sharp frame")
	assert(
		writes[#writes]:find("a=d", 1, true) and writes[#writes]:find("p=2", 1, true),
		"hide leaked the relative placement"
	)
	presentation.viewport.x = 0.75
	assert(viewport.show(presentation, geometry, 800, 400))
	assert(visible_rows() == 1, "pan did not restore the anchor immediately")
	assert(writes[#writes]:find("x=300", 1, true), "pan reused old crop coordinates")
	assert(uploads == 2, "moving the preview requested another image")
	presentation.viewport.x = 0.5
	assert(viewport.show(presentation, geometry, 160, 80))
	local centred = false
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Snacks.image.placement.ns, 0, -1, { details = true })) do
		if mark[4].virt_text then
			centred = mark[2] == 4 and mark[3] == 12
		end
	end
	assert(centred, "the one-cell anchor lost horizontal or vertical centring")
	viewport.close(presentation)
	assert(visible_rows() == 0, "closing leaked placeholders")

	-- Exercise the host handoff with real extmarks: replacing the blank canvas
	-- must not erase the anchor before Snacks displays the new sharp placement.
	local host = assert(package.loaded["config.diagram"])
	local jobs = {}
	cache_root = vim.fn.tempname()
	assert(host.setup({
		cache_root = cache_root,
		resolve_executable = function(name)
			return "/verified/" .. name
		end,
		spawn = function(_, _, done)
			jobs[#jobs + 1] = done
			return { kill = function() end }
		end,
		schedule = function(done)
			done()
		end,
	}))
	source = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(source)
	vim.bo[source].filetype = "mermaid"
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "graph LR", "A --> B" })
	session = assert(host.show("svg"))
	jobs[1]({ code = 0, stdout = "<svg/>", stderr = "" })
	local png = "\137PNG\r\n\26\n" .. string.rep("\0", 8) .. string.char(0, 0, 2, 88, 0, 0, 1, 44)
	jobs[2]({ code = 0, stdout = png, stderr = "" })
	local current = session.presentation
	vim.api.nvim_buf_call(current.buf, function()
		vim.fn.maparg("+", "n", false, true).callback()
	end)
	assert(
		vim.wait(200, function()
			return #jobs == 3
		end, 5),
		"refinement did not start"
	)
	assert(visible_rows(current.buf) == 1, "preview anchor missing before refinement")
	jobs[3]({ code = 0, stdout = png .. "sharp", stderr = "" })
	assert(current.placement and not current.preview.hidden)
	assert(visible_rows(current.buf) == 1, "sharp handoff erased the preview before its placement was ready")
	assert(
		vim.wait(200, function()
			return current.preview.hidden == true
		end, 5),
		"sharp placement did not hide the preview"
	)
end

return T
