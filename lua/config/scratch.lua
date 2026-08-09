local M = {}

local MAX_AGE_SECONDS = 30 * 24 * 60 * 60

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Scratch" })
end

local function root_directory()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "scratch")
end

local function ensure_private_directory()
	local state = vim.fn.stdpath("state")
	local parent = vim.fs.joinpath(state, "nvim-config")
	local root = root_directory()
	for _, path in ipairs({ parent, root }) do
		local lstat = vim.uv.fs_lstat(path)
		if lstat and lstat.type == "link" then
			return nil, "refusing symlinked private directory: " .. path
		end
		if lstat and lstat.type ~= "directory" then
			return nil, "private state path is not a directory: " .. path
		end
		if not lstat and vim.fn.mkdir(path, "p", tonumber("700", 8)) == 0 then
			return nil, "could not create private directory: " .. path
		end
		local ok, err = vim.uv.fs_chmod(path, tonumber("700", 8))
		if not ok then
			return nil, "could not secure private directory: " .. tostring(err)
		end
	end
	return root
end

local function loaded_files()
	local files = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" then
			files[vim.fs.normalize(name)] = true
		end
	end
	return files
end

local function private_file(path, label)
	local stat = vim.uv.fs_lstat(path)
	if not stat then
		return true
	end
	if stat.type == "link" then
		return nil, "refusing symlinked " .. label .. ": " .. path
	end
	if stat.type ~= "file" then
		return nil, label .. " is not a regular file: " .. path
	end
	return true
end

local function prune(root, preserve)
	local open = loaded_files()
	local cutoff = os.time() - MAX_AGE_SECONDS
	for name, kind in vim.fs.dir(root) do
		local path = vim.fs.joinpath(root, name)
		if kind == "file" then
			pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
			local stat = vim.uv.fs_stat(path)
			if
				name ~= ".version"
				and path ~= preserve
				and stat
				and stat.mtime.sec < cutoff
				and not open[vim.fs.normalize(path)]
			then
				pcall(vim.uv.fs_unlink, path)
				pcall(vim.uv.fs_unlink, path .. ".meta")
			end
		elseif kind == "directory" then
			pcall(vim.uv.fs_chmod, path, tonumber("700", 8))
		elseif kind == "link" then
			return nil, "refusing symlinked scratch state: " .. path
		end
	end
	return true
end

local function branch(root)
	local value = require("config.repo").git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
	if value and vim.trim(value) ~= "" then
		return vim.trim(value)
	end
	value = require("config.repo").git(root, { "rev-parse", "--short=12", "HEAD" })
	return value and ("detached-" .. vim.trim(value)) or "no-head"
end

local function write_buffer(buf, path)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local data = table.concat(lines, "\n") .. "\n"
	local ok, err = require("config.fs").write_binary_atomic(path, data)
	if not ok then
		notify("Could not save scratch: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
	vim.bo[buf].modified = false
	return true
end

function M.open()
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		notify(root_err, vim.log.levels.ERROR)
		return
	end
	local directory, directory_err = ensure_private_directory()
	if not directory then
		notify(directory_err, vim.log.levels.ERROR)
		return
	end
	local version = vim.fs.joinpath(directory, ".version")
	local version_ok, version_err = private_file(version, "scratch state version")
	if not version_ok then
		notify(version_err, vim.log.levels.ERROR)
		return
	end
	if not vim.uv.fs_lstat(version) then
		local ok, err = require("config.fs").write_binary_atomic(version, "1\n")
		if not ok then
			notify("Could not initialize scratch state: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
	end
	local branch_name = branch(root)
	local id = vim.fn.sha256(root .. "\0" .. branch_name)
	local path = vim.fs.joinpath(directory, id .. ".md")
	local path_ok, path_err = private_file(path, "scratch file")
	if not path_ok then
		notify(path_err, vim.log.levels.ERROR)
		return
	end
	local pruned, prune_err = prune(directory, path)
	if not pruned then
		notify(prune_err, vim.log.levels.ERROR)
		return
	end
	if not vim.uv.fs_lstat(path) then
		local ok, err = require("config.fs").write_binary_atomic(path, "")
		if not ok then
			notify("Could not create scratch: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
	end
	pcall(vim.uv.fs_chmod, path, tonumber("600", 8))
	local now = os.time()
	pcall(vim.uv.fs_utime, path, now, now)
	local win = require("snacks").scratch.open({
		file = path,
		name = "Scratch · " .. vim.fs.basename(root) .. " · " .. branch_name,
		ft = "markdown",
		autowrite = false,
		win = { bo = { buftype = "acwrite", swapfile = false } },
	})
	if not win or not win.buf then
		return
	end
	local buf = win.buf
	local group = vim.api.nvim_create_augroup("NvimConfigScratch" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			write_buffer(buf, path)
		end,
	})
	vim.api.nvim_create_autocmd("BufHidden", {
		group = group,
		buffer = buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				write_buffer(buf, path)
			end
		end,
	})
	return win
end

function M.setup()
	vim.api.nvim_create_user_command("Scratch", M.open, { nargs = 0, desc = "Open the private repo/branch scratch" })
	vim.keymap.set("n", "<leader>.", M.open, { desc = "Project scratch" })
end

M._prune = prune
M._root_directory = root_directory
M._private_file = private_file

return M
