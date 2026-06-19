-- Buffer-local default keymaps for mermaid buffers.
--
-- Keys map to the <Plug>(mermaid-*) handles defined in plugin/mermaid-edit.lua,
-- so they are easy to override: set `keymaps` (or a single entry) to false in
-- setup() and map the <Plug> handles yourself, or just shadow a key in your own
-- after/ftplugin/mermaid.lua. We also skip any key the user has already mapped,
-- so an existing mapping always wins.

local me = require("mermaid-edit")
local keymaps = me.get_config().keymaps

if keymaps == false then
	return
end

local buf = vim.api.nvim_get_current_buf()
-- The buffer's diagram kind lets us show a single, clean label per key instead
-- of the dual flowchart/erDiagram description the global command must carry.
local er_kind = require("mermaid-edit.er.core").diagram_type(buf) == "er"

for _, a in ipairs(me._actions) do
	local lhs = keymaps[a.fn]
	-- An action with no flowchart meaning (er-only) is skipped in flowcharts.
	local label = er_kind and a.er or a.flow
	if lhs and label and vim.fn.maparg(lhs, "n") == "" then
		vim.keymap.set("n", lhs, "<Plug>(" .. a.plug .. ")", {
			buffer = buf,
			silent = true,
			desc = "Mermaid: " .. label,
		})
	end
end
