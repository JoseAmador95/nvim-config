local schema = require("action_palette.schema")
local default_target = require("action_palette.target")

local M = {}
local Registry = {}
Registry.__index = Registry

local function supports_surface(candidate, surface)
	return not surface or candidate.surfaces == nil or candidate.surfaces[surface] == true
end

local function available(candidate, context)
	if not candidate.when then
		return true
	end
	local ok, result = pcall(candidate.when, context)
	return ok and result == true
end

local function descriptor_copy(descriptor)
	local copy = vim.deepcopy(descriptor)
	copy.when = nil
	copy.surfaces = nil
	return copy
end

function Registry:_notify(message, level)
	self.notify(tostring(message), level or vim.log.levels.WARN)
end

---@param sections table[]
---@param resolver { supports: fun(id: string): boolean, execute: fun(id: string, invocation: table): any, confirmation?: fun(id: string): string?, available?: fun(id: string, context: table): boolean }
function Registry:register_catalog(sections, resolver)
	assert(type(resolver) == "table", "action resolver must be a table")
	assert(type(resolver.supports) == "function", "action resolver must provide supports(id)")
	assert(type(resolver.execute) == "function", "action resolver must provide execute(id, invocation)")
	local validated, validation_err = schema.catalog(sections)
	assert(validated, validation_err)

	local actions = {}
	for _, section in ipairs(validated) do
		for _, descriptor in ipairs(section.items) do
			assert(resolver.supports(descriptor.id), "catalog descriptor has no action: " .. descriptor.id)
			actions[descriptor.id] = {
				execute = function(invocation)
					return resolver.execute(descriptor.id, invocation)
				end,
				confirmation = resolver.confirmation and resolver.confirmation(descriptor.id) or nil,
				available = function(context)
					return available(section, context)
						and available(descriptor, context)
						and (not resolver.available or resolver.available(descriptor.id, context) ~= false)
				end,
			}
		end
	end
	self.sections_value = validated
	self.actions = actions
end

function Registry:supports(id)
	return type(id) == "string" and self.actions[id] ~= nil
end

function Registry:is_available(id, context)
	local action = self.actions[id]
	return action ~= nil and action.available(context or {})
end

function Registry:_refresh(invocation)
	local target, target_err = self.target.revalidate(invocation.target)
	if not target then
		return nil, target_err
	end
	local context = vim.deepcopy(invocation.context or {})
	context.target = target
	if self.refresh_context then
		local refreshed, refresh_err = self.refresh_context(context, target)
		if not refreshed then
			return nil, refresh_err or "Action context is no longer available"
		end
		context = refreshed
		context.target = target
	end
	local action = self.actions[invocation.id]
	if not action or not action.available(context) then
		return nil, "Action is no longer available: " .. tostring(invocation.id)
	end
	return {
		id = invocation.id,
		target = target,
		context = vim.deepcopy(context),
		surface = invocation.surface,
	}
end

---@param id string
---@param context table
---@param surface? "palette"|"context"
---@return function
function Registry:bind(id, context, surface)
	local action = self.actions[id]
	assert(action, "unknown action: " .. tostring(id))
	local invocation = {
		id = id,
		target = vim.deepcopy(context and context.target),
		context = vim.deepcopy(context or {}),
		surface = surface,
	}
	local state = "ready"

	return function()
		if state ~= "ready" then
			return false, "Action invocation was already consumed"
		end
		state = "pending"
		local prepared, prepare_err = self:_refresh(invocation)
		if not prepared then
			state = "done"
			self:_notify(prepare_err)
			return false, prepare_err
		end

		local function execute_once()
			if state ~= "pending" then
				return
			end
			state = "done"
			local refreshed, refresh_err = self:_refresh(invocation)
			if not refreshed then
				self:_notify(refresh_err)
				return
			end
			local ok, result = pcall(action.execute, refreshed)
			if not ok then
				self:_notify(result, vim.log.levels.ERROR)
				return
			end
			return result
		end

		if action.confirmation then
			if not self.confirm then
				local confirmation_err = "Confirmation adapter is unavailable"
				state = "done"
				self:_notify(confirmation_err)
				return false, confirmation_err
			end
			self.confirm(action.confirmation, function(accepted)
				if state ~= "pending" then
					return
				end
				if accepted then
					execute_once()
				else
					state = "done"
				end
			end)
			return true
		end
		execute_once()
		return true
	end
end

---@param context table
---@param surface? "palette"|"context"
---@return table[]
function Registry:sections(context, surface)
	local visible = {}
	for _, section in ipairs(self.sections_value) do
		if supports_surface(section, surface) and available(section, context) then
			local items = {}
			for _, descriptor in ipairs(section.items) do
				local action = self.actions[descriptor.id]
				if
					supports_surface(descriptor, surface)
					and available(descriptor, context)
					and action.available(context)
				then
					local copy = descriptor_copy(descriptor)
					copy.run = self:bind(descriptor.id, context, surface)
					items[#items + 1] = copy
				end
			end
			if #items > 0 then
				visible[#visible + 1] = {
					id = section.id,
					label = section.label,
					palette_label = section.palette_label,
					items = items,
				}
			end
		end
	end
	return visible
end

function Registry:definitions()
	return vim.deepcopy(self.sections_value)
end

---@param opts? table
function M.new(opts)
	opts = opts or {}
	return setmetatable({
		actions = {},
		sections_value = {},
		target = opts.target or default_target,
		confirm = opts.confirm,
		notify = opts.notify or function() end,
		refresh_context = opts.refresh_context,
	}, Registry)
end

return M
