-- Core, UI-free primitives for structural edits of mermaid erDiagrams.
--
-- Mirrors mermaid-edit.core (the flowchart engine): every public function is
-- synchronous, takes explicit (buf, row, ...) arguments, never prompts, and
-- gates on a clean parse so an edit can never silently corrupt a diagram the
-- plugin could no longer read back.
--
-- Relies on the monaqa/tree-sitter-mermaid grammar. The two statement shapes:
--
--   er_stmt_entity_relation   "CUSTOMER ||--o{ ORDER : places"
--   ├─ er_entity_name         (left)
--   ├─ er_relation            "||--o{"  (cardinality + line glyphs)
--   ├─ er_entity_name         (right)
--   └─ er_role                "places"  (the `:` label; REQUIRED by the grammar)
--
--   er_stmt_entity_block      "CUSTOMER {\n  string name PK\n}"
--   ├─ er_entity_name
--   └─ er_stmt_entity_block_inner          (absent for an empty `{ }` block)
--      └─ er_attribute  "string name PK"
--         ├─ er_attribute_type      "string"
--         ├─ er_attribute_name      "name"
--         ├─ er_attribute_key_type_pk/fk/uk  "PK"   (optional)
--         └─ er_attribute_comment   "\"...\""        (optional)
--
-- The grammar errors on an unlabelled relation (`A ||--o{ B`) and on a
-- single-line block, so this module always writes a role and one attribute per
-- line. Edits are verbatim range copies, never regenerated, so labels survive.

local M = {}

local function warn(msg)
	vim.notify("mermaid-edit: " .. msg, vim.log.levels.WARN)
end

-- True when every parse error in the tree is whitespace-only (a benign grammar
-- quirk on trailing-whitespace lines). Same tolerance as the flowchart engine.
local function only_blank_errors(root, buf)
	local real_error = false
	local function walk(node)
		if real_error then
			return
		end
		if node:type() == "ERROR" or node:missing() then
			if not vim.treesitter.get_node_text(node, buf):match("^%s*$") then
				real_error = true
				return
			end
		end
		for child in node:iter_children() do
			walk(child)
		end
	end
	walk(root)
	return not real_error
end

-- Root's first named child type, without warning or error-gating. Lets a caller
-- route by diagram kind even when the tree has errors.
-- Returns "er", "flow", or nil.
function M.diagram_type(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "mermaid")
	if not ok or not parser then
		return nil
	end
	local root = parser:parse()[1]:root()
	for child in root:iter_children() do
		if child:named() then
			local t = child:type()
			if t == "diagram_er" then
				return "er"
			elseif t == "diagram_flow" then
				return "flow"
			end
			return nil
		end
	end
	return nil
end

-- Parse `buf`, returning the root node, or nil after notifying when the parser
-- is missing or the tree has a real (non-whitespace) parse error - most often an
-- unlabelled relation (every relation needs a `: role`) or a single-line block.
local function parse(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "mermaid")
	if not ok or not parser then
		warn("no mermaid treesitter parser (run :checkhealth mermaid-edit)")
		return nil
	end
	local root = parser:parse()[1]:root()
	if root:has_error() and not only_blank_errors(root, buf) then
		warn(
			"the diagram has a parse error - every relation needs a `: role` label and each attribute "
				.. "must sit on its own line inside the `{ }` block"
		)
		return nil
	end
	return root
end

-- First descendant of `node` (inclusive) with the given type.
local function find_descendant(node, type_name)
	if node:type() == type_name then
		return node
	end
	for child in node:iter_children() do
		local found = find_descendant(child, type_name)
		if found then
			return found
		end
	end
	return nil
end

-- First direct child of `node` with the given type.
local function child_of_type(node, type_name)
	for child in node:iter_children() do
		if child:type() == type_name then
			return child
		end
	end
	return nil
end

local function text(node, buf)
	return vim.treesitter.get_node_text(node, buf)
end

-- erDiagram roles are a single bare word unless quoted; a role with whitespace
-- (or any non-word glyph) must be wrapped in double quotes to parse. These keep
-- the stored form valid while showing the user the bare text.
local function unquote(s)
	return (s or ""):gsub('^"(.*)"$', "%1")
end

local function quote_role(s)
	s = unquote(s)
	if s:match("^[%w_]+$") then
		return s
	end
	return '"' .. s:gsub('"', "") .. '"'
end

-- The er_stmt_entity_relation that begins on buffer `row`, or nil.
local function relation_at_row(root, buf, row)
	local query = vim.treesitter.query.parse("mermaid", "(er_stmt_entity_relation) @rel")
	for _, node in query:iter_captures(root, buf) do
		if node:start() == row then
			return node
		end
	end
	return nil
