vim.o.shadafile = "NONE"
vim.o.swapfile = false

local repo = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo)
package.path = table.concat({ repo .. "/lua/?.lua", repo .. "/lua/?/init.lua", package.path }, ";")

local failures = {}
local count = 0
local function equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(string.format("%s\nexpected: %s\nactual:   %s", message, vim.inspect(expected), vim.inspect(actual)))
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

local adapter = require("config.review_tuicr")
local launcher = vim.fn.expand("~/.config/tuicr/tuicr-round")
local root = "/tmp/review-tuicr-repository"
local round_id = "12345678-1234-4abc-8def-1234567890ab"

local function success(value)
	return { code = 0, stdout = vim.json.encode(value) .. "\n", stderr = "" }
end

local function status(rounds, repo_root)
	return success({
		ok = true,
		command = "status",
		repo_root = repo_root or root,
		rounds = rounds or {
			{ ok = true, command = "status", round = round_id, repo_root = root, session = "fixture/worktree" },
		},
	})
end

local function fake_client(results, options)
	local calls = {}
	local index = 0
	options = options or {}
	local client = adapter.new({
		system = function(command, system_options, callback)
			index = index + 1
			calls[index] = vim.deepcopy(command)
			equal({ text = true }, system_options, "vim.system options changed")
			local result = assert(results[index], "missing fake result for " .. vim.inspect(command))
			callback(result)
			return { fake = true }
		end,
		schedule = function(callback)
			callback()
		end,
		canonical_root = function(value)
			assert(value == (options.input_root or root))
			return root
		end,
		author = options.author or "Configured Reviewer",
	})
	return client, calls
end

local function capture(invoke)
	local called = 0
	local value
	local err
	invoke(function(result, result_err)
		called = called + 1
		value = result
		err = result_err
	end)
	assert(called == 1, "callback count was " .. called)
	return value, err
end

test("list_rounds uses only the public all-round launcher contract and returns picker metadata", function()
	local metadata = {
		{ ok = true, command = "status", round = round_id, repo_root = root, session = "fixture/worktree" },
		{
			ok = true,
			command = "status",
			round = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
			repo_root = root,
			session = "fixture/commit",
		},
	}
	local client, calls = fake_client({ status(metadata) })
	local value, err = capture(function(callback)
		client.list_rounds(root, callback)
	end)
	assert(not err)
	equal(metadata, value, "picker metadata changed")
	equal({ launcher, "status", "--repo", root, "--all" }, calls[1], "round discovery argv changed")
end)

test("comments verifies the selected round through status before reading normalized comments", function()
	local comments = {
		ok = true,
		command = "comments",
		round = round_id,
		repo_root = root,
		comments = { { id = "native-1", comment_type = "question", message = "Why?" } },
		threads = {},
		snapshot = { branch = "main" },
	}
	local client, calls = fake_client({ status(), success(comments) })
	local value, err = capture(function(callback)
		client.comments(root, round_id, callback)
	end)
	assert(not err)
	equal(comments, value, "comment payload changed")
	equal({ launcher, "status", "--repo", root, "--all" }, calls[1], "comments skipped round discovery")
	equal({ launcher, "comments", "--round", round_id }, calls[2], "comments argv changed")
end)

test("add maps all six store types to compatible severities and native comment types", function()
	local mappings = {
		issue = "blocker",
		suggestion = "warning",
		rationale = "warning",
		question = "warning",
		pedantic = "nit",
		praise = "nit",
	}
	for comment_type, severity in pairs(mappings) do
		local result = success({
			ok = true,
			command = "add",
			round = round_id,
			tuicr = { id = "created" },
		})
		local client, calls = fake_client({ status(), result })
		local value, err = capture(function(callback)
			client.add(root, round_id, {
				type = comment_type,
				body = "Review body",
				delivery_key = "native-item",
				author = "Exact Author",
				anchor = { path = "lua//config/example.lua", side = "left", start_line = 3, end_line = 5 },
			}, callback)
		end)
		assert(value and value.id == "created" and not err)
		equal({
			launcher,
			"add",
			"--round",
			round_id,
			"--author=Exact Author",
			"--severity=" .. severity,
			"--comment-type=" .. comment_type,
			"--delivery-key=native-item",
			"--path=lua/config/example.lua",
			"--start=3",
			"--end=5",
			"--side=old",
			"--",
			"Review body",
		}, calls[2], "add argv changed for " .. comment_type)
	end
end)

