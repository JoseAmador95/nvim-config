local cache = require("diagram_view.cache")
local source = require("diagram_view.source")

local M = {}

local DEFAULT_CONFIG = {
	default_mode = "svg",
	stage_timeout_ms = 30000,
	max_stage_output_bytes = 16 * 1024 * 1024,
	cache = {
		max_age_seconds = 30 * 24 * 60 * 60,
		max_bytes = 256 * 1024 * 1024,
	},
}

local SECURITY_PROFILES = {
	SANDBOX = true,
	ALLOWLIST = true,
	INTERNET = true,
	LEGACY = true,
	UNSECURE = true,
}

local state = {
	configured = false,
	options = nil,
	renderers = {},
	presenters = {},
	sessions = {},
	next_session = 0,
}

local Session = {}
Session.__index = Session

local function copy(value)
	return vim.deepcopy(value)
end

local function nonempty(value, label)
	if type(value) ~= "string" or value == "" or value:find("\0", 1, true) then
		return nil, label .. " must be a non-empty string without NUL bytes"
	end
	return value
end

local function notify(message, level)
	if state.options and state.options.notify then
		pcall(state.options.notify, message, level)
	end
end

local function emit(kind, session, extra)
	if not state.options or not state.options.event then
		return
	end
	local event = copy(extra or {})
	event.kind = kind
	event.session = session.id
	event.state = session.state
	pcall(state.options.event, event)
end

local function default_spawn(argv, options, callback)
	return vim.system(argv, options, callback)
end

local function default_schedule(callback)
	vim.schedule(callback)
end

local function default_defer(callback, milliseconds)
	return vim.defer_fn(callback, milliseconds)
end

local function stop_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	local ok, closing = pcall(timer.is_closing, timer)
	if not ok or not closing then
		pcall(timer.close, timer)
	end
end

