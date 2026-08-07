-- lua/config/theme_default.lua
-- The versioned theme selection: what a fresh clone of this config starts on.
--
-- This file IS under version control. It is read only when the machine-local
-- selection (lua/localconfig/theme.lua, gitignored) is absent or unreadable,
-- so editing it changes the starting point for a new machine without touching
-- what any existing machine is currently using.
--
-- Change the running theme with `:Theme` instead of editing this by hand;
-- `:ThemeReset` discards the local selection and comes back here.

return {
	colorscheme = "vscode",
}
