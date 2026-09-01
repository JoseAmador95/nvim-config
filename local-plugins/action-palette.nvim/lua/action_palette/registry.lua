local schema = require("action_palette.schema")
local default_target = require("action_palette.target")

local M = {}
local Registry = {}
Registry.__index = Registry

local function availability(value)
	if type(value) == "table" then
		if type(value.available) ~= "boolean" then
			return { available = false, error = "availability.available must be boolean" }
		end
		if value.reason ~= nil and type(value.reason) ~= "string" then
			return { available = false, error = "availability.reason must be a string" }
		end
		if value.error ~= nil and type(value.error) ~= "string" then
			return { available = false, error = "availability.error must be a string" }
		end
		return { available = value.available, reason = value.reason, error = value.error }
	end
	return { available = value == true }
end

local function supports_surface(candidate, surface)
	return not surface or candidate.surfaces == nil or candidate.surfaces[surface] == true
end

local function available(candidate, context)
	if not candidate.when then
		return { available = true }
	end
	local ok, result = pcall(candidate.when, context)
	if not ok then
		return { available = false, error = tostring(result) }
	end
	return availability(result)
end

local function combine(...)
	for index = 1, select("#", ...) do
		local result = select(index, ...)
		if not result.available then
			return result
		end
	end
	return { available = true }
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

function Registry:_emit(kind, extra)
	if not self.event then
		return
	end
	local event = vim.deepcopy(extra or {})
	event.kind = kind
	pcall(self.event, event)
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
				target = descriptor.target or self.config.target_default,
				unavailable = descriptor.unavailable or self.config.unavailable,
				available = function(context)
					local resolved = { available = true }
					if resolver.available then
						local ok, result = pcall(resolver.available, descriptor.id, context)
						resolved = ok and availability(result) or { available = false, error = tostring(result) }
					end
					return combine(available(section, context), available(descriptor, context), resolved)
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
	return vim.deepcopy(action and action.available(context or {}) or {
		available = false,
		error = "Unknown action: " .. tostring(id),
	})
end

function Registry:_refresh(invocation)
	local action = self.actions[invocation.id]
	local target, target_err = self.target.revalidate(invocation.target, action.target)
	if action.target ~= "none" and not target then
		return nil, target_err
	end
	local context = vim.deepcopy(invocation.context or {})
	context.target = target
	if self.refresh_context and action.target ~= "none" then
		local refreshed, refresh_err = self.refresh_context(context, target)
		if not refreshed then
			return nil, refresh_err or "Action context is no longer available"
		end
		context = refreshed
		context.target = target
	end
	local current = action and action.available(context) or { available = false, error = "Unknown action" }
	if not current.available then
		return nil, current.error or current.reason or ("Action is no longer available: " .. tostring(invocation.id))
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
			self:_emit("rejected", { id = id, error = prepare_err })
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
				self:_emit("error", { id = id, error = tostring(result) })
				return
			end
			self:_emit("executed", { id = id, surface = surface })
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
		if supports_surface(section, surface) and available(section, context).available then
			local items = {}
			for _, descriptor in ipairs(section.items) do
				local action = self.actions[descriptor.id]
				local current = action.available(context)
				if supports_surface(descriptor, surface) and (current.available or action.unavailable == "show") then
					local copy = descriptor_copy(descriptor)
					copy.availability = vim.deepcopy(current)
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

function Registry:effective_config()
	return vim.deepcopy(self.config)
end

function Registry:status()
	local count = 0
	for _ in pairs(self.actions) do
		count = count + 1
	end
	return { configured = true, actions = count, sections = #self.sections_value, config = self:effective_config() }
end

function Registry:teardown()
	self.actions = {}
	self.sections_value = {}
	return true
end

---@param opts? table
function M.new(opts)
	if opts == nil then
		opts = {}
	end
	if type(opts) ~= "table" or (next(opts) ~= nil and vim.islist(opts)) then
		error("action-palette setup options must be an object", 2)
	end
	local allowed = {
		target = true,
		confirm = true,
		notify = true,
		refresh_context = true,
		event = true,
		target_default = true,
		unavailable = true,
	}
	for key in pairs(opts) do
		assert(allowed[key], "action-palette setup contains an unknown option: " .. tostring(key))
	end
	for _, key in ipairs({ "confirm", "notify", "refresh_context", "event" }) do
		assert(opts[key] == nil or type(opts[key]) == "function", "action-palette " .. key .. " must be a function")
	end
	assert(
		opts.target == nil
			or (
				type(opts.target) == "table"
				and (next(opts.target) == nil or not vim.islist(opts.target))
				and type(opts.target.revalidate) == "function"
			),
		"action-palette target adapter must be an object with revalidate(value, mode)"
	)
	local target_default = opts.target_default
	if target_default == nil then
		target_default = "exact"
	end
	assert(
		vim.tbl_contains({ "exact", "buffer", "window", "none" }, target_default),
		"action-palette target_default is invalid"
	)
	local unavailable = opts.unavailable
	if unavailable == nil then
		unavailable = "hide"
	end
	assert(unavailable == "hide" or unavailable == "show", "action-palette unavailable must be hide or show")
	return setmetatable({
		actions = {},
		sections_value = {},
		target = opts.target or default_target,
		confirm = opts.confirm,
		notify = opts.notify or function() end,
		refresh_context = opts.refresh_context,
		event = opts.event,
		config = { target_default = target_default, unavailable = unavailable },
	}, Registry)
end

return M
