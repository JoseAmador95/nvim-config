vim.o.shadafile = "NONE"
vim.o.swapfile = false

local fixture_kind = assert(vim.env.NVIM_DAP_FIXTURE, "NVIM_DAP_FIXTURE is required")
assert(fixture_kind == "python" or fixture_kind == "cpp", "unsupported DAP fixture: " .. fixture_kind)

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.uv.fs_realpath(root) or root
local source_path = root .. (fixture_kind == "python" and "/fixture.py" or "/fixture.cpp")
local source_lines = fixture_kind == "python"
		and {
			"def answer():",
			"    value = 42",
			"    return value",
			"",
			"print(answer())",
		}
	or {
		"int answer() {",
		"  int value = 42;",
		"  return value;",
		"}",
		"int main() { return answer() == 42 ? 0 : 1; }",
	}
assert(vim.fn.writefile(source_lines, source_path) == 0)

local function fail(message)
	vim.fn.delete(root, "rf")
	vim.api.nvim_err_writeln("dap_session_spec (" .. fixture_kind .. "): " .. message)
	vim.cmd("cquit")
end

local function wait_for(predicate, message)
	assert(vim.wait(5000, predicate, 20), message)
end

local function buffer_text(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function find_buffer(filetype)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == filetype then
			return bufnr
		end
	end
end

local function spawn_server()
	local rpc = require("dap.rpc")
	local server = assert(vim.uv.new_tcp())
	assert(server:bind("127.0.0.1", 0))

	local client = { seq = 0 }
	local function send(payload)
		client.seq = client.seq + 1
		payload.seq = client.seq
		client.socket:write(rpc.msg_with_content_length(vim.json.encode(payload)))
	end
	local function respond(request, body)
		send({
			type = "response",
			request_seq = request.seq,
			command = request.command,
			success = true,
			body = body or {},
		})
	end
	local function event(name, body)
		send({ type = "event", event = name, body = body or {} })
	end

	local handlers = {}
	handlers.initialize = function(request)
		respond(request, {
			supportsConfigurationDoneRequest = true,
			supportsTerminateRequest = true,
			supportsEvaluateForHovers = true,
		})
	end
	handlers.launch = function(request)
		respond(request)
		event("initialized")
	end
	handlers.setBreakpoints = function(request)
		local breakpoints = {}
		for index, breakpoint in ipairs(request.arguments.breakpoints or {}) do
			breakpoints[index] = {
				id = index,
				verified = true,
				line = breakpoint.line,
				source = request.arguments.source,
			}
		end
		respond(request, { breakpoints = breakpoints })
	end
	handlers.setFunctionBreakpoints = respond
	handlers.setInstructionBreakpoints = respond
	handlers.setExceptionBreakpoints = respond
	handlers.configurationDone = function(request)
		respond(request)
		vim.schedule(function()
			event("stopped", { reason = "breakpoint", threadId = 1, allThreadsStopped = true })
		end)
	end
	handlers.threads = function(request)
		respond(request, { threads = { { id = 1, name = fixture_kind .. " fixture" } } })
	end
	handlers.stackTrace = function(request)
		respond(request, {
			stackFrames = {
				{
					id = 11,
					name = "answer",
					line = 2,
					column = 1,
					source = { name = vim.fs.basename(source_path), path = source_path },
				},
			},
			totalFrames = 1,
		})
	end
	handlers.scopes = function(request)
		respond(request, {
			scopes = { { name = "Locals", variablesReference = 100, expensive = false } },
		})
	end
	handlers.variables = function(request)
		respond(request, {
			variables = {
				{ name = "value", value = "42", type = "integer", evaluateName = "value", variablesReference = 0 },
			},
		})
	end
	handlers.evaluate = function(request)
		respond(request, { result = "42", type = "integer", variablesReference = 0 })
	end
	handlers.terminate = function(request)
		respond(request)
	end
	handlers.disconnect = function(request)
		respond(request)
		event("terminated")
	end

	server:listen(1, function(err)
		assert(not err, err)
		local socket = assert(vim.uv.new_tcp())
		client.socket = socket
		server:accept(socket)
		socket:read_start(rpc.create_read_loop(function(body)
			local request = vim.json.decode(body)
			if request.type == "request" then
				local handler = handlers[request.command]
				assert(handler, "fake adapter has no handler for " .. request.command)
				handler(request)
			end
		end, function() end))
	end)

	return {
		adapter = {
			type = "server",
			host = "127.0.0.1",
			port = server:getsockname().port,
			options = { disconnect_timeout_sec = 0.1 },
		},
		close = function()
			if client.socket and not client.socket:is_closing() then
				client.socket:read_stop()
				client.socket:close()
			end
			if not server:is_closing() then
				server:close()
			end
		end,
	}
end

vim.api.nvim_create_autocmd("VimEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			local server
			local ok, err = xpcall(function()
				assert(vim.env.NVIM_DAP_UI == "dap-view", "fixture must exercise dap-view")
				package.loaded["config.workflow_execution"] = {
					grant = function(capability)
						assert(capability == "debug")
						return true, { runtime = "host" }
					end,
					tool = function()
						error("fixture adapters must replace managed adapters before execution")
					end,
					notify = function() end,
				}
				require("lazy").load({ plugins = { "nvim-dap" } })
				local dap = require("dap")
				local dap_view = require("dap-view")
				local state = require("dap-view.state")

				vim.cmd.tabedit(source_path)
				local source_tab = vim.api.nvim_get_current_tabpage()
				vim.cmd.tabnew()
				local debug_tab = vim.api.nvim_get_current_tabpage()

				server = spawn_server()
				local adapter_name = fixture_kind == "python" and "python" or "codelldb"
				dap.adapters[adapter_name] = server.adapter

				local stopped = false
				dap.listeners.after.event_stopped.nvim_config_fixture = function()
					stopped = true
				end
				dap.run({
					name = fixture_kind .. " UI fixture",
					type = adapter_name,
					request = "launch",
					program = source_path,
					cwd = root,
				}, { filetype = fixture_kind })

				wait_for(function()
					return stopped and dap.session() and dap.session().current_frame ~= nil
				end, "debug session did not stop on a frame")
				assert(state.winnr and vim.api.nvim_win_is_valid(state.winnr), "dap-view did not auto-open")

				dap_view.show_view("scopes")
				wait_for(function()
					return buffer_text(state.bufnr):find("value = 42", 1, true) ~= nil
				end, "scopes did not render the fixture variable")

				dap_view.add_expr("value", false)
				dap_view.show_view("watches")
				wait_for(function()
					local text = buffer_text(state.bufnr)
					return text:find("value", 1, true) and text:find("42", 1, true)
				end, "watch expression did not evaluate")

				dap_view.show_view("repl")
				dap.repl.execute("value")
				wait_for(function()
					local repl_buf = find_buffer("dap-repl")
					return buffer_text(repl_buf):find("42", 1, true) ~= nil
				end, "REPL did not display the evaluation result")

				dap_view.show_view("console")
				assert(state.current_section == "console", "console view is not available")

				vim.api.nvim_set_current_tabpage(debug_tab)
				dap_view.show_view("threads")
				wait_for(function()
					return next(state.frames_by_line) ~= nil
				end, "threads view did not render a stack frame")
				local frame_line = assert(next(state.frames_by_line))
				vim.api.nvim_set_current_win(state.winnr)
				vim.api.nvim_win_set_cursor(state.winnr, { frame_line, 0 })
				require("dap-view.threads.actions").jump_and_set_frame(frame_line)
				assert(
					vim.api.nvim_get_current_tabpage() == source_tab,
					"frame navigation did not reuse the source tab"
				)
				assert(vim.api.nvim_buf_get_name(0) == source_path, "frame navigation opened the wrong source")
				assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "frame navigation opened the wrong line")

				dap.terminate()
				wait_for(function()
					return not state.winnr or not vim.api.nvim_win_is_valid(state.winnr)
				end, "dap-view did not auto-close after termination")
				wait_for(function()
					return dap.session() == nil
				end, "debug session did not terminate")
			end, debug.traceback)

			if server then
				server.close()
			end
			if not ok then
				fail(err)
				return
			end

			vim.fn.delete(root, "rf")
			print("dap_session_spec: " .. fixture_kind .. " fixture passed")
			vim.cmd("quitall!")
		end)
	end,
})
