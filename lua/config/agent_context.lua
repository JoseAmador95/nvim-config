-- Explicit, size-bounded context transfer to an agent through OSC52.
local M = {}

local MAX_BYTES = 1024 * 1024

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Agent context" })
end

local function severity_name(value)
	local name = vim.diagnostic.severity[value]
	return type(name) == "string" and name:lower() or "unknown"
end

local function collect_diagnostics(buf, get_diagnostics)
	local values = {}
	for _, diagnostic in ipairs(get_diagnostics(buf)) do
		local item = {
			start = { line = diagnostic.lnum + 1, column = diagnostic.col + 1 },
			["end"] = {
				line = (diagnostic.end_lnum or diagnostic.lnum) + 1,
				column = (diagnostic.end_col or diagnostic.col) + 1,
			},
			severity = severity_name(diagnostic.severity),
			message = diagnostic.message,
		}
		if diagnostic.source and diagnostic.source ~= "" then
			item.source = diagnostic.source
		end
		if diagnostic.code ~= nil then
			item.code = tostring(diagnostic.code)
		end
		values[#values + 1] = item
	end
	return values
end

local function run_git(root, arguments, runner)
	local output, err = require("config.repo").git(root, arguments, runner)
	if not output then
		return nil, err
	end
	return output
end

local function git_context(root, runner)
	local staged, staged_err = run_git(root, { "diff", "--cached", "--no-ext-diff", "--no-textconv", "--" }, runner)
	if not staged then
		return nil, "could not read staged diff: " .. staged_err
	end
	local unstaged, unstaged_err = run_git(root, { "diff", "--no-ext-diff", "--no-textconv", "--" }, runner)
	if not unstaged then
		return nil, "could not read unstaged diff: " .. unstaged_err
	end
	local untracked_output, untracked_err =
		run_git(root, { "ls-files", "--others", "--exclude-standard", "-z" }, runner)
	if not untracked_output then
		return nil, "could not read untracked files: " .. untracked_err
	end
	local untracked = vim.split(untracked_output, "\0", { plain = true, trimempty = true })
	return { staged_diff = staged, unstaged_diff = unstaged, untracked = untracked }
end

function M.collect(options, dependencies)
	local opts = options or {}
	local deps = dependencies or {}
	local buf = opts.buf or vim.api.nvim_get_current_buf()
	local root, root_err = (deps.current_root or require("config.repo").current_root)(buf, deps.git)
	if not root then
		return nil, root_err
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local path, path_err = require("config.repo").relative_existing(root, name)
	if not path then
		return nil, path_err
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local first = math.max(1, math.min(tonumber(opts.line1) or 1, line_count))
	local last = math.max(first, math.min(tonumber(opts.line2) or first, line_count))
	local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
	local final_line = lines[#lines] or ""
	local payload = {
		version = 1,
		repo_root = root,
		path = path,
		range = {
			start = { line = first, column = 1 },
			["end"] = { line = last, column = #final_line + 1 },
		},
		selection = table.concat(lines, "\n"),
		diagnostics = collect_diagnostics(buf, deps.get_diagnostics or vim.diagnostic.get),
	}
	local symbol = deps.symbol and deps.symbol() or vim.fn.expand("<cword>")
	if type(symbol) == "string" and symbol ~= "" then
		payload.symbol = symbol
	end
	if opts.bang then
		local git, git_err = git_context(root, deps.git)
		if not git then
			return nil, git_err
		end
		payload.git = git
	end
	return payload
end

function M.encode(payload)
	local ok, encoded = pcall(vim.json.encode, payload)
	if not ok then
		return nil, "could not encode UTF-8 JSON: " .. tostring(encoded)
	end
	if not pcall(vim.str_utfindex, encoded) then
		return nil, "context is not valid UTF-8"
	end
	if #encoded > MAX_BYTES then
		return nil, string.format("context is %d bytes; maximum is %d", #encoded, MAX_BYTES)
	end
	return encoded
end

function M.emit(options, dependencies)
	local deps = dependencies or {}
	local report = deps.notify or notify
	local payload, collect_err = M.collect(options, deps)
	if not payload then
		report("Could not copy context: " .. collect_err, vim.log.levels.ERROR)
		return nil
	end
	local encoded, encode_err = M.encode(payload)
	if not encoded then
		report("Could not copy context: " .. encode_err, vim.log.levels.ERROR)
		return nil
	end
	local copy = deps.copy or require("vim.ui.clipboard.osc52").copy("+")
	local ok, copy_err = pcall(copy, { encoded }, "v")
	if not ok then
		report("OSC52 copy failed: " .. tostring(copy_err), vim.log.levels.ERROR)
		return nil
	end
	report(string.format("Copied %d bytes through OSC52", #encoded), vim.log.levels.INFO)
	return encoded
end

function M.setup()
	vim.api.nvim_create_user_command("AgentContext", function(opts)
		M.emit({ bang = opts.bang, line1 = opts.line1, line2 = opts.line2 })
	end, {
		bang = true,
		range = true,
		desc = "Copy current file context through OSC52 (! includes Git diffs)",
	})
end

M.max_bytes = MAX_BYTES

return M
