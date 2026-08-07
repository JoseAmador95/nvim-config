-- Recover file lifecycle events that Neovim 0.12 emits for argv buffers before
-- lazy.nvim has installed its handlers. Existing autocmd groups are never
-- replayed: only groups created by plugins loaded during recovery are invoked.
local M = {}

local lifecycle_events = { "BufReadPre", "BufReadPost", "FileType" }
local ignored_groups = {
	-- Calling Lazy's FileType autocmd would replay every FileType group because
	-- lazy.core.handler.event intentionally does not build an exclusion list for
	-- that event. FileType plugins are loaded explicitly below instead.
	lazy_handler_event = true,
	-- vim.lsp.enable() already evaluates only this group for existing buffers.
	["nvim.lsp.enable"] = true,
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.ERROR, { title = "nvim startup" })
end

local function event_groups(event)
	local groups = {}
	for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = event })) do
		if autocmd.group_name then
			groups[autocmd.group_name] = true
		end
	end
	return groups
end

local function snapshot_events()
	local snapshot = {}
	for _, event in ipairs(lifecycle_events) do
		snapshot[event] = event_groups(event)
	end
	return snapshot
end

local function append_new_groups(target, before)
	for _, event in ipairs(lifecycle_events) do
		for group in pairs(event_groups(event)) do
			if not before[event][group] and not ignored_groups[group] then
				target[event][group] = true
			end
		end
	end
end

local function trigger_groups(groups, event, buf)
	for group in pairs(groups[event]) do
		local ok, err = pcall(vim.api.nvim_exec_autocmds, event, {
			buffer = buf,
			group = group,
			modeline = false,
		})
		if not ok then
			notify(string.format("Could not recover %s group %s: %s", event, group, err), vim.log.levels.WARN)
		end
	end
end

local function source_file(path)
	vim.cmd.source(vim.fn.fnameescape(path))
end

local function source_matching_ftplugins(plugin, ft, seen)
	if not plugin._.loaded or not plugin.dir or plugin.dir == "" then
		return
	end

	for name in ft:gmatch("[^.]+") do
		for _, prefix in ipairs({ plugin.dir .. "/ftplugin", plugin.dir .. "/after/ftplugin" }) do
			for _, extension in ipairs({ "vim", "lua" }) do
				local exact = string.format("%s/%s.%s", prefix, name, extension)
				if vim.fn.filereadable(exact) == 1 and not seen[exact] then
					source_file(exact)
					seen[exact] = true
				end

				for _, pattern in ipairs({
					string.format("%s/%s_*.%s", prefix, name, extension),
					string.format("%s/%s/*.%s", prefix, name, extension),
				}) do
					for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
						if not seen[path] then
							source_file(path)
							seen[path] = true
						end
					end
				end
			end
		end
	end
end

local function source_loaded_ftplugins(internals, buf, ft)
	if ft == "" then
		return
	end

	vim.api.nvim_buf_call(buf, function()
		local seen = vim.b[buf].lazy_argv_ftplugins or {}
		for _, plugin in pairs(internals.config.plugins) do
			source_matching_ftplugins(plugin, ft, seen)
		end
		vim.b[buf].lazy_argv_ftplugins = seen
	end)
end

local function pending_filetype_plugins(internals, ft)
	local pending = {}
	local handlers = internals.handler.handlers

	for _, name in pairs((handlers.event.active or {}).FileType or {}) do
		pending[name] = true
	end
	for _, name in pairs((handlers.ft.active or {})[ft] or {}) do
		pending[name] = true
	end

	return vim.tbl_keys(pending)
end

local function load_filetype_plugins(internals, groups, buf, ft)
	local plugins = pending_filetype_plugins(internals, ft)
	if #plugins == 0 then
		source_loaded_ftplugins(internals, buf, ft)
		return
	end

	local before = snapshot_events()
	local state = internals.event.get_state("FileType", buf, nil)
	for _, item in ipairs(state) do
		-- Lazy leaves this nil for FileType and consequently replays every group.
		-- Supplying the snapshot makes Event.trigger() select only new groups.
		if item.event == "FileType" then
			item.exclude = vim.tbl_keys(before.FileType)
		end
	end

	internals.loader.load(plugins, { event = "FileType", ft = ft })
	source_loaded_ftplugins(internals, buf, ft)
	for _, item in ipairs(state) do
		internals.event.trigger(item)
	end
	append_new_groups(groups, before)
end

local function trigger_lazy_event(internals, groups, event, buf)
	local before = snapshot_events()
	vim.api.nvim_exec_autocmds(event, {
		buffer = buf,
		group = internals.event.group,
		modeline = false,
	})
	append_new_groups(groups, before)
end

local function recover_buffer(internals, groups, pager, buf)
	if vim.b[buf].lazy_argv_recovered then
		return
	end

	if pager.active then
		pager.apply_stdin_filetype(buf)
	end

	local name = vim.api.nvim_buf_get_name(buf)
	local existing_file = name ~= "" and vim.fn.filereadable(name) == 1

	if existing_file then
		trigger_groups(groups, "BufReadPre", buf)
		trigger_lazy_event(internals, groups, "BufReadPre", buf)
		trigger_groups(groups, "BufReadPost", buf)
		trigger_lazy_event(internals, groups, "BufReadPost", buf)
	elseif name ~= "" then
		local before = snapshot_events()
		vim.api.nvim_exec_autocmds("BufNewFile", {
			buffer = buf,
			group = internals.event.group,
			modeline = false,
		})
		append_new_groups(groups, before)
	end

	local ft = vim.bo[buf].filetype
	if ft ~= "" then
		trigger_groups(groups, "FileType", buf)
		load_filetype_plugins(internals, groups, buf, ft)
	end

	vim.b[buf].lazy_argv_recovered = true
end

local function load_internals()
	local ok_handler, handler = pcall(require, "lazy.core.handler")
	local ok_event, event = pcall(require, "lazy.core.handler.event")
	local ok_loader, loader = pcall(require, "lazy.core.loader")
	local ok_config, config = pcall(require, "lazy.core.config")
	if not (ok_handler and ok_event and ok_loader and ok_config) then
		return nil
	end
	if not handler.handlers or not handler.handlers.event or not handler.handlers.ft or not event.group then
		return nil
	end
	return { handler = handler, event = event, loader = loader, config = config }
end

---Recover already-loaded argv/session buffers once VimEnter has completed.
---@param pager table
function M.setup(pager)
	vim.api.nvim_create_autocmd("VimEnter", {
		group = vim.api.nvim_create_augroup("LazyArgvRecovery", { clear = true }),
		callback = function()
			local internals = load_internals()
			if not internals then
				vim.notify_once(
					"lazy.nvim internals changed; argv recovery was skipped. Update config.lazy_argv for this Lazy version.",
					vim.log.levels.WARN,
					{ title = "nvim startup" }
				)
				return
			end

			local groups = { BufReadPre = {}, BufReadPost = {}, FileType = {} }

			local current = vim.api.nvim_get_current_buf()
			local buffers = { current }
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if buf ~= current then
					buffers[#buffers + 1] = buf
				end
			end

			for _, buf in ipairs(buffers) do
				if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
					local name = vim.api.nvim_buf_get_name(buf)
					local real_file = name ~= "" and vim.bo[buf].buftype == ""
					if real_file or pager.active then
						local ok, err = pcall(recover_buffer, internals, groups, pager, buf)
						if not ok then
							notify(string.format("Could not recover argv buffer %d: %s", buf, err))
						end
					end
				end
			end
		end,
	})
end

return M
