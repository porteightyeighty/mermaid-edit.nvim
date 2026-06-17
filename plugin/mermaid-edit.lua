-- User commands for mermaid-edit.nvim. These work regardless of keymaps.

if vim.g.loaded_mermaid_edit then
	return
end
vim.g.loaded_mermaid_edit = true

local function cmd(name, fn, desc)
	vim.api.nvim_create_user_command(name, function()
		require("mermaid-edit")[fn]()
	end, { desc = desc })
end

cmd("MermaidInsertStep", "insert_step", "Insert a step between the two nodes on this edge")
cmd("MermaidSwapDown", "swap_down", "Swap this step with the next one")
cmd("MermaidSwapUp", "swap_up", "Swap this step with the previous one")
cmd("MermaidShape", "change_shape", "Change the shape of the node under the cursor")
cmd("MermaidRemove", "remove_node", "Remove the node under the cursor and bridge the gap")
