-- Runs only in the auxiliary terminal. No Lazy bootstrap or editor services.
local snacks = require("snacks")
local theme = require("config.theme")
local diagram = require("config.diagram")
local M = {}
local generation = 0
local profile
local executables, unavailable = {}, {}

function M.update(payload)
	if type(payload) ~= "table" or type(payload.generation) ~= "number" or payload.generation <= generation then
		return
	end
	generation = payload.generation
	if payload.error then
		diagram.outdated(payload.error)
		return
	end
	local item = payload.diagram
	if
		type(item) ~= "table"
		or (item.kind ~= "mermaid" and item.kind ~= "plantuml")
		or type(item.source) ~= "string"
		or #item.source > profile.config.max_stage_output_bytes
		or (payload.mode ~= "svg" and payload.mode ~= "ascii")
	then
		diagram.outdated("Invalid diagram update")
		return
	end
	executables, unavailable = payload.executables or {}, payload.unavailable or {}
	local session, err = diagram.render(item, payload.mode, payload.reset)
	if not session then
		diagram.outdated(tostring(err))
	end
end

-- Probe an actual Unicode placement, not only image transfer. Rex drops direct
-- placements on a session redraw; placeholders survive those redraws. The tiny
-- virtual image is never drawn and is removed after the acknowledgement.
local function probe_graphics(done)
	local finished = false
	local event
	local function finish(supported)
		if finished then
			return
		end
		finished = true
		vim.api.nvim_del_autocmd(event)
		vim.api.nvim_ui_send("\27_Ga=d,d=I,i=7091,q=2\27\\")
		snacks.image.terminal.detect(function()
			local env = snacks.image.terminal.env()
			env.supported, env.placeholders, env.remote = supported, supported, true
			done()
		end)
	end
	event = vim.api.nvim_create_autocmd("TermResponse", {
		callback = function(ev)
			if ev.data.sequence:find("Gi=7091;OK", 1, true) then
				finish(true)
			end
		end,
	})
	vim.api.nvim_ui_send("\27_Ga=T,i=7091,s=1,v=1,f=24,U=1,c=1,r=1,q=0;AAAA\27\\")
	vim.defer_fn(function()
		finish(false)
	end, 1000)
end

function M.setup(options)
	profile = options
	vim.g.mapleader = " "
	vim.o.background = options.background
	vim.o.termguicolors = true
	vim.o.number, vim.o.relativenumber = false, false
	vim.o.signcolumn = "no"
	vim.o.showmode, vim.o.showcmd, vim.o.ruler = false, false, false
	vim.o.laststatus, vim.o.showtabline = 2, 0
	vim.o.mouse = "a"
	vim.opt.fillchars:append({ eob = " " })
	vim.opt.shortmess:append("I")
	snacks.setup({ image = { enabled = true, doc = { enabled = false } } })
	theme.setup()
	assert(diagram.setup({
		embedded = true,
		config = options.config,
		cache_root = options.cache_root,
		resolve_executable = function(name)
			return executables[name], unavailable[name]
		end,
		on_close = function()
			vim.schedule(function()
				vim.cmd("qa!")
			end)
		end,
	}))
	_G.NvimRexDiagram = M
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			vim.cmd("qa!")
		end, { nowait = true })
	end
	vim.wo.statusline = " Diagram — connecting…"
	local focus_generation = 0
	vim.api.nvim_create_autocmd("FocusGained", {
		callback = function()
			focus_generation = focus_generation + 1
			local captured = focus_generation
			vim.defer_fn(function()
				if captured == focus_generation then
					local ok, err = pcall(diagram.refresh)
					if not ok then
						diagram.outdated("Could not restore image: " .. tostring(err))
					end
				end
			end, 100)
		end,
	})
	for _, address in ipairs(vim.fn.serverlist()) do
		vim.fn.serverstop(address)
	end
	vim.api.nvim_create_autocmd("VimEnter", {
		once = true,
		callback = function()
			probe_graphics(function()
				vim.fn.serverstart(options.socket)
				assert(vim.uv.fs_chmod(options.socket, 384))
			end)
		end,
	})
	local parent_timer = assert(vim.uv.new_timer())
	parent_timer:start(
		1000,
		1000,
		vim.schedule_wrap(function()
			if not vim.uv.kill(options.parent_pid, 0) then
				vim.cmd("qa!")
			end
		end)
	)
	vim.api.nvim_create_autocmd("VimLeavePre", {
		once = true,
		callback = function()
			diagram.teardown()
			parent_timer:stop()
			parent_timer:close()
		end,
	})
end

return M
