-- Loaded before init.lua. Assert the full-editor load boundary after all
-- startup events have settled without activating any deferred product.
vim.o.shadafile = "NONE"
vim.o.swapfile = false

local function fail(message)
	vim.api.nvim_err_writeln("load_contract_spec: " .. message)
	vim.cmd("cquit")
end

local completed = false
local late_very_lazy_callback_ran = false

local function is_module_or_child(name, prefix)
	return name == prefix or name:sub(1, #prefix + 1) == prefix .. "."
end

vim.api.nvim_create_autocmd("User", {
	pattern = "VeryLazy",
	once = true,
	callback = function()
		vim.schedule(function()
			vim.defer_fn(function()
				completed = true
				local ok, err = xpcall(function()
					assert(vim.g.did_very_lazy == true, "load boundary ran before User VeryLazy settled")
					assert(late_very_lazy_callback_ran, "load boundary skipped a scheduled VeryLazy callback")
					for _, name in ipairs({
						"trusted_workspace",
						"exact_editor",
						"tab_first",
						"treesitter_runtime",
						"theme_router",
						"native_review",
					}) do
						assert(package.loaded[name] ~= nil, name .. " was not loaded at its required early boundary")
					end

					local deferred_modules = {
						"devcontainer_editor",
						"terminal_lifecycle",
						"project_python",
						"action_palette",
						"diagram_view",
						"log_workbench",
						"repo_scratch",
						"coverage_workbench",
						"just_workbench",
						"clangd_compile_db",
						"verified_tools",
					}
					for loaded_name in pairs(package.loaded) do
						for _, prefix in ipairs(deferred_modules) do
							assert(
								not is_module_or_child(loaded_name, prefix),
								loaded_name .. " crossed the " .. prefix .. " first-use boundary during startup"
							)
						end
					end
					for _, name in ipairs({
						"config.python",
						"config.terminal",
						"config.cmake",
						"config.action_palette",
						"config.log_patterns",
						"config.tool_bootstrap",
					}) do
						assert(package.loaded[name] == nil, name .. " host adapter loaded before its trigger")
					end

					for _, command in ipairs({
						"MenuOpen",
						"DiagramShow",
						"LogHlAdd",
						"LogHlRegex",
						"LogHlClear",
						"LogWatchCurrentFile",
						"Scratch",
						"CoverageLoad",
						"CoverageSummary",
						"CoverageClear",
						"JustRun",
						"JustImportLast",
						"ClangdSetCompileCommands",
						"NvimConfigToolsInstall",
					}) do
						assert(vim.fn.exists(":" .. command) == 2, command .. " was not registered by its host facade")
					end

					local runtime_paths = {}
					for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
						runtime_paths[vim.fs.normalize(path)] = true
					end
					for _, path in ipairs(require("config.local_plugins").paths()) do
						assert(
							runtime_paths[vim.fs.normalize(path)],
							"local product is missing from runtimepath: " .. path
						)
					end

					local local_paths = {}
					for _, path in ipairs(require("config.local_plugins").paths()) do
						local_paths[vim.fs.normalize(path)] = true
					end
					local lazy_config = package.loaded["lazy.core.config"]
					for name, plugin in pairs((lazy_config and lazy_config.plugins) or {}) do
						local directory = type(plugin) == "table" and plugin.dir or nil
						assert(
							not directory or not local_paths[vim.fs.normalize(directory)],
							"local product was registered as Lazy plugin " .. tostring(name)
						)
					end
				end, debug.traceback)
				if not ok then
					fail(err)
					return
				end
				io.stdout:write("load_contract_spec: early and first-use boundaries are isolated\n")
				io.stdout:flush()
				vim.cmd("quitall!")
			end, 0)
		end)
	end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		if not completed then
			fail("Neovim exited before the deferred load boundary was verified")
		end
	end,
})

-- Registered after the verifier on purpose: a VeryLazy consumer may defer its
-- first import by one scheduler turn. The assertions above must run later.
vim.api.nvim_create_autocmd("User", {
	pattern = "VeryLazy",
	once = true,
	callback = function()
		vim.schedule(function()
			late_very_lazy_callback_ran = true
		end)
	end,
})

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			-- Lazy defers VeryLazy until UIEnter. Headless CI has no attached UI,
			-- so exercise that same documented boundary explicitly.
			if vim.g.did_very_lazy ~= true then
				vim.api.nvim_exec_autocmds("UIEnter", { modeline = false })
			end
			vim.defer_fn(function()
				if not completed then
					fail("User VeryLazy did not fire during startup")
				end
			end, 1000)
		end)
	end,
})