local function ordered_keys(value)
	local keys = vim.tbl_keys(value)
	table.sort(keys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	return keys
end

local function encode(value, active)
	local value_type = type(value)
	if value_type == "nil" then
		return "nil"
	end
	if value_type == "string" then
		return "s" .. #value .. ":" .. value
	end
	if value_type == "number" or value_type == "boolean" then
		return value_type:sub(1, 1) .. tostring(value)
	end
	if value_type ~= "table" then
		return nil, "cache identity contains unsupported " .. value_type
	end
	if active[value] then
		return nil, "cache identity contains a cycle"
	end
	active[value] = true
	local parts = { "{" }
	for _, key in ipairs(ordered_keys(value)) do
		local encoded_key, key_err = encode(key, active)
		if not encoded_key then
			active[value] = nil
			return nil, key_err
		end
		local encoded_value, value_err = encode(value[key], active)
		if not encoded_value then
			active[value] = nil
			return nil, value_err
		end
		parts[#parts + 1] = encoded_key
		parts[#parts + 1] = encoded_value
	end
	parts[#parts + 1] = "}"
	active[value] = nil
	return table.concat(parts, "\0")
end

local function renderer_signal(argv)
	local executable = argv[1] or ""
	local resolved = executable ~= "" and vim.fn.exepath(executable) or ""
	if resolved == "" then
		resolved = executable
	end
	local info = resolved ~= "" and vim.uv.fs_stat(resolved) or nil
	local mtime = info and info.mtime
	if type(mtime) == "table" then
		mtime = mtime.sec
	end
	return { path = resolved, size = info and info.size or "missing", mtime = mtime or "missing" }
end

local function plantuml_security(renderer, request)
	if not renderer.plantuml then
		return nil
	end
	local profile = "SANDBOX"
	local callback = state.options.plantuml_policy
	if callback then
		local ok, decision = pcall(callback, copy(request))
		if ok then
			local trusted = decision == "local-trusted"
			local requested = request.plantuml_profile
			if type(decision) == "table" then
				trusted = decision.policy == "local-trusted" or decision.trust == "local-trusted"
				requested = decision.profile or requested
			end
			if trusted and SECURITY_PROFILES[requested] then
				profile = requested
			end
		end
	end
	return profile
end

local function validate_plan(plan)
	if type(plan) ~= "table" then
		return nil, "renderer build must return a plan"
	end
	local extension, extension_err = nonempty(plan.extension, "renderer extension")
	if not extension then
		return nil, extension_err
	end
	if extension:find("[^%w%-]") then
		return nil, "renderer extension contains unsupported characters"
	end
	if type(plan.stages) ~= "table" or #plan.stages == 0 then
		return nil, "renderer plan must contain at least one stage"
	end
	local stages = {}
	for index, stage in ipairs(plan.stages) do
		if type(stage) ~= "table" or type(stage.argv) ~= "table" or #stage.argv == 0 then
			return nil, ("renderer stage %d needs argv"):format(index)
		end
		local argv = {}
		for argument_index, argument in ipairs(stage.argv) do
			local normalized, argument_err =
				nonempty(argument, ("renderer stage %d argv[%d]"):format(index, argument_index))
			if not normalized then
				return nil, argument_err
			end
			argv[argument_index] = normalized
		end
		if stage.env ~= nil and type(stage.env) ~= "table" then
			return nil, ("renderer stage %d environment must be a table"):format(index)
		end
		if stage.text ~= nil and type(stage.text) ~= "boolean" then
			return nil, ("renderer stage %d text must be a boolean"):format(index)
		end
		local env = {}
		for name, value in pairs(stage.env or {}) do
			if type(name) ~= "string" or name == "" or name:find("[=%z]") or type(value) ~= "string" then
				return nil, ("renderer stage %d has invalid environment"):format(index)
			end
			env[name] = value
		end
		stages[index] = { argv = argv, env = env, text = stage.text == true }
	end
	if plan.validate ~= nil and type(plan.validate) ~= "function" then
		return nil, "renderer validate must be a function"
	end
	return { extension = extension, stages = stages, validate = plan.validate }
end

local function valid_output(plan, output)
	if not plan.validate then
		return true
	end
	local ok, valid = pcall(plan.validate, output)
	return ok and valid == true
end

local function plan_key(renderer_name, request, plan, security_profile)
	local stages = {}
	for index, stage in ipairs(plan.stages) do
		stages[index] = {
			argv = stage.argv,
			env = stage.env,
			text = stage.text,
			signal = renderer_signal(stage.argv),
		}
	end
	local material, err = encode({
		version = "diagram-cache-v3",
		renderer = renderer_name,
		kind = request.kind,
		source = request.source,
		cache_key = request.cache_key,
		security_profile = security_profile,
		stages = stages,
	}, {})
	if not material then
		return nil, err
	end
	return vim.fn.sha256(material)
end

local function present_error(session, message)
	stop_timer(session.timeout)
	session.timeout = nil
	session.state = "error"
	session.error = message
	notify(message, vim.log.levels.ERROR)
	local presenter = session.presenter
	if presenter.error then
		pcall(presenter.error, session.presentation, message, session)
	end
	emit("error", session, { error = message })
	if session.request.on_done then
		pcall(session.request.on_done, nil, message, session)
	end
end

local function deliver(session, result)
	if session.closed then
		return
	end
	session.state = "presented"
	session.result = { path = result.path, extension = result.extension, cached = result.cached }
	if result.path then
		cache.retain(result.path)
		session.retained = result.path
	end
	local ok, err = pcall(session.presenter.deliver, session.presentation, result, session)
	if not ok then
		present_error(session, "diagram presenter failed: " .. tostring(err))
		return
	end
	emit("presented", session, { cached = result.cached, path = result.path })
	if session.request.on_done then
		pcall(session.request.on_done, copy(session.result), nil, session)
	end
end

function Session:_finish_stage(generation, result)
	if self.closed or generation ~= self.generation then
		return
	end
	self.active = nil
	stop_timer(self.timeout)
	self.timeout = nil
	if type(result) ~= "table" or result.code ~= 0 then
		local detail = type(result) == "table" and vim.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
			or ""
		present_error(self, detail ~= "" and detail or "diagram renderer failed")
		return
	end
	local output = result.stdout or ""
	local error_output = result.stderr or ""
	if #output + #error_output > state.options.config.max_stage_output_bytes then
		present_error(
			self,
			("diagram renderer output exceeds %d bytes"):format(state.options.config.max_stage_output_bytes)
		)
		return
	end
	self.stage_input = output
	self.stage_index = self.stage_index + 1
	if self.stage_index <= #self.plan.stages then
		self:_start_stage(generation)
		return
	end
	if not valid_output(self.plan, output) then
		present_error(self, "diagram renderer returned invalid output")
		return
	end
	local path, write_err = cache.write(self.cache_key, self.plan.extension, output)
	if not path then
		present_error(self, "could not cache diagram output: " .. tostring(write_err))
		return
	end
	deliver(self, { data = output, path = path, extension = self.plan.extension, cached = false })
	state.options.schedule(function()
		cache.prune()
	end)
end

function Session:_start_stage(generation)
	if self.closed or generation ~= self.generation then
		return
	end
	local stage = self.plan.stages[self.stage_index]
	local env = copy(stage.env)
	if self.security_profile then
		env.PLANTUML_SECURITY_PROFILE = self.security_profile
	end
	self.state = "running"
	emit("stage", self, { index = self.stage_index, argv = copy(stage.argv), security_profile = self.security_profile })
	local completed = false
	local function callback(result)
		if completed then
			return
		end
		completed = true
		state.options.schedule(function()
			self:_finish_stage(generation, result)
		end)
	end
	self.timeout = state.options.defer(function()
		if completed or self.closed or generation ~= self.generation then
			return
		end
		completed = true
		self.generation = self.generation + 1
		if self.active and self.active.kill then
			pcall(self.active.kill, self.active, 15)
		end
		self.active = nil
		present_error(
			self,
			("diagram renderer stage timed out after %d ms"):format(state.options.config.stage_timeout_ms)
		)
	end, state.options.config.stage_timeout_ms)
	local ok, handle = pcall(state.options.spawn, copy(stage.argv), {
		stdin = self.stage_input,
		text = stage.text,
		env = env,
		timeout = state.options.config.stage_timeout_ms,
	}, callback)
	if not ok then
		callback({ code = -1, stdout = "", stderr = tostring(handle) })
	elseif not completed then
		self.active = handle
	end
end

function Session:cancel(reason)
	if self.closed then
		return false
	end
	self.generation = self.generation + 1
	self.cancel_reason = reason or "cancelled"
	if self.active and self.active.kill then
		local killed, result = pcall(self.active.kill, self.active, 15)
		if not killed or result == false then
			stop_timer(self.timeout)
			self.timeout = nil
			self.state = "cancel-failed"
			self.error = "diagram process could not be stopped: " .. tostring(killed and result or result)
			emit("cancel-failed", self, { reason = self.cancel_reason, error = self.error })
			return nil, self.error
		end
	end
	stop_timer(self.timeout)
	self.timeout = nil
	if self.presenter.close then
		local closed, result = pcall(self.presenter.close, self.presentation, self)
		if not closed or result == false then
			self.state = "cancel-failed"
			self.error = "diagram presentation could not be closed: " .. tostring(closed and result or result)
			emit("cancel-failed", self, { reason = self.cancel_reason, error = self.error })
			return nil, self.error
		end
	end
	self.closed = true
	self.state = "cancelled"
	self.error = nil
	self.active = nil
	cache.release(self.retained)
	self.retained = nil
	state.sessions[self.id] = nil
	emit("cancelled", self, { reason = self.cancel_reason })
	return true
end

Session.close = Session.cancel

function Session:status()
	return {
		id = self.id,
		state = self.state,
		renderer = self.renderer_name,
		presenter = self.presenter_name,
		security_profile = self.security_profile,
		error = self.error,
		result = copy(self.result),
	}
end

function M.setup(opts)
	if type(opts) ~= "table" then
		return nil, "setup options must be a table"
	end
	local allowed = {
		cache_root = true,
		default_mode = true,
		stage_timeout_ms = true,
		max_stage_output_bytes = true,
		cache = true,
		notify = true,
		event = true,
		spawn = true,
		schedule = true,
		defer = true,
		plantuml_policy = true,
	}
	for key in pairs(opts) do
		if not allowed[key] then
			return nil, "setup contains an unknown option: " .. tostring(key)
		end
	end
	for _, callback in ipairs({ "notify", "event" }) do
		if opts[callback] ~= nil and type(opts[callback]) ~= "function" then
			return nil, ("setup.%s must be a function"):format(callback)
		end
	end
	if opts.spawn ~= nil and type(opts.spawn) ~= "function" then
		return nil, "setup.spawn must be a function"
	end
	if opts.schedule ~= nil and type(opts.schedule) ~= "function" then
		return nil, "setup.schedule must be a function"
	end
	if opts.defer ~= nil and type(opts.defer) ~= "function" then
		return nil, "setup.defer must be a function"
	end
	if opts.plantuml_policy ~= nil and type(opts.plantuml_policy) ~= "function" then
		return nil, "setup.plantuml_policy must be a function"
	end
	local cache_options = opts.cache
	if cache_options == nil then
		cache_options = {}
	end
	if type(cache_options) ~= "table" or (next(cache_options) ~= nil and vim.islist(cache_options)) then
		return nil, "setup.cache must be an object"
	end
	for key in pairs(cache_options) do
		if key ~= "max_age_seconds" and key ~= "max_bytes" then
			return nil, "setup.cache contains an unknown option: " .. tostring(key)
		end
	end
	local default_mode = opts.default_mode
	if default_mode == nil then
		default_mode = DEFAULT_CONFIG.default_mode
	end
	if default_mode ~= "svg" and default_mode ~= "ascii" then
		return nil, "setup.default_mode must be svg or ascii"
	end
	local function positive_integer(value, fallback, label)
		value = value == nil and fallback or value
		if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
			return nil, label .. " must be a positive integer"
		end
		return value
	end
	local stage_timeout_ms, timeout_err =
		positive_integer(opts.stage_timeout_ms, DEFAULT_CONFIG.stage_timeout_ms, "setup.stage_timeout_ms")
	if not stage_timeout_ms then
		return nil, timeout_err
	end
	local max_stage_output_bytes, output_err = positive_integer(
		opts.max_stage_output_bytes,
		DEFAULT_CONFIG.max_stage_output_bytes,
		"setup.max_stage_output_bytes"
	)
	if not max_stage_output_bytes then
		return nil, output_err
	end
	local max_age_seconds, age_err = positive_integer(
		cache_options.max_age_seconds,
		DEFAULT_CONFIG.cache.max_age_seconds,
		"setup.cache.max_age_seconds"
	)
	if not max_age_seconds then
		return nil, age_err
	end
	local max_bytes, bytes_err =
		positive_integer(cache_options.max_bytes, DEFAULT_CONFIG.cache.max_bytes, "setup.cache.max_bytes")
	if not max_bytes then
		return nil, bytes_err
	end
	local effective = {
		default_mode = default_mode,
		stage_timeout_ms = stage_timeout_ms,
		max_stage_output_bytes = max_stage_output_bytes,
		cache = { max_age_seconds = max_age_seconds, max_bytes = max_bytes },
	}
	if type(opts.cache_root) ~= "string" or opts.cache_root == "" or opts.cache_root:find("\0", 1, true) then
		return nil, "cache root must be a non-empty path"
	end
	local normalized_cache_root = vim.fs.normalize(opts.cache_root)
	if normalized_cache_root:sub(1, 1) ~= "/" then
		return nil, "cache root must be absolute"
	end
	local existing = {}
	for _, session in pairs(state.sessions) do
		existing[#existing + 1] = session
	end
	for _, session in ipairs(existing) do
		local cancelled, cancel_err = session:cancel("reconfigured")
		if not cancelled then
			return nil, "could not reconfigure diagram view: " .. tostring(cancel_err)
		end
	end
	local cache_ok, cache_err = cache.setup({
		root = normalized_cache_root,
		max_age_seconds = effective.cache.max_age_seconds,
		max_bytes = effective.cache.max_bytes,
	})
	if not cache_ok then
		return nil, cache_err
	end
	state.options = {
		notify = opts.notify,
		event = opts.event,
		spawn = opts.spawn or default_spawn,
		schedule = opts.schedule or default_schedule,
		defer = opts.defer or default_defer,
		plantuml_policy = opts.plantuml_policy,
		config = effective,
	}
	state.renderers = {}
	state.presenters = {}
	state.sessions = {}
	state.configured = true
	return true
end

function M.register_renderer(name, spec)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local renderer_name, name_err = nonempty(name, "renderer name")
	if not renderer_name then
		return nil, name_err
	end
	if type(spec) ~= "table" or type(spec.build) ~= "function" then
		return nil, "renderer requires a build function"
	end
	state.renderers[renderer_name] = { build = spec.build, plantuml = spec.plantuml == true }
	return true
end

function M.register_presenter(name, spec)
	if not state.configured then
		return nil, "setup must be called first"
	end
	local presenter_name, name_err = nonempty(name, "presenter name")
	if not presenter_name then
		return nil, name_err
	end
	if type(spec) ~= "table" or type(spec.open) ~= "function" or type(spec.deliver) ~= "function" then
		return nil, "presenter requires open and deliver functions"
	end
	if spec.close ~= nil and type(spec.close) ~= "function" then
		return nil, "presenter close must be a function"
	end
	if spec.error ~= nil and type(spec.error) ~= "function" then
		return nil, "presenter error must be a function"
	end
	state.presenters[presenter_name] = spec
	return true
end

function M.open(request)
	if not state.configured then
		return nil, "setup must be called first"
	end
	if type(request) ~= "table" then
		return nil, "render request must be a table"
	end
	local renderer = state.renderers[request.renderer]
	if not renderer then
		return nil, "unknown renderer: " .. tostring(request.renderer)
	end
	local presenter = state.presenters[request.presenter]
	if not presenter then
		return nil, "unknown presenter: " .. tostring(request.presenter)
	end
	local kind, kind_err = nonempty(request.kind, "request.kind")
	if not kind then
		return nil, kind_err
	end
	if type(request.source) ~= "string" then
		return nil, "request.source must be a string"
	end
	if request.on_done ~= nil and type(request.on_done) ~= "function" then
		return nil, "request.on_done must be a function"
	end
	local normalized_request = {
		kind = kind,
		source = request.source,
		metadata = copy(request.metadata or {}),
		cache_key = copy(request.cache_key),
		plantuml_profile = request.plantuml_profile,
		on_done = request.on_done,
	}
	local security_profile = plantuml_security(renderer, normalized_request)
	local ok, built = pcall(renderer.build, copy(normalized_request), { plantuml_profile = security_profile })
	if not ok then
		return nil, "renderer build failed: " .. tostring(built)
	end
	local plan, plan_err = validate_plan(built)
	if not plan then
		return nil, plan_err
	end
	local cache_key, key_err = plan_key(request.renderer, normalized_request, plan, security_profile)
	if not cache_key then
		return nil, key_err
	end

	state.next_session = state.next_session + 1
	local session = setmetatable({
		id = state.next_session,
		state = "starting",
		generation = 1,
		closed = false,
		renderer_name = request.renderer,
		presenter_name = request.presenter,
		renderer = renderer,
		presenter = presenter,
		request = normalized_request,
		plan = plan,
		cache_key = cache_key,
		security_profile = security_profile,
		stage_index = 1,
		stage_input = normalized_request.source,
	}, Session)
	state.sessions[session.id] = session
	local opened, presentation = pcall(presenter.open, copy(normalized_request), session)
	if not opened then
		state.sessions[session.id] = nil
		return nil, "diagram presenter failed to open: " .. tostring(presentation)
	end
	session.presentation = presentation
	emit("opened", session)

	local cached, read_err, path, cache_identity = cache.read(cache_key, plan.extension, function(data)
		return valid_output(plan, data)
	end)
	if cached then
		deliver(session, { data = cached, path = path, extension = plan.extension, cached = true })
		return session
	end
	if read_err and path then
		local removed, remove_err = cache.remove(path, cache_identity)
		if not removed then
			notify("invalid diagram cache entry was preserved: " .. tostring(remove_err), vim.log.levels.WARN)
		end
	elseif read_err then
		present_error(session, "could not read diagram cache: " .. tostring(read_err))
		return session
	end
	session:_start_stage(session.generation)
	return session
end

function M.cancel(session_or_id, reason)
	local session = type(session_or_id) == "table" and session_or_id or state.sessions[session_or_id]
	if not session or getmetatable(session) ~= Session then
		return false
	end
	return session:cancel(reason)
end

function M.extract(opts)
	return source.extract(opts)
end

function M.find_fences(lines, accepted)
	return source.find_fences(lines, accepted)
end

function M.status()
	local renderers = vim.tbl_keys(state.renderers)
	local presenters = vim.tbl_keys(state.presenters)
	table.sort(renderers)
	table.sort(presenters)
	local sessions = {}
	for _, session in pairs(state.sessions) do
		sessions[#sessions + 1] = session:status()
	end
	table.sort(sessions, function(left, right)
		return left.id < right.id
	end)
	return vim.deepcopy({
		configured = state.configured,
		config = M.effective_config(),
		renderers = renderers,
		presenters = presenters,
		sessions = sessions,
	})
end

function M.effective_config()
	return state.options and copy(state.options.config) or copy(DEFAULT_CONFIG)
end

function M.teardown()
	local sessions = {}
	for _, session in pairs(state.sessions) do
		sessions[#sessions + 1] = session
	end
	for _, session in ipairs(sessions) do
		local cancelled, cancel_err = session:cancel("teardown")
		if not cancelled then
			return nil, cancel_err
		end
	end
	state.renderers = {}
	state.presenters = {}
	state.sessions = {}
	state.options = nil
	state.configured = false
	return true
end

return M
