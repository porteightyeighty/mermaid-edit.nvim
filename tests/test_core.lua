-- Headless tests for mermaid-edit.core.
-- Run with: nvim --headless -l tests/test_core.lua  (from the repo root)
-- Exits non-zero if any assertion fails.

vim.opt.runtimepath:append(vim.fn.expand("~/dev/mermaid-edit.nvim"))

local core = require("mermaid-edit.core")

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

-- A clean (<br>) flowchart. Rows: 0 header, 1 start->a, 2 a->b, 3 b->done.
local function fixture()
	return make_buf({
		"flowchart LR",
		"  start([Start]) --> a[Step A]",
		"  a --> b[/Step B\\]",
		"  b --> done([Done])",
	})
end

-- Helper: assert the whole buffer parses without error.
local function parses_clean(buf)
	local parser = vim.treesitter.get_parser(buf, "mermaid")
	return not parser:parse()[1]:root():has_error()
end

-- Helper: every edge line's source id equals the previous edge line's target id.
local function chain_connected(lines)
	local prev_tgt
	for _, line in ipairs(lines) do
		local src, _, rest = line:match("^%s*([%w_]+)%s*(%-%-+>?)%s*(.+)$")
		if src then
			if prev_tgt and src ~= prev_tgt then
				return false, ("broken at: " .. line)
			end
			prev_tgt = rest:match("^([%w_]+)")
		end
	end
	return true
end

----------------------------------------------------------------------
-- insert_between: matches the target's shape, preserves source + target
----------------------------------------------------------------------
do
	local buf = fixture()
	local new_id = core.insert_between(buf, 1, "Intro", { default_shape = "square" })
	local lines = get_lines(buf)
	check("insert: returns slugified id", new_id == "intro", "got " .. tostring(new_id))
	check(
		"insert: source definition preserved (start([Start]))",
		lines[2] == "  start([Start]) --> intro[Intro]",
		"got: " .. lines[2]
	)
	check("insert: new node references original target", lines[3] == "  intro --> a[Step A]", "got: " .. lines[3])
	check("insert: still parses clean", parses_clean(buf))
end

do
	-- Inserting before a trapezoid target gives the new node a trapezoid shape.
	local buf = fixture()
	core.insert_between(buf, 2, "Mid", {})
	local lines = get_lines(buf)
	check("insert: new node matches trapezoid target shape", lines[3] == "  a --> mid[/Mid\\]", "got: " .. lines[3])
	check("insert: trapezoid target moved verbatim", lines[4] == "  mid --> b[/Step B\\]", "got: " .. lines[4])
end

