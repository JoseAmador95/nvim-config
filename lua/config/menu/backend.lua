local M = {}

local Adapter = {}
Adapter.__index = Adapter

local function default_notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Menu" })
end

---Translate stable descriptors into menu.nvim's presentation shape.
---@param sections table[]
---@return table[]
function M.render(sections)
	local rendered = {}
	for _, section in ipairs(sections) do
		local items = {}
		for _, descriptor in ipairs(section.items) do
			local item = {
				name = descriptor.label,
				cmd = descriptor.run,
			}
			if descriptor.hint then
				item.rtxt = descriptor.hint
			end
			table.insert(items, item)
		end
		table.insert(rendered, { name = section.label, items = items })
	end
	return rendered
end

function Adapter:_optional(module)
	local ok, value = pcall(self.require, module)
	if ok then
		return value
	end
	return nil
end

function Adapter:_menu()
	local menu = self:_optional("menu")
	if menu then
		return menu
	end

	local lazy = self:_optional("lazy")
	if lazy and type(lazy.load) == "function" then
		lazy.load({ plugins = { "menu" } })
	end

	menu = self:_optional("menu")
	if not menu then
		self.notify("menu.nvim not available", vim.log.levels.ERROR)
	end
	return menu
end

local function displayed(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

local function clear_stale_state(state)
	if type(state) ~= "table" or type(state.bufids) ~= "table" then
		return
	end
	for _, buf in ipairs(state.bufids) do
		if type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and not displayed(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	state.bufids = {}
	state.bufs = {}
	state.nested_menu = ""
end

---Whether a menu.nvim buffer is currently displayed.
---@return boolean
function Adapter:is_open()
	local state = self:_optional("menu.state")
	if state == nil or type(state.bufids) ~= "table" then
		return false
	end
	for _, buf in ipairs(state.bufids) do
		if displayed(buf) then
			return true
		end
	end
	return false
end

---Close all menu.nvim buffers through its private compatibility seam.
---@return boolean
function Adapter:close()
	local utils = self:_optional("menu.utils")
	if not utils or type(utils.delete_old_menus) ~= "function" then
		return false
	end
	utils.delete_old_menus()
	return true
end

---Open rendered descriptors after resetting menu.nvim's cached config.
---@param sections table[]
---@param options table
---@return boolean
function Adapter:show(sections, options)
	local menu = self:_menu()
	if not menu or type(menu.open) ~= "function" then
		return false
	end

	local state = self:_optional("menu.state")
	if state then
		if not self:is_open() then
			clear_stale_state(state)
		end
		state.config = nil
	end
	menu.open(M.render(sections), options)
	return true
end

---@param options? { require?: fun(module: string): any, notify?: fun(message: string, level?: integer) }
---@return table
function M.new(options)
	options = options or {}
	return setmetatable({
		require = options.require or require,
		notify = options.notify or default_notify,
	}, Adapter)
end

local default_adapter

function M.default()
	if not default_adapter then
		default_adapter = M.new()
	end
	return default_adapter
end

return M
