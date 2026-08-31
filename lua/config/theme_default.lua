-- lua/config/theme_default.lua
-- The versioned theme selection: what a fresh clone of this config starts on.
--
-- This file IS under version control. It is used when the shared machine-local
-- YAML selection under the canonical nvim state directory is absent or invalid,
-- so editing it changes the starting point for a new machine without touching
-- what an existing machine selected explicitly.
--
-- Change the running theme with `:Theme` instead of editing this by hand;
-- `:ThemeReset` discards the local selection and comes back here.

return {
	colorscheme = "vscode",
}
