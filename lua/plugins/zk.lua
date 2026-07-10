-- Notas markdown rápidas en ~/Notes (configurable) mediante la CLI `zk`.
-- Independiente de los vaults de obsidian: solo crea/abre notas en un directorio
-- común. Requiere el binario `zk` en el $PATH (https://github.com/zk-org/zk);
-- si falta, los comandos avisan y no rompen nada.
local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "note" })
end

-- Directorio de notas: configurable en ~/.nvim-local.lua (notes.dir), default
-- ~/Notes (en $HOME, fuera del repo de config → a salvo de git clean/rebase).
local function notes_dir()
	local cfg = require("config.local_config").get("notes", {})
	local dir = (cfg.dir and cfg.dir ~= "") and cfg.dir or "~/Notes"
	dir = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/$", "")
	-- Guarda: nunca escribir notas dentro del repo de config (se perderían en un
	-- git clean/rebase). Si notes.dir apunta ahí, se rechaza con aviso.
	local config = vim.fn.fnamemodify(vim.fn.stdpath("config"), ":p"):gsub("/$", "")
	if dir == config or dir:sub(1, #config + 1) == config .. "/" then
		notify(
			"notes.dir está dentro del repo de config (" .. dir .. "); ajústalo en ~/.nvim-local.lua",
			vim.log.levels.ERROR
		)
		return nil
	end
	return dir
end

-- .zk/config.toml declarativo: nombre = fecha-slug, plantilla siembra "# Título".
local CONFIG_TOML = [[
[note]
filename = "{{format-date now '%Y-%m-%d'}}-{{slug title}}"
extension = "md"
template = "default.md"

[format.markdown]
hashtags = true
]]
local DEFAULT_TEMPLATE = "# {{title}}\n\n"

-- Crea <dir>/.zk/{config.toml,templates/default.md} si faltan. zk reconoce el
-- notebook por la presencia de .zk, así que no hace falta shell-out a `zk init`.
local function ensure_notebook()
	local dir = notes_dir()
	if not dir then
		return nil
	end
	local zkdir = dir .. "/.zk"
	vim.fn.mkdir(zkdir .. "/templates", "p")
	if vim.fn.filereadable(zkdir .. "/config.toml") ~= 1 then
		vim.fn.writefile(vim.split(CONFIG_TOML, "\n"), zkdir .. "/config.toml")
	end
	if vim.fn.filereadable(zkdir .. "/templates/default.md") ~= 1 then
		vim.fn.writefile(vim.split(DEFAULT_TEMPLATE, "\n"), zkdir .. "/templates/default.md")
	end
	return dir
end

local function has_zk()
	if vim.fn.executable("zk") ~= 1 then
		notify("CLI `zk` no encontrada en $PATH. Instálala: https://github.com/zk-org/zk", vim.log.levels.ERROR)
		return false
	end
	return true
end

local function create()
	if not has_zk() then
		return
	end
	local dir = ensure_notebook()
	if not dir then
		return
	end
	vim.ui.input({ prompt = "Título de la nota: " }, function(title)
		if title == nil then
			return -- cancelado con <Esc>
		end
		require("zk").new({ dir = dir, title = vim.trim(title) })
	end)
end

local function open()
	if not has_zk() then
		return
	end
	if not ensure_notebook() then
		return
	end
	-- ZK_NOTEBOOK_DIR (fijado en init) hace que el picker liste el directorio de notas.
	require("zk").edit({}, { title = "Notes" })
end

return {
	"zk-org/zk-nvim",
	main = "zk",
	cond = function()
		return not vim.g.vscode
	end,
	cmd = { "ZkNew", "ZkNotes", "Note" },
	keys = {
		{ "<leader>nn", create, desc = "New note" },
		{ "<leader>no", open, desc = "Open note" },
	},
	-- Fija el notebook por defecto en el arranque para que el picker/CLI siempre
	-- resuelvan el directorio de notas aunque el cwd sea otro. init corre en startup.
	init = function()
		if vim.g.vscode then
			return
		end
		local dir = notes_dir()
		if dir then
			vim.env.ZK_NOTEBOOK_DIR = dir
		end
	end,
	opts = { picker = "telescope" },
	config = function(_, opts)
		require("zk").setup(opts)
		local dispatch = { create = create, open = open }
		vim.api.nvim_create_user_command("Note", function(o)
			local sub = o.fargs[1] or "create"
			local handler = dispatch[sub]
			if not handler then
				notify("Subcomando desconocido '" .. sub .. "' (create|open)", vim.log.levels.WARN)
				return
			end
			handler()
		end, {
			nargs = "?",
			complete = function(lead)
				return vim.tbl_filter(function(c)
					return c:find(lead, 1, true) == 1
				end, { "create", "open" })
			end,
			desc = "Crear o abrir una nota markdown",
		})
	end,
}
