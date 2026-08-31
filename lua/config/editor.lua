local M = {}

function M.open_file_in_tab(filepath, opts)
	opts = opts or {}

	-- Loading the tab adapter configures the host policies used by the standalone
	-- runtime.
	require("config.tabs")
	return require("tab_first").open(filepath, opts)
end

return M
