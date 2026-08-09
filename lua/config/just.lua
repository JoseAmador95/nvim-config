-- Host-only Just integration. Recipes are discovered from trusted justfiles,
-- parameters become argv entries, and execution uses the terminal factory.
local M = {}

local last = nil

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Just" })
end

local function find_justfile(root)
	for _, name in ipairs({ "justfile", "Justfile", ".justfile" }) do
		local path = vim.fs.joinpath(root, name)
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end
	return nil
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
	-- vim.secure.read persists the user's trust decision by content hash.
	if not vim.secure.read(justfile) then
		return nil, "justfile was not trusted"
	end
	return { root = root, justfile = justfile }
end

local function decode_dump(result)
	if not result or result.code ~= 0 then
		local detail = result and vim.trim(result.stderr or "") or "could not start just"
		return nil, detail ~= "" and detail or "just --dump failed"
	end
	local ok, decoded = pcall(vim.json.decode, result.stdout or "")
	if not ok or type(decoded) ~= "table" or type(decoded.recipes) ~= "table" then
		return nil, "just --dump returned invalid JSON"
	end
	local recipes = {}
	for name, recipe in pairs(decoded.recipes) do
		if type(name) ~= "string" or name == "" or type(recipe) ~= "table" then
			return nil, "just --dump contains an invalid recipe"
		end
		local parameters = recipe.parameters or {}
		if type(parameters) ~= "table" or not vim.islist(parameters) then
			return nil, "recipe parameters are not an array: " .. name
		end
		for _, parameter in ipairs(parameters) do
			if type(parameter) ~= "table" or type(parameter.name) ~= "string" or parameter.name == "" then
				return nil, "recipe contains an invalid parameter: " .. name
			end
		end
		recipes[#recipes + 1] = {
			name = name,
			text = name,
			description = type(recipe.doc) == "string" and recipe.doc or "",
			parameters = parameters,
		}
	end
	table.sort(recipes, function(a, b)
		return a.name < b.name
	end)
	return recipes
end

local function terminal_spec(ctx, argv)
	return {
		runtime = "host",
		root = ctx.root,
		id = "just",
		argv = argv,
		cwd = ctx.root,
		env = {},
		layout = "bottom",
		title = "just",
		close_on_success = false,
	}
end

local function execute(ctx, recipe, values)
	local argv = {
		"just",
		"--justfile",
		ctx.justfile,
		"--working-directory",
		ctx.root,
		recipe.name,
	}
	vim.list_extend(argv, values)
	local spec = terminal_spec(ctx, argv)
	local record, err = require("config.terminal").restart(spec)
	if not record then
		notify("Could not run recipe: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	last = { root = ctx.root, spec = spec }
end

local function prompt_parameters(ctx, recipe, index, values)
	index = index or 1
	values = values or {}
	local parameter = recipe.parameters[index]
	if not parameter then
		execute(ctx, recipe, values)
		return
	end
	local variadic = parameter.kind == "plus" or parameter.kind == "star" or parameter.kind == "variadic"
	local default = type(parameter.default) == "string" and parameter.default or ""
	vim.ui.input({
		prompt = ("just %s: %s%s: "):format(recipe.name, parameter.name, variadic and " (space-separated)" or ""),
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
			prompt_parameters(ctx, recipe, index + 1, values)
			return
		elseif variadic then
			vim.list_extend(values, vim.split(value, "%s+", { trimempty = true }))
		else
			values[#values + 1] = value
		end
		prompt_parameters(ctx, recipe, index + 1, values)
	end)
end

local function choose(ctx, recipes, requested)
	if requested and requested ~= "" then
		for _, recipe in ipairs(recipes) do
			if recipe.name == requested then
				prompt_parameters(ctx, recipe)
				return
			end
		end
		notify("Unknown recipe: " .. requested, vim.log.levels.ERROR)
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
		items = recipes,
		format = "text",
		preview = false,
		layout = { preset = "select" },
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.schedule(function()
					prompt_parameters(ctx, item)
				end)
			end
		end,
	})
end

function M.run(requested, dependencies)
	local ctx, ctx_err = context()
	if not ctx then
		notify(ctx_err, vim.log.levels.ERROR)
		return
	end
	local argv = {
		"just",
		"--dump",
		"--dump-format",
		"json",
		"--justfile",
		ctx.justfile,
		"--working-directory",
		ctx.root,
	}
	local system = dependencies and dependencies.system or vim.system
	system(argv, { text = true }, function(result)
		vim.schedule(function()
			local recipes, err = decode_dump(result)
			if not recipes then
				notify("Could not list recipes: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			choose(ctx, recipes, requested)
		end)
	end)
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
	if not last then
		notify("No Just run exists in this Neovim instance", vim.log.levels.WARN)
		return
	end
	local lines, err = require("config.terminal").lines(last.spec)
	if not lines then
		notify(err, vim.log.levels.ERROR)
		return
	end
	local items = M.parse_locations(last.root, lines)
	if #items == 0 then
		notify("No conservative file:line[:col] locations found", vim.log.levels.WARN)
		return
	end
	vim.fn.setqflist({}, " ", { title = "Just output", items = items })
	vim.cmd("Trouble qflist open")
end

function M.setup()
	vim.api.nvim_create_user_command("JustRun", function(opts)
		M.run(opts.args)
	end, { nargs = "?", desc = "Choose and run a trusted Just recipe" })
	vim.api.nvim_create_user_command("JustImportLast", M.import_last, {
		nargs = 0,
		desc = "Import conservative locations from the last Just terminal",
	})
end

M._decode_dump = decode_dump
M._find_justfile = find_justfile

return M
