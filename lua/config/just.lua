-- Host adapter for just-workbench.nvim. Commands, prompts, picker presentation,
-- terminal UI, repository resolution, and quickfix integration remain here.
local M = {}

local workbench = require("just_workbench")
local last_identity

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Just" })
end

local function find_justfile(root)
	local preferred = { justfile = 1, Justfile = 2, [".justfile"] = 3 }
	local found = {}
	local handle = vim.uv.fs_scandir(root)
	if handle then
		while true do
			local name, kind = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if kind == "file" and (name:lower() == "justfile" or name:lower() == ".justfile") then
				found[#found + 1] = name
			end
		end
	end
	table.sort(found, function(left, right)
		local left_rank = preferred[left] or 4
		local right_rank = preferred[right] or 4
		return left_rank == right_rank and left < right or left_rank < right_rank
	end)
	return found[1] and vim.fs.joinpath(root, found[1]) or nil
end

local function context()
	if vim.fn.executable("just") ~= 1 then
		return nil, "host just was not found in PATH (it is never installed automatically)"
	end
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		return nil, root_err
	end
	local justfile = find_justfile(root)
	if not justfile then
		return nil, "no justfile exists at the repository root"
	end
	return { runtime = "host", task_root = root, justfile = justfile, just_bin = "just" }
end

local function terminal_adapter()
	return {
		status = function(key)
			return require("config.terminal").status(key)
		end,
		open = function(spec)
			return require("config.terminal").open(spec)
		end,
		focus = function(spec)
			return require("config.terminal").focus(spec)
		end,
		replace = function(spec)
			return require("config.terminal").restart(spec)
		end,
		lines = function(key)
			return require("config.terminal").lines(key)
		end,
	}
end

local function configure(overrides)
	overrides = overrides or {}
	workbench.setup({
		system = overrides.system or vim.system,
		trust = overrides.trust or function(path, contents)
			local approved = vim.secure.read(path)
			return approved == contents, "source was not trusted: " .. path
		end,
		hash = overrides.hash or vim.fn.sha256,
		home = overrides.home or vim.env.HOME,
		now = overrides.now,
		schedule = overrides.schedule or vim.schedule,
		terminal = overrides.terminal or terminal_adapter(),
	})
end

local function execute(catalog, action, values, decision)
	local result, err = workbench.run(catalog, action.name, values, decision and { decision = decision } or nil)
	if result then
		if result.outcome == "started" or result.outcome == "replaced" then
			last_identity = { runtime = catalog.runtime, task_root = catalog.task_root }
		end
		return
	end
	if type(err) ~= "table" or err.kind ~= "conflict" then
		notify("Could not run recipe: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	local choices = {
		{ value = "focus", label = "Focus existing run" },
		{ value = "replace", label = "Replace existing run" },
		{ value = "cancel", label = "Cancel" },
	}
	vim.ui.select(choices, {
		prompt = ("Just is already active for %s"):format(catalog.task_root),
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		local selected = choice and choice.value or "cancel"
		execute(catalog, action, values, selected)
	end)
end

local function prompt_parameters(catalog, action, index, values)
	index = index or 1
	values = values or {}
	local parameter = action.parameters[index]
	if not parameter then
		execute(catalog, action, values)
		return
	end
	local variadic = parameter.kind == "plus" or parameter.kind == "star" or parameter.kind == "variadic"
	local default = type(parameter.default) == "string" and parameter.default or ""
	vim.ui.input({
		prompt = ("just %s: %s%s: "):format(action.name, parameter.name, variadic and " (space-separated)" or ""),
		default = default,
	}, function(value)
		if value == nil then
			return
		end
		local optional = parameter.default ~= nil or parameter.kind == "star"
		if value == "" and not optional then
			notify("A value is required for " .. parameter.name, vim.log.levels.WARN)
			return
		end
		if value == "" then
			prompt_parameters(catalog, action, index + 1, values)
		elseif variadic then
			vim.list_extend(values, vim.split(value, "%s+", { trimempty = true }))
			prompt_parameters(catalog, action, index + 1, values)
		else
			values[#values + 1] = value
			prompt_parameters(catalog, action, index + 1, values)
		end
	end)
end

local function choose(catalog, requested)
	if requested and requested ~= "" then
		for _, action in ipairs(catalog.actions) do
			if action.name == requested then
				prompt_parameters(catalog, action)
				return
			end
		end
		notify("Unknown recipe or alias: " .. requested, vim.log.levels.ERROR)
		return
	end
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		notify("Snacks picker is unavailable", vim.log.levels.ERROR)
		return
	end
	snacks.picker.pick({
		source = "just_recipes",
		title = "Just recipes",
		items = catalog.actions,
		format = "text",
		preview = false,
		layout = { preset = "select" },
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.schedule(function()
					prompt_parameters(catalog, item)
				end)
			end
		end,
	})
end

function M.run(requested, overrides)
	local ctx, ctx_err = context()
	if not ctx then
		notify(ctx_err, vim.log.levels.ERROR)
		return
	end
	configure(overrides)
	local handle, catalog_err = workbench.catalog(ctx, function(catalog, err)
		vim.schedule(function()
			if not catalog then
				notify("Could not list recipes: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			choose(catalog, requested)
		end)
	end)
	if not handle then
		notify("Could not list recipes: " .. tostring(catalog_err), vim.log.levels.ERROR)
	end
end

local function strip_ansi(line)
	return line:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

function M.parse_locations(root, lines)
	local items = {}
	local seen = {}
	for _, raw in ipairs(lines or {}) do
		if #items >= 2000 then
			break
		end
		local line = strip_ansi(raw)
		if #line <= 8192 and not line:find("[%z\1-\8\11\12\14-\31]") then
			local file, lnum, col, message = line:match("^([^:]+):(%d+):(%d+):%s*(.+)$")
			if not file then
				file, lnum, message = line:match("^([^:]+):(%d+):%s*(.+)$")
			end
			if file then
				local relative, absolute = require("config.repo").relative_existing(root, file)
				if not relative then
					relative, absolute = require("config.repo").relative_existing(root, vim.fs.joinpath(root, file))
				end
				if not relative then
					absolute = nil
				end
				local key = absolute and table.concat({ absolute, lnum, col or "1", message }, "\0") or nil
				if key and not seen[key] then
					seen[key] = true
					items[#items + 1] = {
						filename = absolute,
						lnum = tonumber(lnum),
						col = tonumber(col) or 1,
						text = message,
						type = "E",
					}
				end
			end
		end
	end
	return items
end

function M.import_last()
	if not last_identity then
		notify("No Just run exists in this Neovim instance", vim.log.levels.WARN)
		return
	end
	local transcript, err = workbench.transcript(last_identity)
	if not transcript then
		notify(err, vim.log.levels.ERROR)
		return
	end
	local items = M.parse_locations(last_identity.task_root, transcript.lines)
	if #items == 0 then
		notify("No conservative file:line[:col] locations found", vim.log.levels.WARN)
		return
	end
	vim.fn.setqflist({}, " ", { title = "Just output", items = items })
	vim.cmd("Trouble qflist open")
end

function M.setup()
	configure()
	vim.api.nvim_create_user_command("JustRun", function(opts)
		M.run(opts.args)
	end, { nargs = "?", desc = "Choose and run a trusted Just recipe" })
	vim.api.nvim_create_user_command("JustImportLast", M.import_last, {
		nargs = 0,
		desc = "Import conservative locations from the last Just terminal",
	})
end

M._decode_dump = workbench._decode_dump
M._find_justfile = find_justfile
M._workbench = workbench

return M
