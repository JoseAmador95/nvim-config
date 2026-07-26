-- Resalta todas las apariciones de la palabra/símbolo bajo el cursor (estilo
-- VSCode) y añade lo que VSCode no tiene: text objects sobre la referencia y
-- "freeze" del resaltado. Providers en cascada LSP -> treesitter -> regex, así
-- que funciona en cualquier buffer. Navegación: */# nativos (textual) para el día
-- a día, y Option/Alt + */# para el salto SEMÁNTICO (solo referencias reales, LSP).
return {
	"RRethy/vim-illuminate",
	event = { "BufReadPost", "BufNewFile" },
	cond = function()
		return not vim.g.vscode
	end,
	opts = {
		providers = { "lsp", "treesitter", "regex" },
		delay = 100,
		-- Afinado (ruido/rendimiento):
		-- No resaltar un símbolo que aparece una sola vez.
		min_count_to_highlight = 2,
		-- En archivos enormes usar solo LSP (o nada si no hay servidor) para no
		-- pagar el provider regex sobre miles de líneas.
		large_file_cutoff = 2000,
		large_file_overrides = { providers = { "lsp" } },
		-- No iluminar buffers de UI / herramientas.
		filetypes_denylist = {
			"help",
			"qf",
			"lazy",
			"mason",
			"Trouble",
			"trouble",
			"noice",
			"notify",
			"octo",
			"snacks_picker_list",
			"snacks_dashboard",
		},
		under_cursor = true,
	},
	config = function(_, opts)
		local illuminate = require("illuminate")
		illuminate.configure(opts) -- NOTA: es configure(), no setup()

		-- Salto SEMÁNTICO entre referencias (con LSP, solo referencias reales) en
		-- Option/Alt + */#. Los */# nativos (textual + cgn/n/N) quedan intactos.
		vim.keymap.set("n", "<A-*>", function()
			illuminate.goto_next_reference(true)
		end, { desc = "Siguiente referencia semántica (illuminate)" })
		vim.keymap.set("n", "<A-#>", function()
			illuminate.goto_prev_reference(true)
		end, { desc = "Referencia semántica anterior (illuminate)" })

		-- Text objects: operar sobre la referencia bajo el cursor
		-- (cir cambia, dir borra, yir copia, vir selecciona; combina con . y con */#).
		vim.keymap.set({ "o", "x" }, "ir", illuminate.textobj_select, { desc = "Referencia (illuminate)" })
		vim.keymap.set({ "o", "x" }, "ar", illuminate.textobj_select, { desc = "Referencia (illuminate)" })

		-- Freeze: mantener resaltado el símbolo actual aunque muevas el cursor.
		vim.keymap.set("n", "<leader>li", illuminate.toggle_freeze_buf, { desc = "Fijar/soltar resaltado (illuminate)" })
	end,
}
