local treesitter_runtime = require("config.treesitter_runtime")

return {
	{
		"kevinhwang91/nvim-ufo",
		cond = function()
			return not vim.g.vscode
		end,
		event = "BufReadPost",
		dependencies = { "kevinhwang91/promise-async" },
		config = function()
			vim.o.foldlevel = 99
			vim.o.foldlevelstart = 99
			vim.o.foldenable = true

			local ufo = require("ufo")
			ufo.setup({
				provider_selector = function(buf)
					if treesitter_runtime.policy(buf).eligible then
						return { "treesitter", "indent" }
					end
					return { "indent" }
				end,
			})
			treesitter_runtime.observe_policy("ufo", function(current)
				-- Detach/attach is UFO's public cache invalidation boundary. Only
				-- reselect a buffer UFO still owns so :UfoDetach remains respected.
				if ufo.hasAttached(current.buf) then
					ufo.detach(current.buf)
					ufo.attach(current.buf)
				end
			end)
		end,
	},
}
