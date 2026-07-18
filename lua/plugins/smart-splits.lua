-- Navegación sin costura entre splits de nvim y panes de Zellij (Alt-hjkl).
-- Al llegar al borde de un split, smart-splits detecta $ZELLIJ y salta al pane
-- vecino vía `zellij action move-focus`. Compatible con Ghostty
-- (macos-option-as-alt = left → la Option izquierda emite <A-...>).
return {
  "mrjones2014/smart-splits.nvim",
  lazy = false,
  opts = {
    at_edge = "stop",
    multiplexer_integration = "zellij",
  },
  keys = {
    -- Mover el foco (n = normal, t = terminal)
    { "<A-h>", function() require("smart-splits").move_cursor_left() end, mode = { "n", "t" }, desc = "Focus split/pane izquierda" },
    { "<A-j>", function() require("smart-splits").move_cursor_down() end, mode = { "n", "t" }, desc = "Focus split/pane abajo" },
    { "<A-k>", function() require("smart-splits").move_cursor_up() end, mode = { "n", "t" }, desc = "Focus split/pane arriba" },
    { "<A-l>", function() require("smart-splits").move_cursor_right() end, mode = { "n", "t" }, desc = "Focus split/pane derecha" },
    -- Redimensionar splits de nvim
    { "<A-Left>", function() require("smart-splits").resize_left() end, desc = "Resize split izquierda" },
    { "<A-Down>", function() require("smart-splits").resize_down() end, desc = "Resize split abajo" },
    { "<A-Up>", function() require("smart-splits").resize_up() end, desc = "Resize split arriba" },
    { "<A-Right>", function() require("smart-splits").resize_right() end, desc = "Resize split derecha" },
  },
}
