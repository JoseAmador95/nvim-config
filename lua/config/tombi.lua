local M = {}

function M.env()
	return {
		XDG_CONFIG_HOME = vim.fn.stdpath("config"),
	}
end

function M.settings()
	return {
		tombi = {
			schema = {
				strict = false,
				catalog = { paths = {} },
			},
		},
	}
end

return M