end

-- The er_attribute that covers buffer `row`, or nil.
local function attribute_at_row(root, buf, row)
	local query = vim.treesitter.query.parse("mermaid", "(er_attribute) @attr")
	for _, node in query:iter_captures(root, buf) do
		if node:start() == row then
			return node
		end
	end
	return nil
end

-- The er_stmt_entity_block whose range contains `row`, or nil.
local function block_at_row(root, buf, row)
	local query = vim.treesitter.query.parse("mermaid", "(er_stmt_entity_block) @block")
	for _, node in query:iter_captures(root, buf) do
		local sr, _, er = node:range()
		if row >= sr and row <= er then
			return node
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Relationships
----------------------------------------------------------------------

-- The current relationship marker (e.g. `||--o{`) on the relation at `row`, or
-- nil when there is no relation there. Lets a caller prefill the picker.
function M.relation_marker(buf, row)
	local root = parse(buf)
	if not root then
		return nil
	end
	local rel = relation_at_row(root, buf, row)
	if not rel then
		return nil
	end
	local marker = child_of_type(rel, "er_relation")
	return marker and text(marker, buf) or nil
end

-- Change the relationship marker of the relation on `row` to `marker`,
-- preserving both entities and the role. Returns true on success.
function M.change_relation(buf, row, marker)
	local root = parse(buf)
	if not root then
		return false
	end
	local rel = relation_at_row(root, buf, row)
	if not rel then
		warn("place the cursor on a relationship line to change its cardinality")
		return false
	end
	local node = child_of_type(rel, "er_relation")
	if not node then
		warn("no relationship marker on this line")
		return false
	end
	local sr, sc, er, ec = node:range()
	vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { marker })
	return true
end

-- The current role label of the relation on `row` ("" when somehow absent), or
-- nil when there is no relation there.
function M.role_text(buf, row)
	local root = parse(buf)
	if not root then
		return nil
	end
	local rel = relation_at_row(root, buf, row)
	if not rel then
		return nil
	end
	local role = child_of_type(rel, "er_role")
	return role and unquote(text(role, buf)) or ""
end

-- Set the role label on the relation at `row`. The grammar requires every
-- relation to carry a `: role`, so an empty `role` is rejected (it would make
-- the diagram unparseable) rather than removing the label. Returns true on
-- success.
function M.set_role(buf, row, role)
	if not role or role == "" then
		warn("a relationship needs a role label (the `: word` part)")
		return false
	end
	local root = parse(buf)
	if not root then
		return false
	end
	local rel = relation_at_row(root, buf, row)
	if not rel then
		warn("place the cursor on a relationship line to label it")
		return false
	end
	role = quote_role(role)
	local existing = child_of_type(rel, "er_role")
	if existing then
		local sr, sc, er, ec = existing:range()
		vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { role })
	else
		-- No role: append ` : role` at the end of the right-hand entity name.
		local right
		for child in rel:iter_children() do
			if child:type() == "er_entity_name" then
				right = child
			end
		end
		if not right then
			return false
		end
		local _, _, er, ec = right:range()
		vim.api.nvim_buf_set_text(buf, er, ec, er, ec, { " : " .. role })
	end
	return true
end

-- Append a new relationship line after `row` (or after the last statement when
-- `row` has none). Always carries a role, since the grammar requires one.
-- Returns true on success.
function M.add_relation(buf, row, left_entity, marker, right_entity, role)
	if not left_entity or left_entity == "" or not right_entity or right_entity == "" then
		return false
	end
	local root = parse(buf)
	if not root then
		return false
	end
	marker = (marker and marker ~= "") and marker or "||--o{"
	role = quote_role((role and role ~= "") and role or "relates to")

	-- Anchor: the statement on `row`, else the last top-level er statement.
	local anchor_row, indent
	local rel = relation_at_row(root, buf, row) or block_at_row(root, buf, row)
	if rel then
		local _, _, er = rel:range()
		anchor_row = er
		local sr = rel:start()
		local line = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
		indent = line:match("^%s*") or "  "
	else
		local query = vim.treesitter.query.parse(
			"mermaid",
			"[(er_stmt_entity_relation) (er_stmt_entity_block)] @stmt"
		)
		for _, node in query:iter_captures(root, buf) do
			local _, _, er = node:range()
			if not anchor_row or er > anchor_row then
				anchor_row = er
				local sr = node:start()
				local line = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
				indent = line:match("^%s*") or "  "
			end
		end
		if not anchor_row then
			warn("no erDiagram statement to anchor the new relationship to")
			return false
		end
	end
	local line = string.format("%s%s %s %s : %s", indent, left_entity, marker, right_entity, role)
	vim.api.nvim_buf_set_lines(buf, anchor_row + 1, anchor_row + 1, false, { line })
	return true
