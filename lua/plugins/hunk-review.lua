-- Review of code written by an out-of-process coding agent (Claude Code, Codex).
--
-- The agent writes to disk, then `:HunkReview` opens a two-pane explorer over
-- `git diff`, hunk by hunk, where each finding is annotated with `c`. The payoff
-- is the export: `<CR>` copies the review to the clipboard grouped by comment
-- with `file:line` locations, ready to paste back into the agent's session, and
-- `e` produces the same thing as JSON for tools that want structure.
--
-- Diff modes cycle with `[` / `]`: uncommitted (`git diff HEAD`), against the
-- PR target's merge-base, and against the base branch (`base_branches` below).
--
-- Two things worth knowing, both verified against the plugin's source rather
-- than its README:
--
--   * `git diff HEAD` does not list untracked files, and an agent creates them
--     constantly. The plugin compensates: in uncommitted mode it appends a
--     `--no-index` diff for everything `git ls-files --others` reports, so a
--     brand-new file does show up as a reviewable hunk.
--   * it shells out to `gh` (to detect a PR's base branch) with no
--     `executable()` guard, and `vim.system` raises ENOENT when the binary is
--     missing -- so `:HunkReview` fails outright on a machine without `gh`,
--     even in a mode that never needs it. octo.nvim already wants `gh auth
--     login` here, so this only bites on a host where that was never set up.
--
-- Note `]h` / `[h` inside the review pane move between hunk headers, shadowing
-- the gitsigns mappings of the same name -- buffer-locally, so gitsigns is
-- unaffected everywhere else.
return {
	{
		"shaunchander/hunk-review.nvim",
		cond = function()
			return not vim.g.vscode
		end,
		-- snacks.nvim (its UI dependency) is already a spec of its own here.
		dependencies = { "folke/snacks.nvim" },
		cmd = { "HunkReview", "HunkReviewRefresh", "HunkReviewExport", "HunkReviewReset" },
		keys = {
			{ "<leader>vv", "<cmd>HunkReview<cr>", desc = "Review agent changes" },
			{ "<leader>ve", "<cmd>HunkReviewExport<cr>", desc = "Export review as JSON" },
		},
		opts = {
			base_branches = { "main", "master", "develop" },
			layout = {
				-- The explorer is a file list; the diff is what you actually read.
				-- It stays legible this narrow because of the wrap below.
				explorer_width = 0.15,
			},
		},
		config = function(_, opts)
			require("hunk-review").setup(opts)

			-- The plugin hardcodes near-black backgrounds for the diff
			-- (#1a1a1a / #1a2e1a / #2e1a1a) and paints them over the whole
			-- line, so a light theme's dark text lands on an almost-black
			-- background. It sets them with `default = true`, so ours win.
			--
			-- Linking to DiffAdd/DiffDelete is not enough here: vscode.nvim
			-- ships the *same* dark diff colours for both backgrounds
			-- (DiffDelete is #6f1313 either way), so light mode would still be
			-- dark red under dark text. Hence explicit light values and links
			-- only when dark -- the same trade-off render-markdown.lua makes,
			-- and its palette, so the two look like one system.
			--
			-- The plugin also defines these once at load with no ColorScheme
			-- autocmd, so a theme change wipes them and nothing restores them.
			-- Re-applying below fixes that too.
			local function apply_overrides()
				local set = vim.api.nvim_set_hl
				if vim.o.background == "light" then
					set(0, "HunkReviewAddBg", { bg = "#dceadb" })
					set(0, "HunkReviewDeleteBg", { bg = "#f0dcdc" })
					set(0, "HunkReviewDiffBg", { bg = "#e8e8e8" })
				else
					set(0, "HunkReviewAddBg", { link = "DiffAdd" })
					set(0, "HunkReviewDeleteBg", { link = "DiffDelete" })
					set(0, "HunkReviewDiffBg", { link = "NormalFloat" })
				end
			end

			vim.api.nvim_create_autocmd("ColorScheme", {
				group = vim.api.nvim_create_augroup("HunkReviewBgFollow", { clear = true }),
				callback = apply_overrides,
			})
			apply_overrides()

			-- The plugin sizes the explorer once, when it builds the layout, and
			-- never marks it fixed. So `e` opening its export in a plain
			-- `botright vsplit` -- a window the layout does not manage -- and
			-- then being closed leaves Vim to redistribute the width equally,
			-- and the file tree jumps to half the screen. winfixwidth keeps the
			-- configured share no matter what windows come and go around it.
			--
			-- wrap is what makes a 15% column usable: without it a long path is
			-- simply cut off, and breakindent keeps the continuation lines
			-- aligned under the tree so the shape still reads.
			-- Deferred and applied per window rather than via plain `vim.wo`:
			-- the plugin sets the filetype while the buffer is still not in its
			-- window, so at FileType time the current window is the wrong one.
			vim.api.nvim_create_autocmd("FileType", {
				group = vim.api.nvim_create_augroup("HunkReviewExplorerWin", { clear = true }),
				pattern = "hunkreviewexplorer",
				callback = function(ev)
					vim.schedule(function()
						for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
							if vim.api.nvim_win_is_valid(win) then
								vim.wo[win].winfixwidth = true
								vim.wo[win].wrap = true
								vim.wo[win].breakindent = true
							end
						end
					end)
				end,
			})
		end,
	},
}
