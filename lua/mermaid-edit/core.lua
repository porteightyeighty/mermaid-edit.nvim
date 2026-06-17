-- Core, UI-free primitives for structural edits of mermaid flowcharts.
--
-- Every public function is synchronous and operates on explicit (buf, row, ...)
-- arguments so it can be driven equally from interactive wrappers (init.lua) and
-- from headless tests. Labels/shapes are passed in as plain values; this module
-- never prompts.
--
-- Design relies on the monaqa/tree-sitter-mermaid grammar. For a single edge
-- line `SRC <arrow> TGT[label]` the relevant tree is:
--
--   flow_stmt_vertice
--   ├─ flow_node            (source)  > flow_vertex > flow_vertex_id
--   ├─ flow_link_simplelink (arrow)   text e.g. "-->"
--   └─ flow_node            (target)  > flow_vertex > flow_vertex_id
--                                                   + flow_vertex_<shape>
--                                                       open-delim
--                                                       flow_text_literal
--                                                       close-delim
--
-- Labels and shape delimiters are moved by verbatim range copy, never
-- regenerated, so `<br>` and shape glyphs survive untouched.

local shapes = require("mermaid-edit.shapes")

local M = {}

local function warn(msg)
	vim.notify("mermaid-edit: " .. msg, vim.log.levels.WARN)
end

-- True when every parse error in the tree is a whitespace-only node. The monaqa
-- mermaid grammar emits an ERROR for a line containing only trailing whitespace,
-- which is harmless - we don't want to block edits on it.
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

-- Parse `buf` as mermaid. Returns the root node, or nil after notifying if the
-- parser is missing or the tree has a real (non-whitespace) parse error - most
-- often a stray `<br/>` (use `<br>`).
local function parse(buf)
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "mermaid")
	if not ok or not parser then
		warn("no mermaid treesitter parser (run :checkhealth mermaid-edit)")
		return nil
	end
	local tree = parser:parse()[1]
	local root = tree:root()
	if root:has_error() and not only_blank_errors(root, buf) then
		warn("the diagram has a parse error - check for a `<br/>` (use `<br>`) or other invalid syntax")
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

-- The id text of a flow_node (its flow_vertex_id), or nil.
local function node_id(flow_node, buf)
	local id = find_descendant(flow_node, "flow_vertex_id")
	return id and vim.treesitter.get_node_text(id, buf) or nil
end

-- Number of flow_vertex children directly under a flow_node: 1 for a plain node,
-- more when it is an `&` group (`a & b`).
local function vertex_count(flow_node)
	local n = 0
	for child in flow_node:iter_children() do
		if child:type() == "flow_vertex" then
			n = n + 1
		end
	end
	return n
end

-- The shape node child of a flow_vertex (flow_vertex_<shape>), or nil for a bare
-- id. Works on any member of an `&` group, since it takes the vertex directly.
local function vertex_shape_node(vertex)
	for child in vertex:iter_children() do
		local t = child:type()
		if t ~= "flow_vertex_id" and t:find("^flow_vertex_") then
			return child
		end
	end
	return nil
end

-- The shape node (flow_vertex_<shape>) of a flow_node's first vertex, or nil for
-- a bare id ref.
local function shape_node_of(flow_node)
	local vertex = find_descendant(flow_node, "flow_vertex")
	return vertex and vertex_shape_node(vertex) or nil
end

-- Open/close delimiter text of a shape node (first/last child).
local function shape_delims(shape_node, buf)
	local n = shape_node:child_count()
	local open = vim.treesitter.get_node_text(shape_node:child(0), buf)
	local close = vim.treesitter.get_node_text(shape_node:child(n - 1), buf)
	return open, close
end

-- Inner label text of a shape node (its flow_text_literal / flow_text_quoted).
local function shape_label(shape_node, buf)
	for child in shape_node:iter_children() do
		local t = child:type()
		if t == "flow_text_literal" or t == "flow_text_quoted" then
			return vim.treesitter.get_node_text(child, buf)
		end
	end
	return ""
end

