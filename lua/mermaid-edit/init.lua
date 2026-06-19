-- mermaid-edit.nvim - public API and configuration.
--
-- The functions here are the interactive entry points: they read the current
-- buffer/cursor, detect the diagram kind (flowchart vs erDiagram), prompt via
-- vim.ui where needed, and delegate the actual buffer mutation to the UI-free
-- primitives in mermaid-edit.core / mermaid-edit.er.core.

local core = require("mermaid-edit.core")
local shapes = require("mermaid-edit.shapes")
local arrows = require("mermaid-edit.arrows")
local er = require("mermaid-edit.er.core")
local relations = require("mermaid-edit.er.relations")
local keys = require("mermaid-edit.er.keys")

local M = {}

local defaults = {
	-- Buffer-local keymaps, applied by ftplugin/mermaid.lua.
	-- Set any entry to false to disable just that map, or set `keymaps = false`
	-- to disable all of them and wire your own (the :Mermaid* commands always
	-- work regardless). Each map carries a flowchart and an erDiagram meaning;
	-- the action routes on the diagram kind under the cursor.
	keymaps = {
		insert_step = "<leader>mi", -- flow: insert step / er: add attribute
		add_step = "<leader>mo", -- flow: add step / er: add relationship
		swap_down = "<leader>mj", -- flow: step down / er: attribute down
		swap_up = "<leader>mk", -- flow: step up / er: attribute up
		change_shape = "<leader>ms", -- flow: node shape / er: attribute key
		change_arrow = "<leader>ma", -- flow: edge arrow / er: relationship cardinality
		edit_label = "<leader>ml", -- flow: edge label / er: relationship role
		remove_node = "<leader>md", -- flow: remove node / er: remove attribute or relation
		rename_entity = "<leader>mr", -- er: rename entity everywhere
	},
	-- Shape used for a newly inserted node when the edge's target is a bare id.
	default_shape = "square",
	-- Marker used for a newly added erDiagram relationship.
	default_relation = "||--o{",
	-- Type used for a newly added erDiagram attribute.
	default_attr_type = "string",
}

M.config = nil

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	return M.config
end

-- Resolve config, applying defaults if the user never called setup().
function M.get_config()
	if not M.config then
		M.setup({})
	end
	return M.config
end

-- 0-indexed (row, col) of the cursor; col disambiguates which step of a chained
-- one-liner the operation targets.
local function cursor_pos()
	local c = vim.api.nvim_win_get_cursor(0)
	return c[1] - 1, c[2]
end

-- The kind of diagram in the current buffer: "er", "flow", or nil.
local function kind(buf)
	return er.diagram_type(buf)
end

local function notify(msg)
	vim.notify("mermaid-edit: " .. msg, vim.log.levels.WARN)
end

----------------------------------------------------------------------
-- erDiagram interactive handlers
----------------------------------------------------------------------

-- Compose a relationship marker by picking left cardinality, line type, and
-- right cardinality in turn, each prefilled from the current marker.
local function er_change_relation(buf, row)
	local current = relations.split(er.relation_marker(buf, row) or "")
	local function pick(list_names, list_by_name, prefill, prompt, cont)
		vim.ui.select(list_names(), { prompt = prompt }, function(choice)
			if not choice then
				return
			end
			cont(list_by_name(choice).token)
		end)
	end
	pick(relations.left_names, relations.left_by_name, current and current.left, "Left cardinality:", function(left)
		pick(relations.line_names, relations.line_by_name, current and current.line, "Relationship line:", function(line)
			pick(relations.right_names, relations.right_by_name, current and current.right, "Right cardinality:", function(right)
				er.change_relation(buf, row, left .. line .. right)
			end)
		end)
	end)
end

local function er_edit_role(buf, row)
	local current = er.role_text(buf, row)
	if current == nil then
		notify("place the cursor on a relationship line to label it")
		return
	end
	vim.ui.input({ prompt = "Relationship role: ", default = current }, function(role)
		if role == nil or role == "" then
			return
		end
		er.set_role(buf, row, role)
	end)
end

local function er_change_key(buf, row)
	vim.ui.select(keys.names(), { prompt = "Attribute key:" }, function(choice)
		if not choice then
			return
		end
		er.change_attribute_key(buf, row, keys.by_name(choice).token)
	end)
end

