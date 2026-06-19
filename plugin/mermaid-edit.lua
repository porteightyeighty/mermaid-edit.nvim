-- Global setup for mermaid-edit.nvim: :Mermaid* user commands and <Plug>
-- mappings. Both work on any buffer but the handlers no-op politely off a
-- mermaid diagram. Buffer-local default keys live in ftplugin/mermaid.lua.

if vim.g.loaded_mermaid_edit then
	return
end
vim.g.loaded_mermaid_edit = true

-- Single source of truth. Each action routes on the diagram kind under the
-- cursor, so it carries a separate `flow` and `er` label. The keymaps pick the
-- one matching the buffer (see ftplugin/mermaid.lua); the global command and
-- <Plug>, which can't know the kind in advance, show both.
local actions = {
	{ fn = "insert_step", cmd = "MermaidInsertStep", plug = "mermaid-insert-step", flow = "Insert step between nodes", er = "Add attribute" },
	{ fn = "add_step", cmd = "MermaidAddStep", plug = "mermaid-add-step", flow = "Add step after node", er = "Add relationship" },
	{ fn = "swap_down", cmd = "MermaidSwapDown", plug = "mermaid-swap-down", flow = "Move step down", er = "Move attribute down" },
	{ fn = "swap_up", cmd = "MermaidSwapUp", plug = "mermaid-swap-up", flow = "Move step up", er = "Move attribute up" },
	{ fn = "change_shape", cmd = "MermaidShape", plug = "mermaid-shape", flow = "Change node shape", er = "Change attribute key" },
	{ fn = "change_arrow", cmd = "MermaidArrow", plug = "mermaid-arrow", flow = "Change edge arrow", er = "Change relationship cardinality" },
	{ fn = "edit_label", cmd = "MermaidLabel", plug = "mermaid-label", flow = "Edit edge label", er = "Edit relationship role" },
	{ fn = "remove_node", cmd = "MermaidRemove", plug = "mermaid-remove", flow = "Remove node, bridge the gap", er = "Remove attribute or relation" },
	{ fn = "rename_entity", cmd = "MermaidRename", plug = "mermaid-rename", er = "Rename entity everywhere" },
	{ fn = "change_attr_type", cmd = "MermaidAttrType", plug = "mermaid-attr-type", er = "Change attribute type" },
}

-- Combined label for the global command/<Plug>, e.g. "flowchart: X / erDiagram: Y".
local function combined(a)
	if a.flow and a.er then
		return ("flowchart: %s / erDiagram: %s"):format(a.flow, a.er)
	end
	return "erDiagram: " .. a.er
end

for _, a in ipairs(actions) do
	local handler = function()
		require("mermaid-edit")[a.fn]()
	end
	-- Command: always available, independent of any keymap.
	vim.api.nvim_create_user_command(a.cmd, handler, { desc = combined(a) })
	-- <Plug> handle: a stable, rebindable target. <Plug> maps are inert (not
	-- typeable), so defining them globally is harmless and conventional.
	vim.keymap.set("n", "<Plug>(" .. a.plug .. ")", handler, { silent = true, desc = "Mermaid: " .. combined(a) })
end

-- Expose the action table so ftplugin/mermaid.lua can wire default keys to the
-- <Plug> handles and pick the kind-specific label.
require("mermaid-edit")._actions = actions