test("respond requires reply_to, maps right to new, and uses the injected default author", function()
	local client, calls = fake_client({
		status(),
		success({
			ok = true,
			command = "respond",
			round = round_id,
			tuicr = { id = "reply" },
		}),
	}, { author = "Default Reviewer" })
	local value, err = capture(function(callback)
		client.respond(root, round_id, {
			type = "praise",
			body = "Looks good",
			delivery_key = "native-reply",
			reply_to = "native-comment-1",
			anchor = { path = "README.md", side = "right", start_line = 7 },
		}, callback)
	end)
	assert(value and value.id == "reply" and not err)
	equal({
		launcher,
		"respond",
		"--round",
		round_id,
		"--author=Default Reviewer",
		"--severity=nit",
		"--comment-type=praise",
		"--delivery-key=native-reply",
		"--reply-to=native-comment-1",
		"--path=README.md",
		"--start=7",
		"--side=new",
		"--",
		"Looks good",
	}, calls[2], "respond argv changed")
end)

test("option-like author, path, reply id, and body remain literal argv values", function()
	local client, calls = fake_client({
		status(),
		success({
			ok = true,
			command = "respond",
			round = round_id,
			tuicr = { id = "literal" },
		}),
	})
	local value, err = capture(function(callback)
		client.respond(root, round_id, {
			type = "question",
			body = "--status",
			delivery_key = "--delivery",
			author = "--author",
			reply_to = "--parent",
			anchor = { path = "--file.py", side = "right", start_line = 1 },
		}, callback)
	end)
	assert(value and value.id == "literal" and not err)
	equal({
		launcher,
		"respond",
		"--round",
		round_id,
		"--author=--author",
		"--severity=warning",
		"--comment-type=question",
		"--delivery-key=--delivery",
		"--reply-to=--parent",
		"--path=--file.py",
		"--start=1",
		"--side=new",
		"--",
		"--status",
	}, calls[2], "option-like values were reinterpreted")
end)

test("invalid values fail before status or write commands", function()
	local client, calls = fake_client({})
	local _, type_err = capture(function(callback)
		client.add(root, round_id, { type = "note", body = "No", delivery_key = "invalid", anchor = {} }, callback)
	end)
	assert(type_err.code == "invalid_type")
	local _, reply_err = capture(function(callback)
		client.respond(root, round_id, {
			type = "issue",
			body = "No reply",
			delivery_key = "missing-reply",
			anchor = {},
		}, callback)
	end)
	assert(reply_err.code == "invalid_reply_to")
	local _, anchor_err = capture(function(callback)
		client.add(root, round_id, {
			type = "issue",
			body = "Unsafe",
			delivery_key = "unsafe",
			anchor = { path = "../outside.lua" },
		}, callback)
	end)
	assert(anchor_err.code == "invalid_anchor")
	assert(#calls == 0, "invalid values reached vim.system")
end)

test("invalid UUIDs and rounds outside the canonical root fail before target operations", function()
	local invalid_client, invalid_calls = fake_client({})
	local _, uuid_err = capture(function(callback)
		invalid_client.comments(root, "not-a-uuid", callback)
	end)
	assert(uuid_err.code == "invalid_round" and #invalid_calls == 0)

	local missing_client, missing_calls = fake_client({ status({}) })
	local _, missing_err = capture(function(callback)
		missing_client.add(root, round_id, {
			type = "issue",
			body = "Finding",
			delivery_key = "missing-round",
			anchor = {},
		}, callback)
	end)
	assert(missing_err.code == "round_not_found")
	assert(#missing_calls == 1 and missing_calls[1][2] == "status", "missing round reached add")
end)

test("malformed JSON, root mismatches, and launcher errors are rejected", function()
	local malformed = { code = 0, stdout = "not-json", stderr = "" }
	local malformed_client = fake_client({ malformed })
	local _, json_err = capture(function(callback)
		malformed_client.list_rounds(root, callback)
	end)
	assert(json_err.code == "invalid_json")

	local mismatched_client = fake_client({ status(nil, "/tmp/other") })
	local _, root_err = capture(function(callback)
		mismatched_client.list_rounds(root, callback)
	end)
	assert(root_err.code == "invalid_response")

	local launcher_error = {
		code = 1,
		stdout = vim.json.encode({
			ok = false,
			error = { code = "round_not_found", message = "No round", details = { round = round_id } },
		}),
		stderr = "",
	}
	local failing_client = fake_client({ launcher_error })
	local _, err = capture(function(callback)
		failing_client.list_rounds(root, callback)
	end)
	assert(err.code == "round_not_found" and err.details.round == round_id)

	local missing_receipt = fake_client({
		status(),
		success({ ok = true, command = "add", round = round_id, tuicr = {} }),
	})
	local _, receipt_err = capture(function(callback)
		missing_receipt.add(root, round_id, {
			type = "issue",
			body = "Missing remote id",
			delivery_key = "missing-receipt",
		}, callback)
	end)
	assert(receipt_err.code == "invalid_response")
end)

if #failures > 0 then
	for _, failure_value in ipairs(failures) do
		vim.api.nvim_err_writeln(failure_value)
	end
	vim.cmd("cquit")
end

print(string.format("review_tuicr_spec: %d tests passed", count))
vim.cmd("quitall!")
