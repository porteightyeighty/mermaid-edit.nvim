-- Single source of truth for mermaid erDiagram attribute key constraints.
-- Each entry maps a human-readable name to the literal key token that follows
-- an attribute's name (`string id PK`). "none" carries the empty token, which
-- the change-key primitive uses to strip an existing key off an attribute.
--
-- Only keys the tree-sitter-mermaid grammar can parse are offered: it accepts
-- `PK` and `FK` on their own, but not `UK` nor a combined `PK, FK` - and the
-- editor refuses to touch a tree with errors, so offering one would strand the
-- diagram. (mermaid.js renders `UK`; this is purely a grammar limitation.)

local M = {}

M.list = {
	{ name = "none", token = "" },
	{ name = "PK", token = "PK" },
	{ name = "FK", token = "FK" },
}

-- Look a key up by (case-insensitive) name. Returns the entry or nil.
function M.by_name(name)
	name = (name or ""):lower()
	for _, k in ipairs(M.list) do
		if k.name:lower() == name then
			return k
		end
	end
	return nil
end

-- Ordered list of names, for vim.ui.select.
function M.names()
	local names = {}
	for _, k in ipairs(M.list) do
		names[#names + 1] = k.name
	end
	return names
end

return M
