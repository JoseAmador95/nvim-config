-- :checkhealth agent_review -- reports whether the agent-review workflow has
-- what it needs: a git repository, a snapshot to diff against, how much of the
-- round is reviewed, and how the generated prompt would reach the clipboard.
-- See lua/config/agent_review/.

local M = {}

local health = vim.health

-- The clipboard half can only ever be reported, never confirmed: OSC52 (the
-- usual path over ssh) gives no acknowledgement, so no code here can know that
-- the text reached the outer machine. Say so instead of claiming success.
local function check_clipboard()
	health.start("Agent review: prompt delivery")

	local cb = vim.g.clipboard
	if type(cb) == "table" and type(cb.name) == "string" and cb.name ~= "" then
		health.ok("clipboard provider: " .. cb.name)
	else
		local ok, provider = pcall(vim.fn["provider#clipboard#Executable"])
		provider = ok and vim.trim(tostring(provider or "")) or ""
		if provider ~= "" then
			health.ok("clipboard provider: " .. provider)
		else
			health.warn(
				"no clipboard provider found",
				{ "the prompt buffer still opens; yank it by hand with <leader>y" }
			)
		end
	end

	local ssh = vim.env.SSH_TTY or vim.env.SSH_CONNECTION
	if ssh then
		health.warn(
			"ssh session detected: the clipboard most likely travels over OSC52",
			{ "OSC52 is not acknowledged, so delivery cannot be confirmed from Lua -- paste once to check it" }
		)
	else
		health.ok("local session (no SSH_TTY/SSH_CONNECTION)")
	end
end

function M.check()
	health.start("Agent review")

	local ok, git = pcall(require, "config.agent_review.git")
	if not ok then
		health.error("config.agent_review.git failed to load: " .. tostring(git))
		return
	end
	local state
	ok, state = pcall(require, "config.agent_review.state")
	if not ok then
		health.error("config.agent_review.state failed to load: " .. tostring(state))
		return
	end

	if vim.fn.executable("git") ~= 1 then
		health.error("git executable not found: the whole workflow needs it")
		check_clipboard()
		return
	end

	local root = git.root()
	if not root then
		health.warn("not inside a git repository", { "cd into one: every snapshot and diff is repo-relative" })
		check_clipboard()
		return
	end
	health.ok("git repository: " .. root)

	state.load(root)
	local base, origin = state.base(), "recorded base"
	if not base or base == "" then
		base, origin = git.latest(), "latest snapshot (not yet recorded as the base)"
	end
	if not base or base == "" then
		health.warn(
			"no snapshot ref yet",
			{ "take one with <leader>vs (or :AgentReviewSnapshot) before running an agent" }
		)
		check_clipboard()
		return
	end
	health.ok(("snapshot ref: %s (%s)"):format(base, origin))

	local files, err = git.changed_files(base)
	if not files then
		health.error("could not diff against " .. base .. ": " .. tostring(err))
		check_clipboard()
		return
	end
	if #files == 0 then
		health.ok("0 files changed since the snapshot")
	else
		health.ok(("%d file(s) changed since the snapshot"):format(#files))
	end

	local review
	ok, review = pcall(require, "config.agent_review.review")
	if not ok then
		health.error("config.agent_review.review failed to load: " .. tostring(review))
		check_clipboard()
		return
	end
	-- `files` was just computed above: handing it over avoids re-running the whole
	-- diff (which rebuilds a tree object from the working tree) a second time.
	local got, hunks, herr = pcall(review.all_hunks, files)
	if not got then
		health.error("could not compute review progress: " .. tostring(hunks))
		check_clipboard()
		return
	end
	if not hunks then
		-- A git failure used to fall through to state.progress({}) -> 0, 0 and be
		-- reported as "no hunks to review": a clean bill of health for a breakage.
		health.error("could not read the hunks of the changed files: " .. tostring(herr), {
			"the review progress is unknown, not zero",
			"check that the snapshot ref still resolves: git rev-parse " .. base,
		})
		check_clipboard()
		return
	end
	local reviewed, total = review.progress(hunks)
	if herr then
		-- Partial failure: some files were read, some were not. "0/0" here would
		-- read as "nothing to review" when the truth is "could not look".
		health.error(("some files could not be diffed: %s"):format(herr), {
			("their hunks are missing from the review queue and from the count (%d/%d over the rest)"):format(
				reviewed,
				total
			),
			"check that the snapshot ref still resolves: git rev-parse " .. base,
		})
	elseif total == 0 then
		health.ok("no hunks to review")
	elseif reviewed == total then
		health.ok(("review complete: %d/%d hunks"):format(reviewed, total))
	else
		health.warn(("review in progress: %d/%d hunks"):format(reviewed, total), { "]v jumps to the next one" })
	end

	check_clipboard()
end

return M
