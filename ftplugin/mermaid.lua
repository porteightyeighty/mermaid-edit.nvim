-- Buffer-local keymaps for mermaid buffers, derived from the resolved config.

local me = require("mermaid-edit")
local keymaps = me.get_config().keymaps

if keymaps == false then
	return
end

local actions = {
	insert_step = { fn = me.insert_step, desc = "Mermaid: insert step" },
	swap_down = { fn = me.swap_down, desc = "Mermaid: move step down" },
	swap_up = { fn = me.swap_up, desc = "Mermaid: move step up" },
	change_shape = { fn = me.change_shape, desc = "Mermaid: change shape" },
	change_arrow = { fn = me.change_arrow, desc = "Mermaid: change arrow style" },
	edit_label = { fn = me.edit_label, desc = "Mermaid: edit edge label" },
	remove_node = { fn = me.remove_node, desc = "Mermaid: remove node" },
}

for action, spec in pairs(actions) do
	local lhs = keymaps[action]
	if lhs then
		vim.keymap.set("n", lhs, spec.fn, { buffer = true, silent = true, desc = spec.desc })
	end
end
