return {
	{
		"Mofiqul/vscode.nvim",
		lazy = false,
		priority = 1000,
		cond = function()
			return not vim.g.vscode
		end,
		config = function()
			--------------------------------------------------------------
			-- Theme painter (repaint-guarded).
			--------------------------------------------------------------
			-- Per-host overrides from ~/.nvim-local.lua (see config.local_config).
			local theme = require("config.local_config").get("theme", {})
			local transparent = theme.transparent
			if transparent == nil then
				transparent = false
			end
			local italic_comments = theme.italic_comments
			if italic_comments == nil then
				italic_comments = true
			end

			local last_style = nil

			local function apply(bg)
				local style = bg == "light" and "light" or "dark"
				if style == last_style then
					return
				end
				last_style = style

				local ok, vscode = pcall(require, "vscode")
				if not ok then
					vim.notify("vscode.nvim not available", vim.log.levels.ERROR)
					return
				end

				vscode.setup({
					style = style,
					transparent = transparent,
					italic_comments = italic_comments,
				})
				vim.cmd("colorscheme vscode")
			end

			-- A host can pin the background; then we skip OSC 11 auto-detection.
			if theme.background == "light" or theme.background == "dark" then
				vim.o.background = theme.background
				apply(theme.background)
				return
			end

			-- Paint once with whatever Neovim detected (works on a normal boot).
			apply(vim.o.background)

			local group = vim.api.nvim_create_augroup("VscodeBgFollow", { clear = true })

			-- Re-apply the matching style whenever 'background' changes, driven
			-- either by Neovim's own startup detection, by the OSC 11 re-query
			-- below, or by a manual `:set background=...`.
			vim.api.nvim_create_autocmd("OptionSet", {
				pattern = "background",
				group = group,
				callback = function()
					if vim.g.vscode then
						return
					end
					apply(vim.v.option_new)
				end,
			})

			--------------------------------------------------------------
			-- Active OSC 11 background detection.
			--
			-- Neovim auto-detects the terminal background via OSC 11 at
			-- startup, but when lazy.nvim installs a plugin on boot its
			-- install UI clobbers that detection window, leaving
			-- 'background' stuck at the "dark" default for the whole
			-- session. To recover, we re-emit the OSC 11 query ourselves
			-- after lazy is done and parse the reply via TermResponse.
			-- Logic mirrors Neovim core ($VIMRUNTIME/lua/vim/_core/defaults.lua).
			--------------------------------------------------------------

			-- Normalize one hex component (1..4 digits) to 0.0..1.0, scaling
			-- by its own width so 2- and 4-digit values both map correctly.
			local function parsecolor(c)
				if #c == 0 or #c > 4 then
					return nil
				end
				local val = tonumber(c, 16)
				if not val then
					return nil
				end
				local max = tonumber(string.rep("f", #c), 16)
				return val / max
			end

			-- Parse an OSC 11 reply: rgb:R/G/B or rgba:R/G/B/A (alpha ignored).
			-- The terminator is already stripped by Neovim from ev.data.sequence.
			local function parseosc11(resp)
				local r, g, b = resp:match("^\27%]11;rgb:(%x+)/(%x+)/(%x+)$")
				if not (r and g and b) then
					local a
					r, g, b, a = resp:match("^\27%]11;rgba:(%x+)/(%x+)/(%x+)/(%x+)$")
					if not a then
						return nil
					end
				end
				if r and g and b then
					return r, g, b
				end
				return nil
			end

			-- Persistent handler: any OSC 11 reply updates 'background', which
			-- fires the OptionSet autocmd above and repaints. Idempotent:
			-- setting the same value is a no-op, so re-queries never loop.
			vim.api.nvim_create_autocmd("TermResponse", {
				group = group,
				nested = true,
				callback = function(ev)
					if vim.g.vscode then
						return
					end
					local seq = type(ev.data) == "table" and ev.data.sequence or ev.data
					if type(seq) ~= "string" then
						return
					end
					local r, g, b = parseosc11(seq)
					if not (r and g and b) then
						return
					end
					local rr, gg, bb = parsecolor(r), parsecolor(g), parsecolor(b)
					if not (rr and gg and bb) then
						return
					end
					local luminance = (0.299 * rr) + (0.587 * gg) + (0.114 * bb)
					vim.o.background = luminance < 0.5 and "dark" or "light"
				end,
			})

			-- Re-emit the OSC 11 query. nvim_ui_send is the documented way in
			-- 0.12 to reach the host terminal; query string matches core's.
			local function query_bg()
				if vim.g.vscode then
					return
				end
				vim.api.nvim_ui_send("\27]11;?\7")
			end

			-- VeryLazy fires once after lazy finishes its startup work.
			vim.api.nvim_create_autocmd("User", {
				pattern = "VeryLazy",
				group = group,
				once = true,
				callback = function()
					vim.schedule(query_bg)
				end,
			})

			-- Re-query after any install/update/sync — exactly the scenario
			-- that breaks Neovim's own boot-time detection.
			vim.api.nvim_create_autocmd("User", {
				pattern = { "LazyInstall", "LazyUpdate", "LazySync", "LazyCheck", "LazyDone" },
				group = group,
				callback = function()
					vim.schedule(query_bg)
				end,
			})
		end,
	},
}