----------------------------------------------------------------------
-- swap_down: reorders two steps, keeps the chain connected
----------------------------------------------------------------------
do
	local buf = fixture()
	local okk = core.swap_down(buf, 1) -- swap step a and step b
	local lines = get_lines(buf)
	check("swap: returns true", okk == true)
	check("swap: source def preserved, B moves up", lines[2] == "  start([Start]) --> b[/Step B\\]", "got: " .. lines[2])
	check("swap: B now references A", lines[3] == "  b --> a[Step A]", "got: " .. lines[3])
	check("swap: following line's source repaired to A", lines[4] == "  a --> done([Done])", "got: " .. lines[4])
	local connected, why = chain_connected(lines)
	check("swap: chain still connected", connected, why)
	check("swap: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- swap_up mirrors swap_down
----------------------------------------------------------------------
do
	local buf = fixture()
	core.swap_up(buf, 2) -- from a->b line, swap with previous (a) => same as swap_down(1)
	local lines = get_lines(buf)
	check("swap_up: equivalent reordering", lines[2] == "  start([Start]) --> b[/Step B\\]", "got: " .. lines[2])
end

----------------------------------------------------------------------
-- swap_down with a merge: a node with two incoming edges. Both incoming
-- edges must follow the node down to its new position.
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  p1 --> sel[Select]",
		"  p2 --> sel[Select]",
		"  sel --> det[/Details\\]",
		"  det --> done([Done])",
	})
	-- Cursor/row on the second incoming edge (p2 --> sel); swap sel and det.
	local okk = core.swap_down(buf, 2)
	local lines = get_lines(buf)
	check("merge-swap: returns true", okk == true)
	check("merge-swap: first incoming edge redirected", lines[2] == "  p1 --> det[/Details\\]", "got: " .. lines[2])
	check("merge-swap: second incoming edge redirected", lines[3] == "  p2 --> det[/Details\\]", "got: " .. lines[3])
	check("merge-swap: connecting edge flipped", lines[4] == "  det --> sel[Select]", "got: " .. lines[4])
	check("merge-swap: following edge source repaired", lines[5] == "  sel --> done([Done])", "got: " .. lines[5])
	check("merge-swap: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- chained one-liner (A --> B --> C): swap reorders in place, positionally
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	-- swap_down with the cursor on B -> A --> C --> B
	local col = line:find("b%[B%]") - 1
	local okk = core.swap_down(buf, 1, col)
	local lines = get_lines(buf)
	check("oneliner-swap: returns true", okk == true)
	check("oneliner-swap: B and C reordered in place", lines[2] == "  a[A] --> c[C] --> b[B]", "got: " .. lines[2])
	check("oneliner-swap: still parses clean", parses_clean(buf))
end

do
	-- swap_up from the last node mirrors swap_down from the middle.
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("c%[C%]") - 1
	core.swap_up(buf, 1, col)
	local lines = get_lines(buf)
	check("oneliner-swap_up: C moves left of B", lines[2] == "  a[A] --> c[C] --> b[B]", "got: " .. lines[2])
end

do
	-- swap at the chain boundary has no neighbour; it is a no-op.
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("a%[A%]") - 1
	local okk = core.swap_up(buf, 1, col)
	check("oneliner-swap: boundary is a no-op", okk == false)
end

----------------------------------------------------------------------
-- chained one-liner: insert splices a node in place, matching next shape
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	-- cursor on B; insert after B, before C (matches C's square shape)
	local col = line:find("b%[B%]") - 1
	local new_id = core.insert_between(buf, 1, "Mid", {}, col)
	local lines = get_lines(buf)
	check("oneliner-insert: returns id", new_id == "mid", "got " .. tostring(new_id))
	check(
		"oneliner-insert: spliced after cursor node",
		lines[2] == "  a[A] --> b[B] --> mid[Mid] --> c[C]",
		"got: " .. lines[2]
	)
	check("oneliner-insert: still parses clean", parses_clean(buf))
end

do
	-- Inserting on the last node appends to the chain (default square shape).
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("c%[C%]") - 1
	core.insert_between(buf, 1, "Tail", { default_shape = "square" }, col)
	local lines = get_lines(buf)
	check(
		"oneliner-insert: appends at chain end",
		lines[2] == "  a[A] --> b[B] --> c[C] --> tail[Tail]",
		"got: " .. lines[2]
	)
end

----------------------------------------------------------------------
-- branching with `&`: reorder siblings, splice into the transition, reshape
----------------------------------------------------------------------
do
	-- fan-out: swap the two branch targets in place.
	local buf = make_buf({
		"flowchart LR",
		"  a --> b & c",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("b") - 1
	local okk = core.swap_down(buf, 1, col)
	local lines = get_lines(buf)
	check("amp-swap: fan-out siblings reorder", okk == true and lines[2] == "  a --> c & b", "got: " .. lines[2])
	check("amp-swap: still parses clean", parses_clean(buf))
end

do
	-- fan-in: swap the two branch sources in place.
	local buf = make_buf({
		"flowchart LR",
		"  a & b --> c",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("b") - 1
	core.swap_up(buf, 1, col)
	local lines = get_lines(buf)
	check("amp-swap: fan-in siblings reorder", lines[2] == "  b & a --> c", "got: " .. lines[2])
end

do
	-- insert between the `&` group and the next node: splits the transition,
	-- keeping the group intact.
	local buf = make_buf({
		"flowchart LR",
		"  a & b --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("a") - 1
	local new_id = core.insert_between(buf, 1, "Gate", {}, col)
	local lines = get_lines(buf)
	check("amp-insert: returns id", new_id == "gate", "got " .. tostring(new_id))
	check("amp-insert: spliced after the group, shape matches C", lines[2] == "  a & b --> gate[Gate] --> c[C]", "got: " .. lines[2])
	check("amp-insert: still parses clean", parses_clean(buf))
end

do
	-- change_shape reaches a vertex inside an `&` group.
	local buf = make_buf({
		"flowchart LR",
		"  a --> b[B] & c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("c%[C%]") - 1
	local okk = core.change_shape(buf, { 1, col }, "Circle")
	local lines = get_lines(buf)
	check("amp-reshape: reshapes the second branch only", okk == true and lines[2] == "  a --> b[B] & c((C))", "got: " .. lines[2])
	check("amp-reshape: still parses clean", parses_clean(buf))
end

do
	-- multi-line fan-out: the existing id-threaded swap still applies to a plain
	-- edge whose source also branches elsewhere.
	local buf = make_buf({
		"flowchart LR",
		"  d --> x[X]",
		"  d --> y[Y]",
		"  x --> z[Z]",
	})
	-- swap x and z via the x --> z line (move z up past x); the connecting edge is
	-- found by id even though the d --> y branch sits between the references.
	local okk = core.swap_up(buf, 3)
	local lines = get_lines(buf)
	check("multiline-branch: returns true", okk == true)
	check("multiline-branch: incoming edge redirected to Z", lines[2] == "  d --> z[Z]", "got: " .. lines[2])
	check("multiline-branch: sibling branch untouched", lines[3] == "  d --> y[Y]", "got: " .. lines[3])
	check("multiline-branch: connecting edge flipped", lines[4] == "  z --> x[X]", "got: " .. lines[4])
	check("multiline-branch: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- swap transposition: X's *other* out-edge follows it to Y (fan-out from X)
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  x[X] --> y[Y]",
		"  x --> w[W]",
	})
	local okk = core.swap_up(buf, 1) -- swap x and y
	local lines = get_lines(buf)
	check("swap-fanout: returns true", okk == true)
	-- y takes x's place (the fork) and keeps its own label; the x --> w edge moves
	-- to y --> w. The old code left it as x --> w and dropped y's [Y] label.
	check("swap-fanout: connecting edge flipped, labels kept", lines[2] == "  y[Y] --> x[X]", "got: " .. lines[2])
	check("swap-fanout: x's other out-edge follows to y", lines[3] == "  y[Y] --> w[W]", "got: " .. lines[3])
	check("swap-fanout: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- swap transposition: Y's *other* in-edge follows it to X (fan-in to Y)
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  x[X] --> y[Y]",
		"  z[Z] --> y",
	})
	core.swap_up(buf, 1) -- swap x and y
	local lines = get_lines(buf)
	-- x becomes the merge point; z's edge redirects to x. The old code left z --> y.
	check("swap-fanin: connecting edge flipped", lines[2] == "  y[Y] --> x[X]", "got: " .. lines[2])
	check("swap-fanin: z's edge redirected to the swapped node", lines[3] == "  z[Z] --> x[X]", "got: " .. lines[3])
	check("swap-fanin: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- swap transposition: a diamond keeps its bottom merge after swapping a side
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B]",
		"  a --> c[C]",
		"  b --> d[D]",
		"  c --> d",
	})
	core.swap_up(buf, 3) -- swap b and d via the b --> d edge
	local lines = get_lines(buf)
	check("swap-diamond: top edge into b redirected to d", lines[2] == "  a[A] --> d[D]", "got: " .. lines[2])
	check("swap-diamond: sibling branch untouched", lines[3] == "  a --> c[C]", "got: " .. lines[3])
	check("swap-diamond: connecting edge flipped", lines[4] == "  d --> b[B]", "got: " .. lines[4])
	-- The c --> d edge must follow d down to b; the old code left it as c --> d.
	check("swap-diamond: bottom merge redirected", lines[5] == "  c --> b[B]", "got: " .. lines[5])
	check("swap-diamond: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- change_shape: rewraps label verbatim, including <br>
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[Line one<br>line two] --> b[End]",
	})
	-- cursor on the label of node a (col within "a[Line one...]")
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("Line") - 1
	local okk = core.change_shape(buf, { 1, col }, "Circle")
	local lines = get_lines(buf)
	check("reshape: returns true", okk == true)
	check(
		"reshape: square -> circle, <br> preserved",
		lines[2] == "  a((Line one<br>line two)) --> b[End]",
		"got: " .. lines[2]
	)
	check("reshape: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- change_shape on a bare id reference bails (no label to reshape)
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B]",
		"  b --> c[C]",
	})
	-- cursor on bare "b" at start of line 3
	local line = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
	local col = line:find("b") - 1
	local okk = core.change_shape(buf, { 2, col }, "Circle")
	check("reshape: bare id reference is rejected", okk == false)
end

----------------------------------------------------------------------
-- parse-error guard: a <br/> makes ops no-op
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[Bad<br/>label] --> b[B]",
	})
	local before = get_lines(buf)
	local result = core.insert_between(buf, 1, "X", {})
	local after = get_lines(buf)
	check("error-guard: insert returns nil on <br/>", result == nil)
	check("error-guard: buffer unchanged on <br/>", vim.deep_equal(before, after))
end

----------------------------------------------------------------------
-- whitespace-only lines are tolerated (grammar quirk, not a real error)
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B]",
		"  b --> c[C]",
		"  ", -- trailing-whitespace-only line: grammar emits a benign ERROR
	})
	local new_id = core.insert_between(buf, 1, "Mid", {})
	local lines = get_lines(buf)
	check("blank-error: insert still works despite trailing-ws line", new_id == "mid", "got " .. tostring(new_id))
	check("blank-error: edit applied", lines[3] == "  mid --> b[B]", "got: " .. tostring(lines[3]))
