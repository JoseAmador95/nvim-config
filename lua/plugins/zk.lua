-- Quick markdown notes in ~/Notes (configurable) via the `zk` CLI.
-- Independent of the obsidian vaults: it only creates/opens notes in a common
-- directory. Requires the `zk` binary on $PATH (https://github.com/zk-org/zk);
-- if it is missing, the commands warn and nothing breaks.
local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "note" })
end

-- Notes directory: configurable in ~/.nvim-local.lua (notes.dir), default
-- ~/Notes (in $HOME, outside the config repo -> safe from git clean/rebase).
local function notes_dir()
	local cfg = require("config.local_config").get("notes", {})
	local dir = (cfg.dir and cfg.dir ~= "") and cfg.dir or "~/Notes"
	dir = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("/$", "")
	-- Guard: never write notes inside the config repo (they would be lost on a
	-- git clean/rebase). If notes.dir points there, reject it with a warning.
	local config = vim.fn.fnamemodify(vim.fn.stdpath("config"), ":p"):gsub("/$", "")
	if dir == config or dir:sub(1, #config + 1) == config .. "/" then
		notify(
			"notes.dir is inside the config repo (" .. dir .. "); set it in ~/.nvim-local.lua",
			vim.log.levels.ERROR
		)
		return nil
	end
	return dir
end

-- Declarative .zk/config.toml: filename = date-slug, template seeds "# Title".
local CONFIG_TOML = [[
[note]
filename = "{{format-date now '%Y-%m-%d'}}-{{slug title}}"
extension = "md"
template = "default.md"

[format.markdown]
hashtags = true
]]
local DEFAULT_TEMPLATE = "# {{title}}\n\n"

-- Create <dir>/.zk/{config.toml,templates/default.md} if missing. zk recognizes
-- the notebook by the presence of .zk, so there is no need to shell out to `zk init`.
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
		notify("`zk` CLI not found on $PATH. Install it: https://github.com/zk-org/zk", vim.log.levels.ERROR)
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
	vim.ui.input({ prompt = "Note title: " }, function(title)
		if title == nil then
			return -- cancelled with <Esc>
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
	-- ZK_NOTEBOOK_DIR (set in init) makes the picker list the notes directory.
	require("zk").edit({}, { title = "Notes" })
end

-- Path of the current note's file, only if it is inside the notes directory
-- (a guard so rename/delete cannot touch unrelated files by accident). Returns
-- nil with a warning otherwise.
local function current_note_path()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" then
		notify("The current buffer is not a file", vim.log.levels.WARN)
		return nil
	end
	file = vim.fn.fnamemodify(file, ":p")
	local dir = notes_dir()
	if not dir then
		return nil
	end
	if file:sub(1, #dir + 1) ~= dir .. "/" then
		notify("The current note is not in the notes directory (" .. dir .. ")", vim.log.levels.WARN)
		return nil
	end
	return file
end

-- Rename the current note's file. Does not rewrite backlinks (zk has no such
-- support); it is a plain filesystem operation.
local function rename()
	local path = current_note_path()
	if not path then
		return
	end
	local dir = vim.fn.fnamemodify(path, ":h")
	local old = vim.fn.fnamemodify(path, ":t")
	vim.ui.input({ prompt = "New name: ", default = old }, function(input)
		if input == nil then
			return -- cancelled with <Esc>
		end
		input = vim.trim(input)
		if input == "" or input == old then
			return
		end
		if not input:match("%.md$") then
			input = input .. ".md"
		end
		local target = dir .. "/" .. input
		if vim.fn.filereadable(target) == 1 then
			notify("Already exists: " .. input, vim.log.levels.ERROR)
			return
		end
		if vim.bo.modified then
			vim.cmd("write")
		end
		local ok, err = os.rename(path, target)
		if not ok then
			notify("Could not rename: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		local oldbuf = vim.api.nvim_get_current_buf()
		vim.cmd.edit(vim.fn.fnameescape(target))
		pcall(vim.api.nvim_buf_delete, oldbuf, { force = true })
		notify("Renamed to " .. input)
	end)
end

-- Delete the current note's file (with confirmation) and wipe the buffer.
local function delete()
	local path = current_note_path()
	if not path then
		return
	end
	local name = vim.fn.fnamemodify(path, ":t")
	if vim.fn.confirm("Delete note '" .. name .. "'?", "&Yes\n&No", 2) ~= 1 then
		return
	end
	local ok, err = os.remove(path)
	if not ok then
		notify("Could not delete: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	pcall(vim.api.nvim_buf_delete, 0, { force = true })
	notify("Deleted " .. name)
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
		{ "<leader>nr", rename, desc = "Rename note" },
		{ "<leader>nd", delete, desc = "Delete note" },
	},
	-- Set the default notebook at startup so the picker/CLI always resolve the
	-- notes directory even when the cwd is elsewhere. init runs on startup.
	init = function()
		if vim.g.vscode then
			return
		end
		local dir = notes_dir()
		if dir then
			vim.env.ZK_NOTEBOOK_DIR = dir
		end
	end,
	opts = { picker = "snacks_picker" },
	config = function(_, opts)
		require("zk").setup(opts)
		local dispatch = { create = create, open = open, rename = rename, delete = delete }
		vim.api.nvim_create_user_command("Note", function(o)
			local sub = o.fargs[1] or "create"
			local handler = dispatch[sub]
			if not handler then
				notify("Unknown subcommand '" .. sub .. "' (create|open|rename|delete)", vim.log.levels.WARN)
				return
			end
			handler()
		end, {
			nargs = "?",
			complete = function(lead)
				return vim.tbl_filter(function(c)
					return c:find(lead, 1, true) == 1
				end, { "create", "open", "rename", "delete" })
			end,
			desc = "Create, open, rename or delete a markdown note",
		})
	end,
}
