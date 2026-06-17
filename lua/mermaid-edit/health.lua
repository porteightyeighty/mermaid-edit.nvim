-- :checkhealth mermaid-edit

local M = {}

function M.check()
	local health = vim.health or require("health")
	local start = health.start or health.report_start
	local ok = health.ok or health.report_ok
	local warn = health.warn or health.report_warn
	local error = health.error or health.report_error

	start("mermaid-edit")

	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim " .. tostring(vim.version()))
	else
		warn("Neovim 0.10+ recommended")
	end

	local has_parser = pcall(vim.treesitter.language.inspect, "mermaid")
	if has_parser then
		ok("mermaid treesitter parser is installed")
	else
		error("mermaid treesitter parser not found", {
			"Install it, e.g. with nvim-treesitter: `:TSInstall mermaid`",
		})
	end

	if vim.treesitter.query.get("mermaid", "highlights") then
		ok("mermaid queries are available")
	else
		warn("no mermaid highlight queries found (optional)")
	end
end

return M