end

----------------------------------------------------------------------
-- remove: multi-line linear chain, bridge predecessor to successor
----------------------------------------------------------------------
do
	local buf = fixture() -- start->a, a->b, b->done
	-- remove node `a` (cursor on the target of line 2)
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("a%[Step A%]") - 1
	local okk = core.remove(buf, 1, col)
	local lines = get_lines(buf)
	check("remove: returns true", okk == true)
	check("remove: predecessor bridged to successor", lines[2] == "  start([Start]) --> b[/Step B\\]", "got: " .. lines[2])
	check("remove: node line gone, chain intact", lines[3] == "  b --> done([Done])", "got: " .. lines[3])
	check("remove: chain still connected", (chain_connected(lines)))
	check("remove: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- remove: a merge node (two incoming) bridges both predecessors
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  p1 --> sel[Select]",
		"  p2 --> sel[Select]",
		"  sel --> done([Done])",
	})
	-- remove `sel` (cursor on the source of line 4)
	local line = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
	local col = line:find("sel") - 1
	local okk = core.remove(buf, 3, col)
	local lines = get_lines(buf)
	check("remove-merge: returns true", okk == true)
	check("remove-merge: first predecessor bridged", lines[2] == "  p1 --> done([Done])", "got: " .. lines[2])
	check("remove-merge: second predecessor bridged", lines[3] == "  p2 --> done([Done])", "got: " .. lines[3])
	check("remove-merge: only the bridges remain", #lines == 3, "got " .. #lines .. " lines")
	check("remove-merge: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- remove: a leaf (no successors) just drops its incoming edge
----------------------------------------------------------------------
do
	local buf = fixture() -- start->a, a->b, b->done
	local line = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
	local col = line:find("done") - 1
	local okk = core.remove(buf, 3, col)
	local lines = get_lines(buf)
	check("remove-leaf: returns true", okk == true)
	check("remove-leaf: incoming edge dropped", #lines == 3, "got " .. #lines .. " lines")
	check("remove-leaf: prior chain intact", lines[3] == "  a --> b[/Step B\\]", "got: " .. lines[3])
	check("remove-leaf: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- remove: chained one-liner splices the middle node out in place
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a[A] --> b[B] --> c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("b%[B%]") - 1
	local okk = core.remove(buf, 1, col)
	local lines = get_lines(buf)
	check("remove-oneliner: returns true", okk == true)
	check("remove-oneliner: middle node spliced out", lines[2] == "  a[A] --> c[C]", "got: " .. lines[2])
	check("remove-oneliner: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- remove: `&` branch drops just the one sibling, group stays
----------------------------------------------------------------------
do
	local buf = make_buf({
		"flowchart LR",
		"  a --> b[B] & c[C]",
	})
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("b%[B%]") - 1
	local okk = core.remove(buf, 1, col)
	local lines = get_lines(buf)
	check("remove-amp: returns true", okk == true)
	check("remove-amp: only the targeted sibling dropped", lines[2] == "  a --> c[C]", "got: " .. lines[2])
	check("remove-amp: still parses clean", parses_clean(buf))
end

----------------------------------------------------------------------
-- remove: refuse (don't destroy) when the id also spans a one-liner/branch
----------------------------------------------------------------------
do
	-- `x` is the target of a plain edge but also the head of a chained one-liner.
	-- Removing it must not delete the one-liner and drop its interior node `y`.
	local buf = make_buf({
		"flowchart LR",
		"  p --> x[X]",
		"  x --> y[Y] --> z[Z]",
	})
	local before = get_lines(buf)
	local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
	local col = line:find("x%[X%]") - 1
	local okk = core.remove(buf, 1, col)
	local lines = get_lines(buf)
	check("remove-mixed: refuses rather than destroying", okk == false)
	check("remove-mixed: buffer left unchanged (y not dropped)", vim.deep_equal(before, lines))
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
