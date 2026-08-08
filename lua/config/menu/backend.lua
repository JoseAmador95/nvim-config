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

function Adapter:_loaded(module)
	return self.loaded(module)
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
		if type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	state.bufids = {}
	state.bufs = {}
	state.config = nil
	state.nested_menu = ""
end

local function all_displayed(state)
	if type(state) ~= "table" or type(state.bufids) ~= "table" or #state.bufids == 0 then
		return false
	end
	for _, buf in ipairs(state.bufids) do
		if not displayed(buf) then
			return false
		end
	end
	return true
end

local function left_mouse_mapping()
	local mapping = vim.fn.maparg("<LeftMouse>", "n", false, true)
	if type(mapping) ~= "table" or type(mapping.callback) ~= "function" then
		return nil
	end
	return mapping.callback
end

function Adapter:_remember_mouse_mapping()
	self.mouse_mapping = left_mouse_mapping()
end

function Adapter:_clear_owned_mouse_mapping()
	local owned = self.mouse_mapping
	self.mouse_mapping = nil
	if owned and left_mouse_mapping() == owned then
		pcall(vim.keymap.del, "n", "<LeftMouse>")
	end
end

function Adapter:_recover_state(state)
	if not state or all_displayed(state) then
		return false
	end
	clear_stale_state(state)
	self:_clear_owned_mouse_mapping()
	return true
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
	local state = self:_loaded("menu.state")
	if not state then
		return false
	end
	if self:_recover_state(state) then
		return true
	end

	local utils = self:_optional("menu.utils")
	if not utils or type(utils.delete_old_menus) ~= "function" then
		return false
	end
	local ok, error_message = pcall(utils.delete_old_menus)
	self:_clear_owned_mouse_mapping()
	if not ok then
		error(error_message, 0)
	end
	return true
end

---Clear only already-loaded stale menu state without activating menu.nvim.
---@return boolean
function Adapter:recover_stale()
	return self:_recover_state(self:_loaded("menu.state"))
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
			self:_clear_owned_mouse_mapping()
		end
		state.config = nil
	end
	menu.open(M.render(sections), options)
	if options.mouse then
		self:_remember_mouse_mapping()
	end
	return true
end

---@param options? { require?: fun(module: string): any, loaded?: fun(module: string): any, notify?: fun(message: string, level?: integer) }
---@return table
function M.new(options)
	options = options or {}
	return setmetatable({
		require = options.require or require,
		loaded = options.loaded or function(module)
			return package.loaded[module]
		end,
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
