return {
	{
		"Civitasv/cmake-tools.nvim",
		cmd = {
			"CMakeGenerate",
			"CMakeBuild",
			"CMakeRun",
			"CMakeRunTest",
			"CMakeDebug",
			"CMakeSelectConfigurePreset",
			"CMakeSelectBuildPreset",
			"CMakeSelectBuildTarget",
			"CMakeSelectLaunchTarget",
			"CMakeSelectBuildType",
		},
		cond = function()
			return not vim.g.vscode
		end,
		opts = function()
			return {
				cmake_use_preset = true,
				cmake_regenerate_on_save = true,
				cmake_generate_options = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" },
				cmake_compile_commands_options = {
					action = "none",
				},
				cmake_executor = {
					name = "quickfix",
					opts = {
						show = "always",
						auto_close_when_success = false,
					},
				},
				cmake_use_scratch_buffer = true,
				cmake_runner = {
					name = "terminal",
				},
			}
		end,
	},
}
