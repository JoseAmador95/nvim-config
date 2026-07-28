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
		},
	},
}
