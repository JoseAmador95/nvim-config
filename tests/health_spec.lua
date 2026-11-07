local T = MiniTest.new_set()

T["health observes loaded state without activation, probes, or writes"] = function()
	vim.o.shadafile = "NONE"
	vim.o.swapfile = false

	local repo = vim.fn.getcwd()
	vim.opt.runtimepath:prepend(repo)
	package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

	local module_names =
		{ "config.local_config", "config.tool_bootstrap", "config.release_installer", "config.pager", "verified_tools" }
	for _, product in ipairs(require("config.local_plugins").products()) do
		module_names[#module_names + 1] = product.module
	end
	local originals = {}
	local attempted_loads = {}
	for _, name in ipairs(module_names) do
		if not originals[name] then
			originals[name] = { loaded = package.loaded[name], preload = package.preload[name] }
			package.loaded[name] = nil
			package.preload[name] = function()
				attempted_loads[#attempted_loads + 1] = name
				error("health attempted to load " .. name)
			end
		end
	end

	local original_system = vim.system
	local system_calls = 0
	vim.system = function()
		system_calls = system_calls + 1
		error("health started a process")
	end
	local mutation_calls = {}
	local mutation_functions = {
		{ owner = vim.fn, name = "delete" },
		{ owner = vim.fn, name = "mkdir" },
		{ owner = vim.fn, name = "rename" },
		{ owner = vim.fn, name = "setfperm" },
		{ owner = vim.fn, name = "writefile" },
		{ owner = vim.uv, name = "fs_chmod" },
		{ owner = vim.uv, name = "fs_copyfile" },
		{ owner = vim.uv, name = "fs_link" },
		{ owner = vim.uv, name = "fs_mkdir" },
		{ owner = vim.uv, name = "fs_rename" },
		{ owner = vim.uv, name = "fs_rmdir" },
		{ owner = vim.uv, name = "fs_symlink" },
		{ owner = vim.uv, name = "fs_unlink" },
		{ owner = vim.uv, name = "fs_write" },
	}
	for _, mutation in ipairs(mutation_functions) do
		mutation.original = mutation.owner[mutation.name]
		local name = mutation.name
		mutation.owner[name] = function()
			mutation_calls[#mutation_calls + 1] = name
			error("health attempted mutation through " .. name)
		end
	end
	local original_health = {}
	local emitted = {}
	for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
		original_health[kind] = vim.health[kind]
		vim.health[kind] = function(message, advice)
			emitted[#emitted + 1] = { kind = kind, message = tostring(message), advice = advice }
		end
	end

	package.loaded["nvimconfig.health"] = nil
	local health = require("nvimconfig.health")
	local catalog = health._tool_contract()
	assert(#catalog == #require("config.toolchain").tool_order)
	for _, item in ipairs(catalog) do
		assert(item.name ~= "gumtree" and item.backend and item.version ~= "latest")
	end

	local products = health._local_product_status()
	assert(#products == #require("config.local_plugins").products(), "health does not aggregate every local product")
	for _, product in ipairs(products) do
		assert(product.loaded == false, product.name .. " was activated by observational inventory")
		assert(product.observational == true, product.name .. " missing observational marker")
		assert(product.error == nil, product.name .. " was reported broken merely because it was not loaded")
		assert(package.loaded[product.module] == nil, product.name .. " crossed its first-use boundary")
	end

	local fake_status = { configured = true, nested = { value = 1 } }
	local fake_config = { enabled = true }
	local first_module = products[1].module
	local original_first = package.loaded[first_module]
	package.loaded[first_module] = {
		status = function()
			return fake_status
		end,
		effective_config = function()
			return fake_config
		end,
	}
	products = health._local_product_status()
	assert(products[1].loaded and products[1].status.nested.value == 1, "loaded product status was not observed")
	products[1].status.nested.value = 2
	products[1].effective_config.enabled = false
	products = health._local_product_status()
	assert(products[1].status.nested.value == 1, "health returned shared plugin status")
	assert(products[1].effective_config.enabled == true, "health returned shared plugin configuration")
	package.loaded[first_module] = original_first

	local function emitted_message(predicate, from)
		for index = from or 1, #emitted do
			if predicate(emitted[index].message) then
				return true
			end
		end
		return false
	end
	local catalog_entry = "devcontainers-cli@0.89.0 (npm:@devcontainers/cli)"
	local check_ok, check_err = pcall(health.check)
	assert(check_ok, check_err)
	assert(#emitted > 0, "health emitted no observations")
	assert(emitted[1].kind == "start" and emitted[1].message == "Problems", "health did not lead with problems")
	assert(not emitted_message(function(message)
		return message == catalog_entry or message:find("^PATH%[") ~= nil
	end), "the PATH listing and Mise catalog must stay out of the default report")
	local detailed_from = #emitted + 1
	check_ok, check_err = pcall(health.check, { details = true })
	assert(check_ok, check_err)
	assert(
		emitted_message(function(message)
			return message == catalog_entry
		end, detailed_from),
		"health details omitted the exact Mise catalog entry"
	)
	assert(system_calls == 0, "health executed an external probe")
	assert(#mutation_calls == 0, "health attempted filesystem mutation: " .. vim.inspect(mutation_calls))
	assert(#attempted_loads == 0, "health activated runtime modules: " .. vim.inspect(attempted_loads))

	package.loaded["localconfig.health"] = nil
	local local_health = require("localconfig.health")
	local before = #emitted
	local_health.check()
	assert(#attempted_loads == 0, "localconfig health loaded config.local_config")
	assert(
		#emitted > before and emitted[#emitted].message:find("did not activate", 1, true),
		"unloaded local config was unclear"
	)

	local observed_path = vim.fn.tempname()
	package.loaded["config.local_config"] = {
		observation = function()
			return {
				evaluated = true,
				errors = { "fixture validation error" },
				sources = { { path = observed_path, status = "absent" } },
			}
		end,
	}
	before = #emitted
	local_health.check()
	local observed_messages = {}
	for index = before + 1, #emitted do
		observed_messages[#observed_messages + 1] = emitted[index].message
	end
	local joined = table.concat(observed_messages, "\n")
	assert(joined:find(observed_path .. " (absent)", 1, true), "localconfig health lost observed source state")
	assert(joined:find("fixture validation error", 1, true), "localconfig health lost observed diagnostics")

	for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
		vim.health[kind] = original_health[kind]
	end
	vim.system = original_system
	for _, mutation in ipairs(mutation_functions) do
		mutation.owner[mutation.name] = mutation.original
	end
	for name, value in pairs(originals) do
		package.loaded[name] = value.loaded
		package.preload[name] = value.preload
	end

	require("config.local_plugins").setup()
	package.loaded["config.local_config"] = nil
	local local_config = require("config.local_config")
	local observation = local_config.observation()
	assert(observation.evaluated == false, "observation evaluated local config")
	assert(
		vim.tbl_isempty(observation.sources) and vim.tbl_isempty(observation.errors),
		"fresh observation invented state"
	)
	observation.sources[1] = { status = "mutated" }
	assert(vim.tbl_isempty(local_config.observation().sources), "local config observation leaked mutable state")

	assert(select(1, health._path_origin("/tmp/custom/bin/tool", { ["/tmp/custom/bin"] = true })) == "local_config")
	assert(select(1, health._path_origin(vim.fn.expand("~/.local/bin/tool"), {})) == "user-local")
	assert(select(1, health._path_origin(require("config.tool_paths").managed_bin() .. "/tool", {})) == "mise-launcher")
	assert(
		select(1, health._path_origin(require("config.tool_paths").managed_root() .. "/installs/tool", {})) == "managed"
	)
	assert(select(1, health._path_origin(require("config.tool_paths").mason_bin() .. "/tool", {})) == "mason")
end

T["health lists errors before warnings, each with the fix for the platform"] = function()
	local repo = vim.fn.getcwd()
	vim.opt.runtimepath:prepend(repo)
	package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

	-- Only mise and cc exist, so git (required) and the optional host tools are missing.
	local bin = vim.fn.tempname()
	vim.fn.mkdir(bin, "p")
	for _, name in ipairs({ "mise", "cc" }) do
		local path = vim.fs.joinpath(bin, name)
		vim.fn.writefile({ "#!/bin/sh" }, path)
		vim.fn.setfperm(path, "rwx------")
	end
	local original_path = vim.env.PATH
	vim.env.PATH = bin

	local emitted = {}
	local original_health = {}
	for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
		original_health[kind] = vim.health[kind]
		vim.health[kind] = function(message, advice)
			emitted[#emitted + 1] = { kind = kind, message = tostring(message), advice = advice }
		end
	end
	local platform = require("config.host_packages").detect({
		sysname = "Linux",
		os_release = 'PRETTY_NAME="Fedora Linux 43"\nID=fedora\nVERSION_ID=43\n',
		exepath = function()
			return ""
		end,
	})
	package.loaded["nvimconfig.health"] = nil
	local ok, err = pcall(require("nvimconfig.health").check, { platform = platform })
	for kind, original in pairs(original_health) do
		vim.health[kind] = original
	end
	vim.env.PATH = original_path
	vim.fn.delete(bin, "rf")
	assert(ok, err)

	local sections, last_error, first_warning, summary = {}, 0, math.huge, math.huge
	for index, item in ipairs(emitted) do
		if item.kind == "start" then
			sections[#sections + 1] = item.message
			summary = item.message == "Summary" and index or summary
		elseif item.kind == "error" then
			last_error = index
		elseif item.kind == "warn" then
			first_warning = math.min(first_warning, index)
		elseif index > summary then
			assert(item.kind == "ok" or item.kind == "info")
		end
	end
	assert(vim.deep_equal(sections, { "Problems", "Summary" }), vim.inspect(sections))
	assert(last_error > 0 and last_error < first_warning, "errors must precede warnings")
	assert(first_warning < summary, "problems must precede the summary")

	local function find(prefix)
		for _, item in ipairs(emitted) do
			if item.message:sub(1, #prefix) == prefix then
				return item
			end
		end
	end
	local git = find("git is missing")
	assert(git and git.kind == "error" and vim.deep_equal(git.advice, { "sudo dnf install git" }), vim.inspect(git))
	local rsvg = find("rsvg-convert is missing")
	assert(rsvg and rsvg.kind == "warn" and rsvg.advice[1] == "sudo dnf install librsvg2-tools", vim.inspect(rsvg))
	local lazygit = find("lazygit is missing")
	assert(lazygit and lazygit.advice[1]:find("lazygit/releases", 1, true), vim.inspect(lazygit))
	assert(find("Platform: Fedora Linux 43; fixes use dnf"), "the summary does not name the platform")
end

T["health drops automatic install failures that are already fixed"] = function()
	local repo = vim.fn.getcwd()
	vim.opt.runtimepath:prepend(repo)
	package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

	local bin = vim.fn.tempname()
	vim.fn.mkdir(bin, "p")
	for _, name in ipairs({ "git", "mise", "cc" }) do
		local path = vim.fs.joinpath(bin, name)
		vim.fn.writefile({ "#!/bin/sh" }, path)
		vim.fn.setfperm(path, "rwx------")
	end
	local original_path = vim.env.PATH
	vim.env.PATH = bin
	local stubbed = { "config.auto_install", "config.treesitter_runtime" }
	local originals = {}
	for _, name in ipairs(stubbed) do
		originals[name] = package.loaded[name]
	end
	local parsers_exact = true
	package.loaded["config.auto_install"] = {
		status = function()
			return {
				retry_seconds = 60,
				failures = {
					mise = { at = 1, detail = "old mise failure" },
					parsers = { at = 1, detail = "old build" },
				},
			}
		end,
	}
	package.loaded["config.treesitter_runtime"] = {
		inventory = function()
			if parsers_exact then
				return { exact = true, required = { {} }, problems = {} }
			end
			return { exact = false, required = { {}, {} }, problems = { "c:wrong", "lua:missing" } }
		end,
	}
	local original_warn = vim.health.warn
	local warnings = {}
	vim.health.warn = function(message)
		warnings[#warnings + 1] = tostring(message)
	end
	local platform = { os = "linux", name = "Linux", brew = false, rustup = false }
	package.loaded["nvimconfig.health"] = nil
	local health = require("nvimconfig.health")
	local function run()
		warnings = {}
		local ok, err = pcall(health.check, { platform = platform })
		assert(ok, err)
		return table.concat(warnings, "\n")
	end
	local exact_report = run()
	parsers_exact = false
	local stale_report = run()

	vim.health.warn = original_warn
	vim.env.PATH = original_path
	vim.fn.delete(bin, "rf")
	for _, name in ipairs(stubbed) do
		package.loaded[name] = originals[name]
	end

	assert(not exact_report:find("automatic", 1, true), "fixed steps still reported failures:\n" .. exact_report)
	assert(stale_report:find("automatic parsers install failed", 1, true), stale_report)
	assert(not stale_report:find("automatic mise install", 1, true), "Mise is installed:\n" .. stale_report)
	assert(
		stale_report:find("Tree-sitter parsers need an update (missing: lua; not at the locked revision: c)", 1, true),
		stale_report
	)
end

return T