-- Walk every flow_stmt_vertice in row order, returning one record per edge line.
local function collect_stmts(buf, root)
	local query = vim.treesitter.query.parse("mermaid", "(flow_stmt_vertice) @stmt")
	local stmts = {}
	for _, node in query:iter_captures(root, buf) do
		local flow_nodes, arrow = {}, nil
		for child in node:iter_children() do
			local t = child:type()
			if t == "flow_node" then
				flow_nodes[#flow_nodes + 1] = child
			elseif t:find("^flow_link") then
				arrow = vim.treesitter.get_node_text(child, buf)
			end
		end
		if #flow_nodes >= 2 then
			local src, tgt = flow_nodes[1], flow_nodes[#flow_nodes]
			local sr = node:start()
			local line = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
			local tgt_shape = shape_node_of(tgt)
			stmts[#stmts + 1] = {
				row = sr,
				indent = line:match("^%s*") or "",
				-- A plain edge: exactly two single-vertex nodes (`SRC <arrow> TGT`).
				-- Chained one-liners and `&` branches are collapsed here to their
				-- first/last node, so `plain` flags whether src_text/tgt_text fully
				-- describe the statement (they don't for a chain or a branch).
				plain = #flow_nodes == 2 and vertex_count(src) == 1 and vertex_count(tgt) == 1,
				src_id = node_id(src, buf),
				-- Full verbatim source text: the source may itself carry a
				-- shape/label (e.g. the first line's `start([Start])`), which
				-- must survive a rewrite.
				src_text = vim.treesitter.get_node_text(src, buf),
				arrow = arrow or "-->",
				tgt_id = node_id(tgt, buf),
				tgt_text = vim.treesitter.get_node_text(tgt, buf),
				tgt_shape = tgt_shape and { shape_delims(tgt_shape, buf) } or nil,
			}
		end
	end
	table.sort(stmts, function(a, b)
		return a.row < b.row
	end)
	return stmts
end

local function index_of_row(stmts, row)
	for i, s in ipairs(stmts) do
		if s.row == row then
			return i
		end
	end
	return nil
end

-- Set of all ids used across the collected statements.
local function id_set(stmts)
	local ids = {}
	for _, s in ipairs(stmts) do
		if s.src_id then
			ids[s.src_id] = true
		end
		if s.tgt_id then
			ids[s.tgt_id] = true
		end
	end
	return ids
end

-- Turn a label into a snake_case id.
local function slugify(label)
	local s = label:lower()
	s = s:gsub("<%s*br%s*/?%s*>", " ") -- drop <br> tags
	s = s:gsub("[^%w]+", "_")
	s = s:gsub("^_+", ""):gsub("_+$", "")
	if s == "" then
		s = "step"
	end
	return s
end

-- Make `base` unique against the `ids` set by appending _2, _3, ...
local function unique_id(base, ids)
	if not ids[base] then
		return base
	end
	local i = 2
	while ids[base .. "_" .. i] do
		i = i + 1
	end
	return base .. "_" .. i
end

-- Every flow_vertex_id text in the tree, as a set. Used for de-duping new ids;
-- unlike id_set() it also sees the interior nodes of chained one-liners.
local function all_ids(root, buf)
	local ids = {}
	local function walk(node)
		if node:type() == "flow_vertex_id" then
			ids[vim.treesitter.get_node_text(node, buf)] = true
		end
		for child in node:iter_children() do
			walk(child)
		end
	end
	walk(root)
	return ids
end

-- The flow_stmt_vertice that begins on buffer `row`, or nil.
local function stmt_at_row(root, buf, row)
	local query = vim.treesitter.query.parse("mermaid", "(flow_stmt_vertice) @stmt")
	for _, node in query:iter_captures(root, buf) do
		if node:start() == row then
			return node
		end
	end
	return nil
end

-- Break a statement into ordered *groups* separated by arrows; each group is a
-- list of vertices (more than one when joined by `&`). This is the general
-- shape: a plain edge is two single-vertex groups, a chained one-liner is three
-- or more groups, and `A & B --> C` / `A --> B & C` are multi-vertex groups.
local function group_parts(stmt, buf)
	local groups, arrows = {}, {}
	for child in stmt:iter_children() do
		local t = child:type()
		if t == "flow_node" then
			local vertices = {}
			for v in child:iter_children() do
				if v:type() == "flow_vertex" then
					local _, scol, _, ecol = v:range()
					local sh = vertex_shape_node(v)
					local id = find_descendant(v, "flow_vertex_id")
					vertices[#vertices + 1] = {
						id = id and vim.treesitter.get_node_text(id, buf) or nil,
						text = vim.treesitter.get_node_text(v, buf),
						scol = scol,
						ecol = ecol,
						shape = sh and { shape_delims(sh, buf) } or nil,
					}
				end
			end
			groups[#groups + 1] = vertices
		elseif t:find("^flow_link") then
			arrows[#arrows + 1] = vim.treesitter.get_node_text(child, buf)
		end
	end
	local row = stmt:start()
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	return { row = row, indent = line:match("^%s*") or "", groups = groups, arrows = arrows }
end

-- A plain `SRC <arrow> TGT` edge: two single-vertex groups. These keep the
-- id-threaded multi-line behaviour; everything else edits in place.
local function is_simple(parts)
	return #parts.groups == 2 and #parts.groups[1] == 1 and #parts.groups[2] == 1
end

-- Locate the cursor: which group, and which vertex within it. On an arrow or
-- whitespace, the nearest preceding vertex wins.
local function locate(parts, col)
	col = col or 0
	local bg, bv = 1, 1
	for gi, group in ipairs(parts.groups) do
		for vi, v in ipairs(group) do
			if col >= v.scol and col < v.ecol then
				return gi, vi
			end
			if v.scol <= col then
				bg, bv = gi, vi
			end
		end
	end
	return bg, bv
end

-- Render a statement from group/arrow tables back to a single line. A group is a
-- list of vertex records (`.text`) or raw strings; `&`-joined within the group.
local function render_groups(indent, groups, arrows)
	local function group_text(group)
		local segs = {}
		for i, v in ipairs(group) do
			segs[i] = type(v) == "table" and v.text or v
		end
		return table.concat(segs, " & ")
	end
	local out = indent .. group_text(groups[1])
	for i = 2, #groups do
		local arrow = arrows[i - 1] or arrows[#arrows] or "-->"
		out = out .. " " .. arrow .. " " .. group_text(groups[i])
	end
	return out
end

local function copy_list(t)
	local out = {}
	for i, v in ipairs(t) do
		out[i] = v
	end
	return out
end

-- In-place swap of two adjacent steps on one line. With `dir`, the vertex under
-- the cursor swaps with its `&`-sibling if there is one (reordering branches),
-- otherwise with the adjacent group (reordering a chain). Returns true if a swap
-- happened, false (and a notice) at a boundary.
local function inline_swap(buf, parts, gi, vi, dir)
	local group = parts.groups[gi]
	-- Sibling within the same `&` group.
	if group[vi + dir] then
		local groups = {}
		for i, g in ipairs(parts.groups) do
			groups[i] = (i == gi) and copy_list(g) or g
		end
		groups[gi][vi], groups[gi][vi + dir] = groups[gi][vi + dir], groups[gi][vi]
		vim.api.nvim_buf_set_lines(buf, parts.row, parts.row + 1, false, {
			render_groups(parts.indent, groups, parts.arrows),
		})
		return true
	end
	-- Adjacent group in a chained one-liner (3+ groups).
	if #parts.groups > 2 and parts.groups[gi + dir] then
		local groups = copy_list(parts.groups)
		groups[gi], groups[gi + dir] = groups[gi + dir], groups[gi]
		vim.api.nvim_buf_set_lines(buf, parts.row, parts.row + 1, false, {
			render_groups(parts.indent, groups, parts.arrows),
		})
		return true
	end
	return false
end

-- Splice a new step into a line in place, after the cursor's group `gi`. The new
-- node takes the shape of the first vertex of the following group (or
-- opts.default_shape at the chain's end). Returns the new id.
local function inline_insert(buf, parts, gi, label, opts, ids)
	local follow = parts.groups[gi + 1]
	local open, close
	if follow and follow[1] and follow[1].shape then
		open, close = follow[1].shape[1], follow[1].shape[2]
	else
		local sh = shapes.by_name((opts and opts.default_shape) or "square") or shapes.by_name("square")
		open, close = sh.open, sh.close
	end
	local new_id = unique_id(slugify(label), ids)
	local groups = copy_list(parts.groups)
	local arrows = copy_list(parts.arrows)
	table.insert(groups, gi + 1, { { text = new_id .. open .. label .. close } })
	-- Duplicate the arrow that bridged group gi so both new gaps keep its style.
	table.insert(arrows, gi, parts.arrows[gi] or parts.arrows[#parts.arrows] or "-->")
	vim.api.nvim_buf_set_lines(buf, parts.row, parts.row + 1, false, {
		render_groups(parts.indent, groups, arrows),
	})
	return new_id
end

-- Remove the vertex under the cursor from a line in place. A vertex with `&`
-- siblings is dropped from its group (`A & B & C` -> `A & C`); a lone vertex
-- takes its whole group and one adjoining arrow with it (`A --> B --> C` ->
-- `A --> C`). Returns true if something was removed, false at the last step.
local function inline_remove(buf, parts, gi, vi)
	local group = parts.groups[gi]
	if #group > 1 then
		local groups = {}
		for i, g in ipairs(parts.groups) do
			if i == gi then
				local ng = {}
				for j, v in ipairs(g) do
					if j ~= vi then
						ng[#ng + 1] = v
					end
				end
				groups[i] = ng
			else
				groups[i] = g
			end
		end
		vim.api.nvim_buf_set_lines(buf, parts.row, parts.row + 1, false, {
			render_groups(parts.indent, groups, parts.arrows),
		})
		return true
	end
	-- Lone vertex: drop the whole group plus one adjoining arrow.
	if #parts.groups <= 1 then
		return false
	end
	local groups = {}
	for i, g in ipairs(parts.groups) do
		if i ~= gi then
			groups[#groups + 1] = g
		end
	end
	local arrows = copy_list(parts.arrows)
	table.remove(arrows, (gi > 1) and (gi - 1) or gi)
	vim.api.nvim_buf_set_lines(buf, parts.row, parts.row + 1, false, {
		render_groups(parts.indent, groups, arrows),
	})
	return true
end

-- Insert a new step between SRC and TGT on the edge at `row`:
--   SRC <arrow> TGT[..]   ->   SRC <arrow> NEW<shape>label<close>
--                              NEW <arrow> TGT[..]
-- The new node matches the target's shape (opts.default_shape when the target is
-- a bare id). Returns the new id on success, nil otherwise.
--
-- On a chained one-liner (`A --> B --> C`) or a branch line (`A & B --> C`,
-- `A --> B & C`) the new step is spliced in after the group under `col`, in
-- place, instead of splitting the line.
function M.insert_between(buf, row, label, opts, col)
	opts = opts or {}
	if not label or label == "" then
		return nil
	end
	local root = parse(buf)
	if not root then
		return nil
	end
	local stmt_node = stmt_at_row(root, buf, row)
	if stmt_node then
		local parts = group_parts(stmt_node, buf)
		if not is_simple(parts) then
			local gi = locate(parts, col)
			return inline_insert(buf, parts, gi, label, opts, all_ids(root, buf))
		end
	end
	local stmts = collect_stmts(buf, root)
	local idx = index_of_row(stmts, row)
	if not idx then
		warn("no edge on this line")
		return nil
	end
	local stmt = stmts[idx]
	local new_id = unique_id(slugify(label), id_set(stmts))

	local open, close
	if stmt.tgt_shape then
		open, close = stmt.tgt_shape[1], stmt.tgt_shape[2]
	else
		local sh = shapes.by_name(opts.default_shape or "square") or shapes.by_name("square")
		open, close = sh.open, sh.close
	end

	-- line1 keeps the source verbatim (preserving any source shape/label) and
	-- introduces the new node; line2 references the new id (now defined) and
	-- carries the original target verbatim.
	local line1 = string.format("%s%s %s %s%s%s%s", stmt.indent, stmt.src_text, stmt.arrow, new_id, open, label, close)
	local line2 = string.format("%s%s %s %s", stmt.indent, new_id, stmt.arrow, stmt.tgt_text)
	vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { line1, line2 })
	return new_id
end

-- A node's definition text (id + shape/label), taken from any statement that
-- mentions it - as a target first, but also as a source, since a root node's
-- shape/label only ever appears on the source side (`start([Start]) --> a`).
-- Falls back to the bare id when no statement carries a shape/label for it.
local function def_for(stmts, id)
	for _, s in ipairs(stmts) do
		if s.tgt_id == id and s.tgt_text ~= id then
			return s.tgt_text
		end
		if s.src_id == id and s.src_text ~= id then
			return s.src_text
		end
	end
	return id
end

-- Swap two steps X and Y connected by `X <arrow> Y`. The two nodes trade graph
-- positions, which is a *transposition* of their ids across the whole diagram:
-- every edge endpoint that was X becomes Y and vice versa. This handles all
-- shapes uniformly - the connecting edge reverses (X-->Y becomes Y-->X), edges
-- into/out of either node follow it, and fan-in (a merge) and fan-out (a branch)
-- stay connected - while each node keeps its own label.
--
-- Only the lines that mention X or Y are rewritten (the caller has already
-- guaranteed every such line is a plain edge). Each node's label is rendered on
-- a target side, or on the source when the node is never a target, so a node is
-- defined at least once and bare ids resolve.
local function swap_nodes(buf, stmts, idX, idY)
	local function tau(id)
		if id == idX then
			return idY
		elseif id == idY then
			return idX
		end
		return id
	end
	-- Ids that appear as a target after the swap; these carry their label there,
	-- so a source-only node is the one that must show its label on the source.
	local is_target = {}
	for _, s in ipairs(stmts) do
		if s.tgt_id then
			is_target[tau(s.tgt_id)] = true
		end
	end
	for _, s in ipairs(stmts) do
		if s.src_id == idX or s.src_id == idY or s.tgt_id == idX or s.tgt_id == idY then
			local nsrc, ntgt = tau(s.src_id), tau(s.tgt_id)
			local src_part = is_target[nsrc] and nsrc or def_for(stmts, nsrc)
			local tgt_part = def_for(stmts, ntgt)
			local new_line = string.format("%s%s %s %s", s.indent, src_part, s.arrow, tgt_part)
			vim.api.nvim_buf_set_lines(buf, s.row, s.row + 1, false, { new_line })
		end
	end
	return true
end

local function swap(buf, row, dir, col)
	local root = parse(buf)
	if not root then
		return false
	end
	-- Chained one-liners and `&` branches reorder in place: the vertex under the
	-- cursor swaps with its `&`-sibling, else its adjacent group. A plain edge or
	-- a boundary falls through to the id-threaded multi-line swap below.
	-- A one-liner / `&` line is self-contained: it is edited in place and never
	-- falls through to the id-threaded path (whose collapsed view would mangle
	-- it), so a chain boundary is simply a no-op.
	local stmt_node = stmt_at_row(root, buf, row)
	if stmt_node then
		local parts = group_parts(stmt_node, buf)
		if not is_simple(parts) then
			local gi, vi = locate(parts, col)
			if not inline_swap(buf, parts, gi, vi, dir) then
				warn("no step to swap with on this line")
				return false
			end
			return true
		end
	end
	-- Multi-line: find the connecting edge X --> Y by id. Moving this line's step
	-- down means X is its target and Y is X's successor; moving up means this line
	-- itself is the X --> Y edge.
	local stmts = collect_stmts(buf, root)
	local fi = index_of_row(stmts, row)
	if not fi then
		warn("no edge on this line")
		return false
	end
	local focused = stmts[fi]
	local conn
	if dir > 0 then
		local X = focused.tgt_id
		for _, s in ipairs(stmts) do
			if s.src_id == X then
				conn = s
				break
			end
		end
	else
		conn = focused
	end
	if not conn or not conn.src_id or not conn.tgt_id then
		warn("no neighbouring step to swap with")
		return false
	end
	-- The id-threaded rewrite below rebuilds every line that mentions either id as
	-- a plain `src arrow tgt`. A chained one-liner or `&` branch is collapsed to
	-- its first/last node, so rewriting one would silently drop its interior
	-- nodes. Refuse rather than destroy; that line must be edited in place.
	for _, s in ipairs(stmts) do
		local touches = s.src_id == conn.src_id
			or s.tgt_id == conn.src_id
			or s.src_id == conn.tgt_id
			or s.tgt_id == conn.tgt_id
		if touches and not s.plain then
			warn(
				"can't swap `"
					.. conn.src_id
					.. "`/`"
					.. conn.tgt_id
					.. "`: one also appears in a chained one-liner or `&` branch - edit that line directly"
			)
			return false
		end
	end
	return swap_nodes(buf, stmts, conn.src_id, conn.tgt_id)
end

function M.swap_down(buf, row, col)
	return swap(buf, row, 1, col)
end

function M.swap_up(buf, row, col)
	return swap(buf, row, -1, col)
end

-- Remove node `id` from the diagram and bridge the gap so the chain stays
-- connected: every predecessor P (an edge `P --> id`) is reconnected to every
-- successor Q (an edge `id --> Q`), reusing the predecessor's arrow style. A
-- leaf (no successors) or a root (no predecessors) leaves no bridge, so its
-- edges are simply dropped. The bridge lines replace the first removed line;
-- the rest are deleted.
local function remove_node(buf, stmts, id)
	local ins, outs, del = {}, {}, {}
	for _, s in ipairs(stmts) do
		local touches = s.tgt_id == id or s.src_id == id
		-- A chained one-liner or `&` branch is collapsed to its first/last node, so
		-- deleting its whole row to bridge would silently drop the line's interior
		-- nodes. Refuse rather than destroy; that line must be edited in place.
		if touches and not s.plain then
			warn("can't remove `" .. id .. "`: it also appears in a chained one-liner or `&` branch - edit that line directly")
			return false
		end
		if s.tgt_id == id then
			ins[#ins + 1] = s
			del[s.row] = true
		end
		if s.src_id == id then
			outs[#outs + 1] = s
			del[s.row] = true
		end
	end
	local rows = {}
	for r in pairs(del) do
		rows[#rows + 1] = r
	end
	if #rows == 0 then
		warn("no node under the cursor to remove")
		return false
	end
	table.sort(rows)
	local bridges = {}
	for _, si in ipairs(ins) do
		for _, so in ipairs(outs) do
			bridges[#bridges + 1] = string.format("%s%s %s %s", si.indent, si.src_text, si.arrow, so.tgt_text)
		end
	end
	-- Delete trailing rows first (descending) so the anchor index stays valid,
	-- then replace the anchor line with the bridges (or nothing).
	for i = #rows, 2, -1 do
		vim.api.nvim_buf_set_lines(buf, rows[i], rows[i] + 1, false, {})
	end
	vim.api.nvim_buf_set_lines(buf, rows[1], rows[1] + 1, false, bridges)
	return true
end

-- Remove the node under the cursor. On a chained one-liner or `&` branch line the
-- vertex is spliced out in place; on a plain edge the node's id is removed across
-- the whole diagram and the gap is bridged.
function M.remove(buf, row, col)
	local root = parse(buf)
	if not root then
		return false
	end
	local stmt_node = stmt_at_row(root, buf, row)
	if stmt_node then
		local parts = group_parts(stmt_node, buf)
		if not is_simple(parts) then
			local gi, vi = locate(parts, col)
			if not inline_remove(buf, parts, gi, vi) then
				warn("nothing left to remove on this line")
				return false
			end
			return true
		end
		local stmts = collect_stmts(buf, root)
		local gi, vi = locate(parts, col)
		local id = parts.groups[gi][vi] and parts.groups[gi][vi].id
		if not id then
			warn("place the cursor on a node to remove it")
			return false
		end
		return remove_node(buf, stmts, id)
	end
	warn("no node on this line")
	return false
end

-- Change the shape of the flow_vertex under `pos` ({row, col}, 0-indexed) to the
-- named shape, preserving the label verbatim. Targeting the vertex (not the
-- flow_node) means it works on any member of an `&` group. Returns true on
-- success.
function M.change_shape(buf, pos, shape_name)
	local root = parse(buf)
	if not root then
		return false
	end
	local sh = shapes.by_name(shape_name)
	if not sh then
		warn("unknown shape: " .. tostring(shape_name))
		return false
	end
	local node = root:named_descendant_for_range(pos[1], pos[2], pos[1], pos[2])
	while node and node:type() ~= "flow_vertex" do
		node = node:parent()
	end
	if not node then
		warn("place the cursor on a node to reshape it")
		return false
	end
	local shape_node = vertex_shape_node(node)
	if not shape_node then
		warn("this node has no label to reshape (it is a bare id reference)")
		return false
	end
	local label = shape_label(shape_node, buf)
	local sr, sc, er, ec = shape_node:range()
	vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, { sh.open .. label .. sh.close })
	return true
end

-- Exposed for tests / advanced use.
M._collect_stmts = collect_stmts
M._parse = parse
M._slugify = slugify

return M
