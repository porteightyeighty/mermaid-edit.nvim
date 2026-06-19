-- Single source of truth for mermaid erDiagram relationship markers.
--
-- A relationship is `<left-cardinality><line><right-cardinality>`, e.g.
-- `||--o{`. The two sides are written with different glyphs (the "crow's foot"
-- opens away from each entity), so left and right cardinalities are kept in
-- separate tables, and the line carries the identifying/non-identifying choice.
-- The interactive picker walks the three tables in turn; core composes the
-- chosen tokens into a marker and validates it against the grammar.

local M = {}

-- Left-hand cardinality (reads "<this> relates to ..."). Crow's foot opens left.
M.left = {
	{ name = "zero or one", token = "|o" },
	{ name = "exactly one", token = "||" },
	{ name = "zero or more", token = "}o" },
	{ name = "one or more", token = "}|" },
}

-- Right-hand cardinality. Crow's foot opens right (mirror of the left glyphs).
M.right = {
	{ name = "zero or one", token = "o|" },
	{ name = "exactly one", token = "||" },
	{ name = "zero or more", token = "o{" },
	{ name = "one or more", token = "|{" },
}

-- The connecting line: identifying (solid) vs non-identifying (dashed).
M.line = {
	{ name = "identifying", token = "--" },
	{ name = "non-identifying", token = ".." },
}

-- Ordered list of names for a table, for vim.ui.select.
local function names(list)
	local out = {}
	for _, e in ipairs(list) do
		out[#out + 1] = e.name
	end
	return out
end

function M.left_names()
	return names(M.left)
end

function M.right_names()
	return names(M.right)
end

function M.line_names()
	return names(M.line)
end

-- Case-insensitive name lookup within one of the tables. Returns the entry or nil.
local function by_name(list, name)
	name = (name or ""):lower()
	for _, e in ipairs(list) do
		if e.name:lower() == name then
			return e
		end
	end
	return nil
end

function M.left_by_name(name)
	return by_name(M.left, name)
end

function M.right_by_name(name)
	return by_name(M.right, name)
end

function M.line_by_name(name)
	return by_name(M.line, name)
end

-- Split a marker (`||--o{`) into its three component tokens
-- ({ left, line, right }), or nil when it does not match the expected shape.
-- The line is always the central two glyphs (`--` or `..`); the cardinalities
-- are the two glyphs on either side.
function M.split(marker)
	if type(marker) ~= "string" then
		return nil
	end
	local left, line, right = marker:match("^(..)(%-%-?)(..)$")
	if not left then
		left, line, right = marker:match("^(..)(%.%.)(..)$")
	end
	if not left or (line ~= "--" and line ~= "..") then
		return nil
	end
	return { left = left, line = line, right = right }
end

return M