end

----------------------------------------------------------------------
-- Attributes
----------------------------------------------------------------------

-- Render an attribute line body (no indent): `type name [KEY] [comment]`.
local function render_attribute(typ, name, key, comment)
	local parts = { typ, name }
	if key and key ~= "" then
		parts[#parts + 1] = key
	end
	if comment and comment ~= "" then
		parts[#parts + 1] = comment
	end
	return table.concat(parts, " ")
end

-- Add an attribute to the entity block containing `row`. The new line is placed
-- last in the block, indented to match the existing attributes (or the header
-- indent + 4 for an empty block). Returns true on success.
function M.add_attribute(buf, row, typ, name, key, comment)
	if not typ or typ == "" or not name or name == "" then
		return false
	end
	local root = parse(buf)
	if not root then
		return false
	end
	local block = block_at_row(root, buf, row)
	if not block then
		warn("place the cursor inside an entity `{ }` block to add an attribute")
		return false
	end
	local inner = child_of_type(block, "er_stmt_entity_block_inner")
	local indent, insert_row
	if inner then
		-- Indent from the first attribute; insert after the last one.
		local first = child_of_type(inner, "er_attribute")
		local fr = first:start()
		indent = (vim.api.nvim_buf_get_lines(buf, fr, fr + 1, false)[1] or ""):match("^%s*") or "    "
		local last_attr_row = fr
		for child in inner:iter_children() do
			if child:type() == "er_attribute" then
				last_attr_row = child:start()
			end
		end
		insert_row = last_attr_row + 1
	else
		-- Empty block: indent = header indent + 4; insert just before the `}` line.
		local hr = block:start()
		local header_indent = (vim.api.nvim_buf_get_lines(buf, hr, hr + 1, false)[1] or ""):match("^%s*") or ""
		indent = header_indent .. "    "
		local _, _, er = block:range() -- the closing `}` row
		insert_row = er
	end
	local line = indent .. render_attribute(typ, name, key, comment)
	vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, { line })
	return true
end

-- Remove the attribute line under `row`. Returns true on success.
function M.remove_attribute(buf, row)
	local root = parse(buf)
	if not root then
		return false
	end
	local attr = attribute_at_row(root, buf, row)
	if not attr then
		warn("place the cursor on an attribute line to remove it")
		return false
	end
	local r = attr:start()
	vim.api.nvim_buf_set_lines(buf, r, r + 1, false, {})
	return true
end

-- Remove the relationship line at `row`. Returns true on success, false (with a
-- notice) when there is no relationship there. Lets remove_node fall back here
-- after remove_attribute declines an attribute line.
function M.remove_relation(buf, row)
	local root = parse(buf)
	if not root then
		return false
	end
	local rel = relation_at_row(root, buf, row)
	if not rel then
		warn("place the cursor on an attribute or relationship line to remove it")
		return false
	end
	vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
	return true
end

-- Remove whatever is on `row`: an attribute line, else a relationship line.
-- Picks without emitting a spurious notice for the path not taken. Returns true
-- on success.
function M.remove_at(buf, row)
	local root = parse(buf)
	if not root then
		return false
	end
	if attribute_at_row(root, buf, row) then
		return M.remove_attribute(buf, row)
	end
	return M.remove_relation(buf, row)
end

-- The type of the attribute under `row` (e.g. "string"), or nil when there is no
-- attribute there. Lets a caller prefill a type prompt.
function M.attribute_type_at(buf, row)
	local root = parse(buf)
	if not root then
		return nil
	end
	local attr = attribute_at_row(root, buf, row)
	if not attr then
		return nil
	end
	local tnode = child_of_type(attr, "er_attribute_type")
	return tnode and text(tnode, buf) or nil
end

-- Swap the attribute on `row` with its previous (dir<0) or next (dir>0) sibling
-- within the same block. Returns true on success, false (with a notice) at a
-- block boundary or off an attribute.
function M.move_attribute(buf, row, dir)
	local root = parse(buf)
	if not root then
		return false
	end
	local attr = attribute_at_row(root, buf, row)
	if not attr then
		warn("place the cursor on an attribute line to move it")
		return false
	end
	local inner = attr:parent()
	-- Ordered attribute rows within this block.
	local rows = {}
	for child in inner:iter_children() do
		if child:type() == "er_attribute" then
			rows[#rows + 1] = child:start()
		end
	end
	local idx
	for i, r in ipairs(rows) do
		if r == row then
			idx = i
		end
	end
	local other = idx and rows[idx + dir]
	if not other then
		warn("no attribute to move past on this side")
		return false
	end
	local a = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
	local b = vim.api.nvim_buf_get_lines(buf, other, other + 1, false)[1]
	vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { b })
	vim.api.nvim_buf_set_lines(buf, other, other + 1, false, { a })
	return true
end

-- The key node (er_attribute_key_type_pk/fk/uk) of an er_attribute, or nil.
local function attr_key_node(attr)
	for child in attr:iter_children() do
		if child:type():find("^er_attribute_key_type_") then
			return child
		end
	end
	return nil
end

-- Change (or, for an empty `key`, remove) the PK/FK/UK constraint on the
-- attribute under `row`, leaving type/name/comment untouched. Returns true on
-- success.
function M.change_attribute_key(buf, row, key)
	local root = parse(buf)
	if not root then
		return false
	end
	local attr = attribute_at_row(root, buf, row)
	if not attr then
		warn("place the cursor on an attribute line to change its key")
		return false
	end
	key = key or ""
	local existing = attr_key_node(attr)
	if existing then
		if key == "" then
			-- Drop the key and the single space before it.
			local sr, sc, er, ec = existing:range()
			vim.api.nvim_buf_set_text(buf, sr, sc - 1, er, ec, { "" })
		else
			local sr, sc, er, ec = existing:range()
			vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { key })
		end
		return true
	end
	if key == "" then
		return true -- nothing to remove; already keyless
	end
	-- Insert the key after the attribute name.
	local name = child_of_type(attr, "er_attribute_name")
	local _, _, er, ec = name:range()
	vim.api.nvim_buf_set_text(buf, er, ec, er, ec, { " " .. key })
	return true
