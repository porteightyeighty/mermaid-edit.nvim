-- Single source of truth for mermaid flowchart link (arrow) styles.
-- Each entry maps a human-readable name to the literal arrow token that joins
-- two nodes. Used by the change-arrow picker. Labels are kept separately and
-- rendered in the pipe form (`<arrow>|label|`).

local M = {}

-- Only styles the tree-sitter-mermaid grammar can parse are offered: the editor
-- gates every operation on a clean parse, so an arrow the grammar errors on
-- would produce a diagram the plugin could no longer edit. The dotted *open*
-- link `-.-` is the notable casualty - mermaid.js renders it, but the grammar
-- treats it as an error, so it is deliberately absent (use `-.->` for dotted).
M.list = {
	{ name = "Arrow", arrow = "-->" },
	{ name = "Open link", arrow = "---" },
	{ name = "Dotted arrow", arrow = "-.->" },
	{ name = "Thick arrow", arrow = "==>" },
	{ name = "Thick open", arrow = "===" },
	{ name = "Circle edge", arrow = "--o" },
	{ name = "Cross edge", arrow = "--x" },
	{ name = "Bidirectional", arrow = "<-->" },
}

-- Look an arrow up by (case-insensitive) name. Returns the entry or nil.
function M.by_name(name)
	name = (name or ""):lower()
	for _, a in ipairs(M.list) do
		if a.name:lower() == name then
			return a
		end
	end
	return nil
end

-- Ordered list of names, for vim.ui.select.
function M.names()
	local names = {}
	for _, a in ipairs(M.list) do
		names[#names + 1] = a.name
	end
	return names
end

return M