local function er_add_attribute(buf, row)
	local typ = M.get_config().default_attr_type
	vim.ui.input({ prompt = "Attribute type: ", default = typ }, function(t)
		if not t or t == "" then
			return
		end
		vim.ui.input({ prompt = "Attribute name: " }, function(name)
			if not name or name == "" then
				return
			end
			er.add_attribute(buf, row, t, name, nil, nil)
		end)
	end)
end

local function er_add_relation(buf, row)
	local left = er.entity_at(buf, row) or ""
	vim.ui.input({ prompt = "From entity: ", default = left }, function(from)
		if not from or from == "" then
			return
		end
		vim.ui.input({ prompt = "To entity: " }, function(to)
			if not to or to == "" then
				return
			end
			vim.ui.input({ prompt = "Role: ", default = "relates to" }, function(role)
				if role == nil then
					return
				end
				er.add_relation(buf, row, from, M.get_config().default_relation, to, role)
			end)
		end)
	end)
end

----------------------------------------------------------------------
-- Routed entry points
----------------------------------------------------------------------

function M.insert_step()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er_add_attribute(buf, row)
		return
	end
	vim.ui.input({ prompt = "New step label: " }, function(label)
		if not label or label == "" then
			return
		end
		core.insert_between(buf, row, label, { default_shape = M.get_config().default_shape }, col)
	end)
end

function M.add_step()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er_add_relation(buf, row)
		return
	end
	vim.ui.input({ prompt = "New step label: " }, function(label)
		if not label or label == "" then
			return
		end
		core.add_after(buf, row, col, label, { default_shape = M.get_config().default_shape })
	end)
end

function M.swap_down()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er.move_attribute(buf, row, 1)
		return
	end
	core.swap_down(buf, row, col)
end

function M.swap_up()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er.move_attribute(buf, row, -1)
		return
	end
	core.swap_up(buf, row, col)
end

function M.remove_node()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		-- An attribute line removes that attribute; otherwise a relation line is
		-- deleted whole.
		er.remove_at(buf, row)
		return
	end
	core.remove(buf, row, col)
end

function M.change_shape()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er_change_key(buf, row)
		return
	end
	vim.ui.select(shapes.names(), { prompt = "Shape:" }, function(choice)
		if not choice then
			return
		end
		core.change_shape(buf, { row, col }, choice)
	end)
end

function M.change_arrow()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er_change_relation(buf, row)
		return
	end
	vim.ui.select(arrows.list, {
		prompt = "Arrow style:",
		format_item = function(item)
			return string.format("%-14s %s", item.name, item.arrow)
		end,
	}, function(choice)
		if not choice then
			return
		end
		core.change_arrow(buf, row, col, choice.arrow)
	end)
end

function M.edit_label()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) == "er" then
		er_edit_role(buf, row)
		return
	end
	local current = core.edge_label(buf, row, col)
	if current == nil then
		core.set_label(buf, row, col, "") -- triggers the "no edge here" notice
		return
	end
	vim.ui.input({ prompt = "Edge label (empty to remove): ", default = current }, function(label)
		if label == nil then
			return
		end
		core.set_label(buf, row, col, label)
	end)
end

-- erDiagram-only: rename the entity under the cursor everywhere it appears.
function M.rename_entity()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	if kind(buf) ~= "er" then
		notify("rename is for erDiagram entities; this is not an erDiagram")
		return
	end
	local current = er.entity_at(buf, row, col)
	if not current then
		notify("place the cursor on an entity name to rename it")
		return
	end
	vim.ui.input({ prompt = "Rename entity to: ", default = current }, function(name)
		if not name or name == "" then
			return
		end
		er.rename_entity(buf, row, col, name)
	end)
end

-- erDiagram-only: change the type of the attribute under the cursor.
function M.change_attr_type()
	local buf = vim.api.nvim_get_current_buf()
	local row = cursor_pos()
	if kind(buf) ~= "er" then
		notify("attribute type is for erDiagram entities; this is not an erDiagram")
		return
	end
	local current = er.attribute_type_at(buf, row)
	if current == nil then
		notify("place the cursor on an attribute line to change its type")
		return
	end
	vim.ui.input({ prompt = "Attribute type: ", default = current }, function(t)
		if not t or t == "" then
			return
		end
		er.change_attribute_type(buf, row, t)
	end)
end

return M
