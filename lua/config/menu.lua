local backend = require("config.menu.backend").default()
local context = require("config.menu.context")
local deferred = require("config.deferred")

local M = {}

local function current_context()
	return context.capture()
end

local function descriptors(menu_context, surface)
	return deferred.load("config.action_palette").sections(menu_context, surface)
end

local function palette_items(sections)
	local items = {}
	for _, section in ipairs(sections) do
		for _, descriptor in ipairs(section.items) do
			local display = (section.palette_label or section.label)
				.. ": "
				.. (descriptor.palette_label or descriptor.label)
			local search = { display }
			if descriptor.hint then
				search[#search + 1] = descriptor.hint
			end
			if descriptor.keywords then
				vim.list_extend(search, descriptor.keywords)
			end
			items[#items + 1] = {
				id = descriptor.id,
				text = table.concat(search, " "),
				display = display,
				hint = descriptor.hint,
				section = section.label,
				label = descriptor.label,
				run = descriptor.run,
			}
		end
	end
	return items
end

---The menu belongs only to full terminal Neovim, never VS Code or nvimpager.
---@return boolean
function M.enabled()
	local ok, pager = pcall(require, "config.pager")
	return not vim.g.vscode and not (ok and pager.active)
end

function M.open()
	if not M.enabled() then
		return
	end
	if backend:is_open() then
		backend:close()
		return
	end
	M.ensure_open()
end

---Open the shared catalog as a searchable Snacks action palette.
function M.open_palette()
	if not M.enabled() then
		return
	end

	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		vim.notify("Snacks picker not available", vim.log.levels.ERROR, { title = "Menu" })
		return
	end

	local confirmed = false
	snacks.picker.pick({
		source = "menu_actions",
		title = "Actions",
		items = palette_items(descriptors(current_context(), "palette")),
		format = function(item)
			local formatted = { { item.display } }
			if item.hint then
				formatted[#formatted + 1] = { "  " .. item.hint, "Comment" }
			end
			return formatted
		end,
		preview = false,
		layout = { preset = "select" },
		confirm = function(picker, item)
			if confirmed then
				return
			end
			confirmed = true
			picker:close()
			if item and type(item.run) == "function" then
				vim.schedule(item.run)
			end
		end,
	})
end

function M.ensure_open()
	if not M.enabled() or backend:is_open() then
		return
	end
	backend:show(descriptors(current_context(), "context"), { border = true })
end

---Dismiss any displayed menu or recover stale menu.nvim state.
---@return boolean
function M.dismiss()
	if not M.enabled() then
		return false
	end
	return backend:close()
end

---Recover only stale state from an already-loaded menu.nvim instance.
---@return boolean
function M.recover_stale()
	if not M.enabled() then
		return false
	end
	return backend:recover_stale()
end

---@param options? { move_cursor?: boolean }
function M.open_context(options)
	if not M.enabled() then
		return
	end
	if backend:is_open() then
		backend:close()
		return
	end

	options = options or {}
	local menu_context = current_context()
	if not menu_context.visual and options.move_cursor ~= false then
		pcall(vim.cmd, "normal! \\<RightMouse>")
		menu_context = current_context()
	end
	backend:show(descriptors(menu_context, "context"), { mouse = true, border = true })
end

function M.setup()
	if not M.enabled() then
		return
	end

	vim.keymap.set({ "n", "v" }, "<RightMouse>", M.open_context, { desc = "Open menu" })

	local group = vim.api.nvim_create_augroup("NvimConfigMenu", { clear = true })
	vim.api.nvim_create_autocmd("TabClosed", {
		group = group,
		desc = "Recover menu state after an external tab close",
		callback = function()
			M.recover_stale()
		end,
	})
end

return M
