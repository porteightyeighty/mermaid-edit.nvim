-- Headless tests for mermaid-edit.er.core (the erDiagram engine).
-- Run with: nvim --headless -l tests/test_er.lua  (from the repo root)
-- Exits non-zero if any assertion fails.

-- Load the plugin from this checkout (the directory above tests/).
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local er = require("mermaid-edit.er.core")
local relations = require("mermaid-edit.er.relations")
local keys = require("mermaid-edit.er.keys")

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   - " .. name)
	else
		failures = failures + 1
		print("FAIL - " .. name .. (detail and ("\n        " .. detail) or ""))
	end
end

local function make_buf(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

local function get_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function parses_clean(buf)
	local parser = vim.treesitter.get_parser(buf, "mermaid")
	return not parser:parse()[1]:root():has_error()
end

-- A clean erDiagram fixture: two relations and a CUSTOMER attribute block.
local function fixture()
	return make_buf({
		"erDiagram",
		"  CUSTOMER ||--o{ ORDER : places",
		"  ORDER ||--|{ LINE_ITEM : contains",
		"  CUSTOMER {",
		"    string name PK",
		"    int age",
		"  }",
	})
end

----------------------------------------------------------------------
-- diagram_type: routes erDiagram vs flowchart vs neither
----------------------------------------------------------------------
do
	check("type: erDiagram detected", er.diagram_type(fixture()) == "er")
	check("type: flowchart detected", er.diagram_type(make_buf({ "flowchart LR", "  a --> b" })) == "flow")
	check("type: nil for non-diagram", er.diagram_type(make_buf({ "hello world" })) == nil)
end

----------------------------------------------------------------------
-- change_relation: restyle the marker, keep entities and role
----------------------------------------------------------------------
do
	local buf = fixture()
	check("relation: current marker reported", er.relation_marker(buf, 1) == "||--o{")
	local okk = er.change_relation(buf, 1, "}o..|{")
	local lines = get_lines(buf)
	check("relation: returns true", okk == true)
	check("relation: marker changed, operands kept", lines[2] == "  CUSTOMER }o..|{ ORDER : places", "got: " .. lines[2])
	check("relation: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- set_role: edit, and add to a (rare) role-less relation; empty is refused
----------------------------------------------------------------------
do
	local buf = fixture()
	check("role: current role reported", er.role_text(buf, 1) == "places")
	er.set_role(buf, 1, "submits")
	local lines = get_lines(buf)
	check("role: edited in place", lines[2] == "  CUSTOMER ||--o{ ORDER : submits", "got: " .. lines[2])
	check("role: empty input refused (grammar needs a label)", er.set_role(buf, 1, "") == false)
	check("role: edit parses clean", parses_clean(buf))
	-- a multi-word role is auto-quoted so it parses; role_text reports it bare.
	er.set_role(buf, 1, "places order for")
	check("role: multi-word auto-quoted", get_lines(buf)[2] == '  CUSTOMER ||--o{ ORDER : "places order for"', "got: " .. get_lines(buf)[2])
	check("role: quoted role parses clean", parses_clean(buf))
	check("role: role_text reports unquoted", er.role_text(buf, 1) == "places order for")
end

----------------------------------------------------------------------
-- add_attribute: into a populated block (matches sibling indent), `}` last
----------------------------------------------------------------------
do
	local buf = fixture()
	local okk = er.add_attribute(buf, 4, "string", "email", "FK")
	local lines = get_lines(buf)
	check("attr-add: returns true", okk == true)
	check("attr-add: appended after last attribute", lines[7] == "    string email FK", "got: " .. lines[7])
	check("attr-add: closing brace stays last", lines[8] == "  }", "got: " .. lines[8])
	check("attr-add: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- add_attribute: into an empty block inserts before the `}`
----------------------------------------------------------------------
do
	local buf = make_buf({ "erDiagram", "  ACCOUNT {", "  }" })
	er.add_attribute(buf, 1, "int", "id", "PK")
	local lines = get_lines(buf)
	check("attr-empty: attribute inserted", lines[3] == "      int id PK", "got: " .. lines[3])
	check("attr-empty: brace remains after it", lines[4] == "  }", "got: " .. lines[4])
	check("attr-empty: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- change_attribute_key: none -> PK -> FK -> none, type/name preserved
----------------------------------------------------------------------
do
	local buf = fixture() -- row 5 (0-idx) = "    int age"
	er.change_attribute_key(buf, 5, "PK")
	check("key: none -> PK", get_lines(buf)[6] == "    int age PK", "got: " .. get_lines(buf)[6])
	er.change_attribute_key(buf, 5, "FK")
	check("key: PK -> FK", get_lines(buf)[6] == "    int age FK", "got: " .. get_lines(buf)[6])
	er.change_attribute_key(buf, 5, "")
	check("key: FK -> none (token + space dropped)", get_lines(buf)[6] == "    int age", "got: [" .. get_lines(buf)[6] .. "]")
	check("key: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- change_attribute_type: swaps type, keeps name/key
----------------------------------------------------------------------
do
	local buf = fixture() -- row 4 = "    string name PK"
	check("type: current type reported", er.attribute_type_at(buf, 4) == "string")
	er.change_attribute_type(buf, 4, "uuid")
	check("type: string -> uuid, name+key kept", get_lines(buf)[5] == "    uuid name PK", "got: " .. get_lines(buf)[5])
	check("type: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- move_attribute: reorder within a block, no-op at boundaries
----------------------------------------------------------------------
do
	local buf = fixture() -- rows 4,5 = name, age
	local okk = er.move_attribute(buf, 4, 1)
	local lines = get_lines(buf)
	check("move: returns true", okk == true)
	check("move: name moved below age", lines[5] == "    int age" and lines[6] == "    string name PK", table.concat(lines, "|"))
	check("move: still parses clean", parses_clean(buf))
	-- name is now last; moving it down again is a boundary no-op.
	check("move: bottom boundary is a no-op", er.move_attribute(buf, 5, 1) == false)
	check("move: top boundary is a no-op", er.move_attribute(buf, 4, -1) == false)
end

----------------------------------------------------------------------
-- remove: attribute line vs whole relation line
----------------------------------------------------------------------
do
	local buf = fixture()
	er.remove_at(buf, 5) -- "    int age"
	local lines = get_lines(buf)
	check("remove-attr: attribute line gone", lines[6] == "  }" and #lines == 6, table.concat(lines, "|"))
	check("remove-attr: still parses clean", parses_clean(buf))
end

do
	local buf = fixture()
	er.remove_at(buf, 2) -- "  ORDER ||--|{ LINE_ITEM : contains"
	local lines = get_lines(buf)
	check("remove-rel: relation line gone", lines[3] == "  CUSTOMER {", table.concat(lines, "|"))
	check("remove-rel: other relation untouched", lines[2] == "  CUSTOMER ||--o{ ORDER : places")
	check("remove-rel: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- rename_entity: propagates across every relation operand and the block header
----------------------------------------------------------------------
do
	local buf = fixture()
	-- cursor on CUSTOMER in line 2 (the relation source)
	local okk = er.rename_entity(buf, 1, 2, "CLIENT")
	local lines = get_lines(buf)
	check("rename: returns true", okk == true)
	check("rename: relation source rewritten", lines[2] == "  CLIENT ||--o{ ORDER : places", "got: " .. lines[2])
	check("rename: block header rewritten", lines[4] == "  CLIENT {", "got: " .. lines[4])
	check("rename: unrelated entity untouched", lines[3] == "  ORDER ||--|{ LINE_ITEM : contains", "got: " .. lines[3])
	check("rename: still parses clean", parses_clean(buf))
end

do
	-- partial-substring safety: renaming ORDER must not touch ORDER_LINE.
	local buf = make_buf({
		"erDiagram",
		"  ORDER ||--o{ ORDER_LINE : has",
		"  ORDER {",
		"    int id PK",
		"  }",
	})
	er.rename_entity(buf, 1, 2, "PURCHASE")
	local lines = get_lines(buf)
	check("rename-substr: ORDER renamed", lines[2] == "  PURCHASE ||--o{ ORDER_LINE : has", "got: " .. lines[2])
	check("rename-substr: ORDER_LINE intact", lines[2]:find("ORDER_LINE", 1, true) ~= nil)
	check("rename-substr: header renamed", lines[3] == "  PURCHASE {", "got: " .. lines[3])
	check("rename-substr: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- add_relation: appends a clean, role-bearing line
----------------------------------------------------------------------
do
	local buf = fixture()
	local okk = er.add_relation(buf, 1, "ORDER", "||--||", "INVOICE", "bills")
	local lines = get_lines(buf)
	check("add-rel: returns true", okk == true)
	check("add-rel: inserted after the anchor relation", lines[3] == "  ORDER ||--|| INVOICE : bills", "got: " .. lines[3])
	check("add-rel: still parses clean", parses_clean(buf))
end

do
	-- defaults fill in for a blank marker/role.
	local buf = fixture()
	er.add_relation(buf, 1, "A", "", "B", "")
	check("add-rel: defaults applied (multi-word role quoted)", get_lines(buf)[3] == '  A ||--o{ B : "relates to"', "got: " .. get_lines(buf)[3])
	check("add-rel: default line parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- parse-error guard: an unlabelled relation makes ops no-op
----------------------------------------------------------------------
do
	local buf = make_buf({ "erDiagram", "  A ||--o{ B" }) -- no role: grammar errors
	local before = get_lines(buf)
	local okk = er.change_relation(buf, 1, "}o..|{")
	check("error-guard: change_relation refuses on error tree", okk == false)
	check("error-guard: buffer unchanged", vim.deep_equal(before, get_lines(buf)))
end

----------------------------------------------------------------------
-- every offered marker (left x line x right) and key token applies cleanly.
-- Guards against re-introducing a token the grammar can't parse (the way the
-- arrow suite guards `-.-`): all combinations must parse and round-trip.
----------------------------------------------------------------------
do
	for _, left in ipairs(relations.left) do
		for _, line in ipairs(relations.line) do
			for _, right in ipairs(relations.right) do
				local marker = left.token .. line.token .. right.token
				local buf = make_buf({ "erDiagram", "  A ||--o{ B : x" })
				local okk = er.change_relation(buf, 1, marker)
				local got = get_lines(buf)[2]
				check(
					"markers: '" .. marker .. "' applies cleanly",
					okk == true and parses_clean(buf) and got == "  A " .. marker .. " B : x",
					"got: " .. got
				)
				-- split() must round-trip the marker it produced.
				local s = relations.split(marker)
				check(
					"markers: '" .. marker .. "' splits back",
					s and s.left == left.token and s.line == line.token and s.right == right.token,
					vim.inspect(s)
				)
			end
		end
	end
end

do
	for _, k in ipairs(keys.list) do
		local buf = make_buf({ "erDiagram", "  A {", "    string x", "  }" })
		er.change_attribute_key(buf, 2, k.token)
		local expected = (k.token == "") and "    string x" or ("    string x " .. k.token)
		check(
			"keys: '" .. k.name .. "' applies cleanly",
			parses_clean(buf) and get_lines(buf)[3] == expected,
			"got: " .. get_lines(buf)[3]
		)
	end
end

----------------------------------------------------------------------
print(string.rep("-", 50))
if failures == 0 then
	print("ALL TESTS PASSED")
	vim.cmd("qall!")
else
	print(failures .. " TEST(S) FAILED")
	vim.cmd("cquit!")
end
