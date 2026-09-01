vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
local plugin = repo .. "/local-plugins/diagram-view.nvim"
vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:prepend(plugin)
package.path = table.concat({
	plugin .. "/lua/?.lua",
	plugin .. "/lua/?/init.lua",
	repo .. "/lua/?.lua",
	repo .. "/lua/?/init.lua",
	package.path,
}, ";")

local failures = {}
local count = 0
local temporary = {}

local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			(message or "values differ")
				.. "\nexpected: "
				.. vim.inspect(expected)
				.. "\nactual: "
				.. vim.inspect(actual)
		)
	end
end

local function test(name, callback)
	count = count + 1
	local ok, err = xpcall(callback, debug.traceback)
	if ok then
		print("ok - " .. name)
	else
		failures[#failures + 1] = name .. "\n" .. err
	end
end

local function cache_root()
	local parent = vim.fn.tempname()
	assert(vim.fn.mkdir(parent, "p") == 1)
	temporary[#temporary + 1] = parent
	return parent .. "/diagram-v3"
end

package.loaded["config.local_config"] = {
	plugin = function(_, fallback)
		return fallback
	end,
}
package.loaded["config.pager"] = { active = false }

test("host owns commands, keymaps, renderer commands, and presenters", function()
	local jobs_a = {}
	local jobs_b = {}
	local pending_killed = false
	local function spawn_into(jobs)
		return function(argv, options, callback)
			jobs[#jobs + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
			if not tostring(options.stdin):find("PENDING", 1, true) then
				callback({ code = 0, stdout = "ASCII", stderr = "" })
			end
			return {
				kill = function()
					pending_killed = true
				end,
			}
		end
	end
	local adapter = require("config.diagram")
	assert(package.loaded.diagram_view == nil, "host adapter loaded diagram-view before setup")
	assert(adapter.setup({
		cache_root = cache_root(),
		spawn = spawn_into(jobs_a),
		schedule = function(callback)
			callback()
		end,
		notify = function() end,
	}))

	equal(2, vim.fn.exists(":DiagramShow"), "host command is missing")
	assert(package.loaded.diagram_view == nil, "host registration initialized diagram-view")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
	local mapping = vim.fn.maparg("<leader>md", "n", false, true)
	vim.api.nvim_set_current_buf(buf)
	mapping = vim.fn.maparg("<leader>md", "n", false, true)
	assert(not vim.tbl_isempty(mapping), "host markdown mapping is missing")
	local visual_mapping = vim.fn.maparg("<leader>md", "x", false, true)
	assert(not vim.tbl_isempty(visual_mapping), "host visual diagram mapping is missing")
	assert(visual_mapping.rhs:find("'<,'>DiagramShow", 1, true), "visual mapping did not preserve its range")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ignored", "A --> B", "B --> C", "ignored" })
	local original_executable = vim.fn.executable
	vim.fn.executable = function()
		return 1
	end
	local command_ok, command_err = pcall(vim.cmd, "2,3DiagramShow ascii")
	vim.fn.executable = original_executable
	assert(command_ok, command_err)
	equal("A --> B\nB --> C", jobs_a[#jobs_a].options.stdin, "visual command did not pass the selected lines")
	assert(package.loaded.diagram_view ~= nil, "first DiagramShow did not initialize diagram-view")
	local core = require("diagram_view")
	local status = core.status()
	equal({ "mermaid:ascii", "mermaid:svg", "plantuml:ascii", "plantuml:svg" }, status.renderers)
	equal({ "ascii", "image" }, status.presenters)
	assert(core.register_presenter("pending", {
		open = function()
			return {}
		end,
		deliver = function() end,
	}))
	assert(core.open({
		renderer = "plantuml:ascii",
		presenter = "pending",
		kind = "plantuml",
		source = "@startuml\nPENDING -> B\n@enduml",
	}))
	assert(adapter.setup({
		cache_root = cache_root(),
		spawn = spawn_into(jobs_b),
		schedule = function(callback)
			callback()
		end,
		notify = function() end,
	}))
	assert(pending_killed, "second host setup did not let the core cancel its active session")
	vim.fn.executable = function()
		return 1
	end
	local second_ok, second_err = pcall(vim.cmd, "2,3DiagramShow ascii")
	vim.fn.executable = original_executable
	assert(second_ok, second_err)
	equal("A --> B\nB --> C", jobs_b[#jobs_b].options.stdin, "second use did not receive setup B")

	local delivery = {}
	assert(core.register_presenter("capture", {
		open = function()
			return {}
		end,
		deliver = function(_, result)
			delivery.result = result.data
		end,
	}))
	local session = assert(core.open({
		renderer = "plantuml:ascii",
		presenter = "capture",
		kind = "plantuml",
		source = "@startuml\nA -> B\n@enduml",
	}))
	equal({ "plantuml", "-ttxt", "-pipe" }, jobs_b[#jobs_b].argv)
	equal("SANDBOX", jobs_b[#jobs_b].options.env.PLANTUML_SECURITY_PROFILE)
	equal("ASCII", delivery.result)
	equal("presented", session:status().state)
end)

test("local plugin contains no host imports, global commands, or mappings", function()
	local files = vim.fn.glob(plugin .. "/lua/**/*.lua", false, true)
	assert(#files > 0)
	for _, path in ipairs(files) do
		local contents = table.concat(vim.fn.readfile(path), "\n")
		assert(not contents:match([[require%s*%(%s*["']config%.]]), path .. " imports config.*")
		assert(not contents:find("nvim_create_user_command", 1, true), path .. " creates a global command")
		assert(not contents:find("vim.keymap.set", 1, true), path .. " creates a mapping")
	end
	local host = table.concat(vim.fn.readfile(repo .. "/lua/config/diagram.lua"), "\n")
	assert(host:find("nvim_create_user_command", 1, true), "command did not remain in the host adapter")
	assert(host:find("vim.keymap.set", 1, true), "mappings did not remain in the host adapter")
	assert(host:find("Snacks.image.placement.new", 1, true), "Snacks presenter did not remain in the host adapter")
end)

for _, path in ipairs(temporary) do
	vim.fn.delete(path, "rf")
end

if #failures > 0 then
	for _, failure in ipairs(failures) do
		vim.api.nvim_err_writeln(failure)
	end
	vim.cmd("cquit")
end

print(("diagram_view_spec: %d host contract tests passed"):format(count))
vim.cmd("quitall!")
