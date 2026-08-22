vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.env.NVIM_CONFIG_ROOT or vim.fn.getcwd()
local vscode_stub = dofile(vim.fs.joinpath(repo, "tests", "support", "vscode_stub.lua"))

local function fail(message)
	vim.api.nvim_err_writeln("vscode_profile_spec: " .. message)
	vim.cmd("cquit")
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local ok, err = xpcall(function()
				assert(vim.g.vscode, "VSCode profile flag is missing")
				assert(vim.g.nvim_config_initialized == true, "init.lua did not complete in the VSCode profile")
				for _, command in ipairs({
					"MenuOpen",
					"NavigationBack",
					"NavigationForward",
					"NavigationHistory",
					"CloseTab",
					"DiagramShow",
					"ClangdSetCompileCommands",
					"ClangdSwitchSourceHeader",
					"CoverageLoad",
					"CoverageSummary",
					"CoverageClear",
					"DevPodUp",
					"DevPodRecreate",
					"DevPodStatus",
					"DevPodLog",
					"HostEditor",
					"JustRun",
					"JustImportLast",
					"NvimConfigToolsInstall",
					"LogWatchCurrentFile",
					"Mason",
					"ReviewRoundStart",
					"Scratch",
					"TuicrReview",
					"AgentContext",
					"AgentResultsImport",
				}) do
					assert(vim.fn.exists(":" .. command) == 0, command .. " leaked into VSCode")
				end
				assert(package.loaded["config.editor_rpc"] == nil, "editor RPC module loaded in VSCode")
				assert(
					vim.tbl_isempty(vim.fn.maparg("<leader><leader>", "n", false, true)),
					"palette mapping leaked into VSCode"
				)
				assert(
					vim.tbl_isempty(vim.fn.maparg("<leader><leader>", "x", false, true)),
					"visual palette mapping leaked into VSCode"
				)
				assert(_G.NvimReviewOpenRequest == nil, "editor RPC function leaked into VSCode")

				require("lazy").load({ plugins = { "vscode-multi-cursor.nvim" } })
				local runtime_paths = vim.api.nvim_list_runtime_paths()
				local function has_plugin(name)
					for _, path in ipairs(runtime_paths) do
						if vim.fn.fnamemodify(path, ":t") == name then
							return true
						end
					end
					return false
				end
				for _, plugin in ipairs({
					"bufferline.nvim",
					"catppuccin",
					"mason.nvim",
					"nvim-lint",
					"remote-nvim.nvim",
					"menu",
					"vscode.nvim",
				}) do
					assert(not has_plugin(plugin), plugin .. " loaded in VSCode")
				end
				assert(has_plugin("vscode-multi-cursor.nvim"), "VSCode multi-cursor integration did not load")
				for _, lhs in ipairs({ "[b", "]b" }) do
					assert(not vim.tbl_isempty(vim.fn.maparg(lhs, "n", false, true)), lhs .. " was removed from VSCode")
				end
				local close = vim.fn.maparg("<leader>q", "n", false, true)
				assert(type(close.callback) == "function", "VSCode close mapping was replaced by CloseTab")
				close.callback()
				local close_call = vscode_stub.calls[#vscode_stub.calls]
				assert(
					close_call and close_call.action == "workbench.action.closeActiveEditor",
					"VSCode close action drifted"
				)

				local definition = vim.fn.maparg("gd", "n", false, true)
				assert(not vim.tbl_isempty(definition), "VSCode definition mapping is missing")
				assert(type(definition.callback) == "function", "VSCode definition mapping does not call an action")
				definition.callback()
				local call = vscode_stub.calls[#vscode_stub.calls]
				assert(call and call.action == "editor.action.revealDefinition", "VSCode definition action drifted")
			end, debug.traceback)

			if not ok then
				fail(err)
				return
			end
			print("vscode_profile_spec: terminal services stay out of VSCode")
			vim.cmd("quitall!")
		end)
	end,
})
