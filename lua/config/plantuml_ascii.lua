local M = {}

local async_runner = require("config.async_runner")

local states = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "PlantumlAscii" })
end

local function get_buf_var(buf, name)
	local ok, value = pcall(vim.api.nvim_buf_get_var, buf, name)
	return ok and value or nil
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
	vim.bo[buf].readonly = true
	vim.bo[buf].filetype = "plantuml_ascii"
	set_buf_var(source_buf, "plantuml_ascii_buf", buf)
	return buf
end

local function ensure_preview_window(source_buf, anchor_win)
	local win = get_buf_var(source_buf, "plantuml_ascii_win")
	if win and vim.api.nvim_win_is_valid(win) then
		return win
	end
	local target = anchor_win
	if not target or not vim.api.nvim_win_is_valid(target) then
		target = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(target)
	vim.cmd("vsplit")
	vim.cmd("wincmd L")
	win = vim.api.nvim_get_current_win()
	vim.wo[win].wrap = false
	set_buf_var(source_buf, "plantuml_ascii_win", win)
	return win
end

local function render_spec(state)
	if not vim.api.nvim_buf_is_valid(state.source_buf) then
		return nil
	end
	if vim.fn.executable("plantuml") ~= 1 then
		notify("plantuml not found in PATH", vim.log.levels.ERROR)
		return nil
	end
	local input = table.concat(vim.api.nvim_buf_get_lines(state.source_buf, 0, -1, false), "\n")
	if input == "" then
		notify("Buffer is empty", vim.log.levels.WARN)
		return nil
	end

	return {
		command = { "plantuml", "-ttxt", "-pipe" },
		options = { text = true, stdin = input },
		on_result = function(result)
			if not vim.api.nvim_buf_is_valid(state.source_buf) then
				return
			end
			if result.code ~= 0 then
				local msg = vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
				notify(msg == "" and "plantuml failed" or msg, vim.log.levels.ERROR)
				return
			end

			local preview_buf = ensure_preview_buffer(state.source_buf)
			local preview_win = ensure_preview_window(state.source_buf, state.anchor_win)
			vim.api.nvim_win_set_buf(preview_win, preview_buf)
			vim.wo[preview_win].wrap = false
			vim.bo[preview_buf].readonly = false
			vim.bo[preview_buf].modifiable = true
			vim.api.nvim_buf_set_lines(
				preview_buf,
				0,
				-1,
				false,
				vim.split(result.stdout or "", "\n", { plain = true })
			)
			vim.bo[preview_buf].modifiable = false
			vim.bo[preview_buf].readonly = true
			vim.bo[preview_buf].modified = false
		end,
	}
end

local function schedule_render(state)
	state.runner:debounce(1000, function()
		if states[state.source_buf] ~= state then
			return nil
		end
		return render_spec(state)
	end)
end

local function ensure_state(source_buf)
	local state = states[source_buf]
	if state then
		return state
	end
	state = { source_buf = source_buf, runner = async_runner.new() }
	states[source_buf] = state

	local group = vim.api.nvim_create_augroup("PlantumlAscii_" .. source_buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = source_buf,
		callback = function()
			if states[source_buf] == state then
				schedule_render(state)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = source_buf,
		once = true,
		callback = function()
			if states[source_buf] == state then
				states[source_buf] = nil
				state.runner:close()
			end
		end,
	})
	set_buf_var(source_buf, "plantuml_ascii_group", group)
	return state
end

function M.render(opts)
	local options = opts or {}
	local source_buf = options.buf or vim.api.nvim_get_current_buf()
	local state = ensure_state(source_buf)
	state.anchor_win = options.anchor_win or vim.api.nvim_get_current_win()
	set_buf_var(source_buf, "plantuml_ascii_anchor_win", state.anchor_win)
	local spec = render_spec(state)
	if spec then
		state.runner:request(spec)
	end
end

return M
