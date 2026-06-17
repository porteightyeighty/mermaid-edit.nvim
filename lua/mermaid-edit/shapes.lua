-- Single source of truth for mermaid flowchart vertex shapes.
-- Each entry maps a human-readable name to the open/close delimiter pair that
-- wraps the label text. Used by the change-shape picker and by insert_between
-- when matching a new node to the shape of the edge's target.

local M = {}

M.list = {
	{ name = "Square", open = "[", close = "]" },
	{ name = "Rounded", open = "(", close = ")" },
	{ name = "Stadium", open = "([", close = "])" },
	{ name = "Subroutine", open = "[[", close = "]]" },
	{ name = "Cylinder", open = "[(", close = ")]" },
	{ name = "Circle", open = "((", close = "))" },
	{ name = "Asymmetric", open = ">", close = "]" },
	{ name = "Rhombus", open = "{", close = "}" },
	{ name = "Hexagon", open = "{{", close = "}}" },
	{ name = "Parallelogram", open = "[/", close = "/]" },
	{ name = "Parallelogram alt", open = "[\\", close = "\\]" },
	{ name = "Trapezoid", open = "[/", close = "\\]" },
	{ name = "Trapezoid alt", open = "[\\", close = "/]" },
}

-- Look a shape up by (case-insensitive) name. Returns the entry or nil.
function M.by_name(name)
	name = (name or ""):lower()
	for _, shape in ipairs(M.list) do
		if shape.name:lower() == name then
			return shape
		end
	end
	return nil
end

-- Ordered list of names, for vim.ui.select.
function M.names()
	local names = {}
	for _, shape in ipairs(M.list) do
		names[#names + 1] = shape.name
	end
	return names
end

return M
