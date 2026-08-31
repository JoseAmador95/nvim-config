local M = {}

local scratch = require("repo_scratch")
local configured = false

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Scratch" })
end

local function state_root()
	return vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-config", "scratch")
end

local function git(root, arguments)
	return require("config.repo").git(root, arguments)
end

local function identity(root)
	local full_ref = git(root, { "symbolic-ref", "--quiet", "HEAD" })
	local legacy_ref
	if full_ref and vim.trim(full_ref) ~= "" then
		full_ref = vim.trim(full_ref)
		legacy_ref = full_ref:gsub("^refs/heads/", "")
	else
		full_ref = git(root, { "rev-parse", "HEAD" })
		if not full_ref or not vim.trim(full_ref):match("^[0-9a-f]+$") then
			return nil, "repository has no resolvable HEAD"
		end
		full_ref = vim.trim(full_ref)
		legacy_ref = "detached-" .. full_ref:sub(1, 12)
	end
	return {
		key = { repo_identity = root, ref = full_ref },
		label = legacy_ref,
		legacy_ids = { vim.fn.sha256(root .. "\0" .. legacy_ref) },
	}
end

local function loaded_scratch_paths()
	local result = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[buf].repo_scratch_handle then
			result[#result + 1] = vim.api.nvim_buf_get_name(buf)
		end
	end
	return result
end

local function buffer_content(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local function save(buf)
	local handle = vim.b[buf].repo_scratch_handle
	if not handle then
		return false
	end
	local updated, err = scratch.save(handle, buffer_content(buf))
	if not updated then
		local detail = type(err) == "table" and err.kind or tostring(err)
		notify("Could not save scratch: " .. detail, vim.log.levels.ERROR)
		return false
	end
	vim.b[buf].repo_scratch_handle = updated
	vim.bo[buf].modified = false
	return true
end

local function present(root, label, handle)
	local win = require("snacks").scratch.open({
		file = handle.path,
		name = "Scratch · " .. vim.fs.basename(root) .. " · " .. label,
		ft = "markdown",
		autowrite = false,
		win = { bo = { buftype = "acwrite", swapfile = false } },
	})
	if not win or not win.buf then
		scratch.release(handle)
		return nil
	end
	local buf = win.buf
	vim.b[buf].repo_scratch_handle = handle
	local group = vim.api.nvim_create_augroup("NvimConfigScratch" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			save(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufHidden", {
		group = group,
		buffer = buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				save(buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			scratch.release(vim.b[buf].repo_scratch_handle or handle)
		end,
	})
	return win
end

function M.open()
	local root, root_err = require("config.repo").current_root(0)
	if not root then
		notify(root_err, vim.log.levels.ERROR)
		return nil
	end
	local target, target_err = identity(root)
	if not target then
		notify(target_err, vim.log.levels.ERROR)
		return nil
	end
	local pruned, prune_err = scratch.prune(loaded_scratch_paths())
	if not pruned then
		notify(prune_err, vim.log.levels.ERROR)
		return nil
	end
	local handle, open_err = scratch.open({ key = target.key, legacy_ids = target.legacy_ids })
	if not handle then
		local detail = type(open_err) == "table" and open_err.kind or tostring(open_err)
		notify("Could not open scratch: " .. detail, vim.log.levels.ERROR)
		return nil
	end
	return present(root, target.label, handle)
end

function M.setup()
	if not configured then
		local ok, err = scratch.setup({ state_root = state_root() })
		if not ok then
			notify("Could not initialize scratch state: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		configured = true
	end
	vim.api.nvim_create_user_command("Scratch", M.open, { nargs = 0, desc = "Open the private repo/ref scratch" })
	vim.keymap.set("n", "<leader>.", M.open, { desc = "Project scratch" })
end

M._scratch = scratch
M._identity = identity
M._state_root = state_root

return M
