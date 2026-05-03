local M = {}

local uv = vim.uv or vim.loop

-- Lua-side storage for uv timer handles (cannot survive buf-var round-trips)
local timers = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "PlantumlAscii" })
end

local function get_buf_var(buf, name)
	local ok, value = pcall(vim.api.nvim_buf_get_var, buf, name)
	if ok then
		return value
	end
	return nil
end

local function set_buf_var(buf, name, value)
	pcall(vim.api.nvim_buf_set_var, buf, name, value)
end

local function ensure_preview_buffer(source_buf)
	local buf = get_buf_var(source_buf, "plantuml_ascii_buf")
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "PlantumlAscii://" .. source_buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "plantuml_ascii"
	vim.api.nvim_buf_call(buf, function()
		vim.wo.wrap = false
	end)
	set_buf_var(source_buf, "plantuml_ascii_buf", buf)
	return buf
end

local function ensure_preview_window(source_buf, anchor_win)
	local win = get_buf_var(source_buf, "plantuml_ascii_win")
	if win and vim.api.nvim_win_is_valid(win) then
		return win
	end
	local target_win = anchor_win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		target_win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("vsplit")
	vim.cmd("wincmd L")
	win = vim.api.nvim_get_current_win()
	set_buf_var(source_buf, "plantuml_ascii_win", win)
	return win
end

local function stop_timer(buf)
	local timer = timers[buf]
	if timer and not timer:is_closing() then
		timer:stop()
		timer:close()
	end
	timers[buf] = nil
end

local function schedule_render(source_buf)
	stop_timer(source_buf)

	local anchor_win = get_buf_var(source_buf, "plantuml_ascii_anchor_win")
	local timer = uv.new_timer()
	timers[source_buf] = timer

	timer:start(
		1000,
		0,
		vim.schedule_wrap(function()
			M.render({ buf = source_buf, anchor_win = anchor_win })
			stop_timer(source_buf)
		end)
	)
end

local function setup_autocmds(source_buf)
	local existing = get_buf_var(source_buf, "plantuml_ascii_group")
	if existing and type(existing) == "number" then
		return
	end
	local group = vim.api.nvim_create_augroup("PlantumlAscii_" .. source_buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = source_buf,
		callback = function()
			schedule_render(source_buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = source_buf,
		callback = function()
			stop_timer(source_buf)
			set_buf_var(source_buf, "plantuml_ascii_group", nil)
		end,
	})
	set_buf_var(source_buf, "plantuml_ascii_group", group)
end

local function render_buffer(source_buf, anchor_win)
	if vim.fn.executable("plantuml") ~= 1 then
		notify("plantuml not found in PATH", vim.log.levels.ERROR)
		return
	end

	if not vim.api.nvim_buf_is_valid(source_buf) then
		return
	end

	local input = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
	if input == "" then
		notify("Buffer is empty", vim.log.levels.WARN)
		return
	end

	vim.system({ "plantuml", "-ttxt", "-pipe" }, { text = true, stdin = input }, function(result)
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(source_buf) then
				return
			end

			if result.code ~= 0 then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				if msg == "" then
					msg = "plantuml failed"
				end
				notify(msg, vim.log.levels.ERROR)
				return
			end

			local output = result.stdout or ""
			local lines = vim.split(output, "\n", { plain = true })

			local preview_buf = ensure_preview_buffer(source_buf)
			local preview_win = ensure_preview_window(source_buf, anchor_win)
			vim.api.nvim_win_set_buf(preview_win, preview_buf)
			vim.bo[preview_buf].modifiable = true
			vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
			vim.bo[preview_buf].modifiable = false
		end)
	end)
end

function M.render(opts)
	local options = opts or {}
	local source_buf = options.buf or vim.api.nvim_get_current_buf()
	local anchor_win = options.anchor_win or vim.api.nvim_get_current_win()
	set_buf_var(source_buf, "plantuml_ascii_anchor_win", anchor_win)
	setup_autocmds(source_buf)
	render_buffer(source_buf, anchor_win)
end

return M
