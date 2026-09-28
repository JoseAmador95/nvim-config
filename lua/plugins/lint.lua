-- Lint saved file buffers in the terminal editor. Pager and VSCode sessions do
-- not own file writes or diagnostics, so they intentionally skip this plugin.
local execution = require("config.execution")
local deferred = require("config.deferred")
local pager = require("config.pager")

local TITLE = "nvim-lint"
local MAX_MESSAGE_BYTES = 240
local WRAPPER_MARKER = "_nvim_config_verified_lint_v1"
local LINTERS = {
	hadolint = { tool = "hadolint", command = "hadolint" },
	["markdownlint-cli2"] = { tool = "markdownlint-cli2", command = "markdownlint-cli2" },
	shellcheck = { tool = "shellcheck", command = "shellcheck" },
}

local function bounded(message)
	return tostring(message or "lint failed"):gsub("[%c]", " "):sub(1, MAX_MESSAGE_BYTES)
end

local function notify(message, level)
	vim.notify(bounded(message), level or vim.log.levels.WARN, { title = TITLE })
end

local function exact_path(path, linter)
	if
		type(path) ~= "string"
		or path == ""
		or path:find("\0", 1, true)
		or path:sub(1, 1) ~= "/"
		or vim.fs.normalize(path) ~= path
	then
		return nil, ("verified resolution for linter '%s' did not return an exact absolute path"):format(linter)
	end
	return path
end

local function resolve_command(spec, linter, bufnr)
	local result = {
		pcall(execution.resolve, "lint-format", function()
			return deferred.load("config.tool_bootstrap").resolve(spec.tool, spec.command)
		end, { buf = bufnr }),
	}
	if not result[1] then
		error(("Cannot run linter '%s': authority resolution failed: %s"):format(linter, bounded(result[2])), 0)
	end
	local path, resolve_err = result[2], result[3]
	if not path then
		error(("Cannot run linter '%s': %s"):format(linter, bounded(resolve_err)), 0)
	end
	local resolved, path_err = exact_path(path, linter)
	if not resolved then
		error(path_err, 0)
	end
	return resolved
end

local function install_gate(lint)
	if lint[WRAPPER_MARKER] then
		return true
	end
	if type(lint.lint) ~= "function" then
		return nil, "nvim-lint does not expose its central lint API"
	end
	local original = lint.lint
	lint.lint = function(linter, opts)
		local ignore_errors = type(opts) == "table" and opts.ignore_errors == true
		local notified = false
		local function reject(message)
			message = bounded(message)
			if not ignore_errors and not notified then
				notified = true
				pcall(notify, message, vim.log.levels.WARN)
			end
			return nil, message
		end

		if type(linter) ~= "table" or type(linter.name) ~= "string" or not LINTERS[linter.name] then
			return reject("Linter is not manifest-backed: " .. bounded(type(linter) == "table" and linter.name or nil))
		end
		local copied, safe_linter = pcall(vim.deepcopy, linter)
		if not copied then
			return reject("Linter definition could not be copied: " .. bounded(safe_linter))
		end
		local copied_opts, safe_opts = pcall(vim.deepcopy, opts or {})
		if not copied_opts then
			return reject("Linter options could not be copied: " .. bounded(safe_opts))
		end

		local spec = LINTERS[linter.name]
		local bufnr = vim.api.nvim_get_current_buf()
		-- nvim-lint evaluates args before cmd, then passes cmd directly to
		-- uv.spawn. A command function is therefore its final synchronous seam:
		-- resolve and re-read authority after argument construction, immediately
		-- before the upstream runner spawns.
		safe_linter.cmd = function()
			return resolve_command(spec, linter.name, bufnr)
		end

		local returned = { pcall(original, safe_linter, safe_opts) }
		if not returned[1] then
			return reject(("Linter '%s' failed before spawn: %s"):format(linter.name, bounded(returned[2])))
		end
		return unpack(returned, 2)
	end
	lint[WRAPPER_MARKER] = true
	return true
end

local function configured_linters(lint, ft)
	local exact = lint.linters_by_ft[ft]
	if exact then
		return exact
	end

	local result = {}
	local seen = {}
	for _, component in ipairs(vim.split(ft, ".", { plain = true })) do
		for _, name in ipairs(lint.linters_by_ft[component] or {}) do
			if not seen[name] then
				seen[name] = true
				result[#result + 1] = name
			end
		end
	end
	return result
end

local function lint_buffer(lint, buf)
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
		return
	end
	local name = vim.api.nvim_buf_get_name(buf)
	if vim.bo[buf].buftype ~= "" or name == "" or vim.fn.filereadable(name) ~= 1 then
		return
	end

	local names = configured_linters(lint, vim.bo[buf].filetype)
	if #names > 0 then
		vim.api.nvim_buf_call(buf, function()
			lint.try_lint(names)
		end)
	end
end

return {
	"mfussenegger/nvim-lint",
	event = "BufWritePost",
	cond = function()
		return not vim.g.vscode and not pager.active
	end,
	config = function()
		if vim.g.vscode or pager.active then
			return
		end

		-- Lazy adds the plugin to runtimepath immediately before this callback;
		-- loading the optional upstream module earlier would defeat lazy-loading.
		local lint = require("lint")
		lint.linters_by_ft.dockerfile = { "hadolint" }
		lint.linters_by_ft.markdown = { "markdownlint-cli2" }
		lint.linters_by_ft.sh = { "shellcheck" }
		lint.linters_by_ft.bash = { "shellcheck" }
		local guarded, guard_err = install_gate(lint)
		assert(guarded, guard_err)

		vim.api.nvim_create_autocmd("BufWritePost", {
			group = vim.api.nvim_create_augroup("NvimLint", { clear = true }),
			callback = function(args)
				lint_buffer(lint, args.buf)
			end,
		})
	end,
}
