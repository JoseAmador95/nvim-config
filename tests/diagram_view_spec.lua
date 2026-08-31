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
	get = function(_, fallback)
		return fallback
	end,
}
package.loaded["config.pager"] = { active = false }

test("host owns commands, keymaps, renderer commands, and presenters", function()
	local jobs = {}
	local adapter = require("config.diagram")
	assert(adapter.setup({
		cache_root = cache_root(),
		spawn = function(argv, options, callback)
			jobs[#jobs + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
			callback({ code = 0, stdout = "ASCII", stderr = "" })
			return { kill = function() end }
		end,
		schedule = function(callback)
			callback()
		end,
		notify = function() end,
	}))

	equal(2, vim.fn.exists(":DiagramShow"), "host command is missing")
	local status = require("diagram_view").status()
	equal({ "mermaid:ascii", "mermaid:svg", "plantuml:ascii", "plantuml:svg" }, status.renderers)
	equal({ "ascii", "image" }, status.presenters)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
	local mapping = vim.fn.maparg("<leader>md", "n", false, true)
	vim.api.nvim_set_current_buf(buf)
	mapping = vim.fn.maparg("<leader>md", "n", false, true)
	assert(not vim.tbl_isempty(mapping), "host markdown mapping is missing")

	local delivery = {}
	assert(require("diagram_view").register_presenter("capture", {
		open = function()
			return {}
		end,
		deliver = function(_, result)
			delivery.result = result.data
		end,
	}))
	local session = assert(require("diagram_view").open({
		renderer = "plantuml:ascii",
		presenter = "capture",
		kind = "plantuml",
		source = "@startuml\nA -> B\n@enduml",
	}))
	equal({ "plantuml", "-ttxt", "-pipe" }, jobs[1].argv)
	equal("SANDBOX", jobs[1].options.env.PLANTUML_SECURITY_PROFILE)
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