end

-- Change the type of the attribute under `row`, leaving name/key/comment intact.
-- Returns true on success.
function M.change_attribute_type(buf, row, typ)
	if not typ or typ == "" then
		return false
	end
	local root = parse(buf)
	if not root then
		return false
	end
	local attr = attribute_at_row(root, buf, row)
	if not attr then
		warn("place the cursor on an attribute line to change its type")
		return false
	end
	local tnode = child_of_type(attr, "er_attribute_type")
	if not tnode then
		return false
	end
	local sr, sc, er, ec = tnode:range()
	vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { typ })
	return true
end

----------------------------------------------------------------------
-- Entity rename (the shared-name threading analog)
----------------------------------------------------------------------

-- The entity name under (row, col): the enclosing er_entity_name, else the
-- entity of the block/relation on that row.
local function entity_name_at(root, buf, row, col)
	col = col or 0
	local node = root:named_descendant_for_range(row, col, row, col)
	while node and node:type() ~= "er_entity_name" do
		node = node:parent()
	end
	if node then
		return text(node, buf)
	end
	-- Fall back to the first entity name on the statement at this row.
	local stmt = relation_at_row(root, buf, row) or block_at_row(root, buf, row)
	if stmt then
		local name = find_descendant(stmt, "er_entity_name")
		return name and text(name, buf) or nil
	end
	return nil
end

-- The current entity name under (row, col), or nil. Lets a caller prefill.
function M.entity_at(buf, row, col)
	local root = parse(buf)
	if not root then
		return nil
	end
	return entity_name_at(root, buf, row, col)
end

-- Rename the entity under (row, col) to `new_name` everywhere it appears: every
-- relation operand and the entity-block header. Exact-text match, so a partial
-- name (`ORDER` vs `ORDER_LINE`) is never corrupted. Returns true on success.
function M.rename_entity(buf, row, col, new_name)
	if not new_name or new_name == "" then
		return false
	end
	local root = parse(buf)
	if not root then
		return false
	end
	local old = entity_name_at(root, buf, row, col)
	if not old then
		warn("place the cursor on an entity name to rename it")
		return false
	end
	if old == new_name then
		return true
	end
	-- Collect every matching occurrence, then rewrite descending so earlier
	-- edits don't shift the ranges of later ones.
	local query = vim.treesitter.query.parse("mermaid", "(er_entity_name) @name")
	local ranges = {}
	for _, node in query:iter_captures(root, buf) do
		if text(node, buf) == old then
			ranges[#ranges + 1] = { node:range() }
		end
	end
	table.sort(ranges, function(a, b)
		if a[1] ~= b[1] then
			return a[1] > b[1]
		end
		return a[2] > b[2]
	end)
	for _, r in ipairs(ranges) do
		vim.api.nvim_buf_set_text(buf, r[1], r[2], r[3], r[4], { new_name })
	end
	return true
end

-- Exposed for tests.
M._parse = parse

return M
