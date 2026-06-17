-- mermaid-edit.nvim - public API and configuration.
--
-- The functions here are the interactive entry points: they read the current
-- buffer/cursor, prompt via vim.ui where needed, and delegate the actual buffer
-- mutation to the UI-free primitives in mermaid-edit.core.

local core = require("mermaid-edit.core")
local shapes = require("mermaid-edit.shapes")
local arrows = require("mermaid-edit.arrows")

local M = {}

local defaults = {
	-- Buffer-local keymaps, applied by ftplugin/mermaid.lua.
	-- Set any entry to false to disable just that map, or set `keymaps = false`
	-- to disable all of them and wire your own (the :Mermaid* commands always
	-- work regardless).
	keymaps = {
		insert_step = "<leader>mi",
		swap_down = "<leader>mj",
		swap_up = "<leader>mk",
		change_shape = "<leader>ms",
		change_arrow = "<leader>ma",
		edit_label = "<leader>ml",
		remove_node = "<leader>md",
	},
	-- Shape used for a newly inserted node when the edge's target is a bare id.
	default_shape = "square",
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

function M.insert_step()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
	vim.ui.input({ prompt = "New step label: " }, function(label)
		if not label or label == "" then
			return
		end
		core.insert_between(buf, row, label, { default_shape = M.get_config().default_shape }, col)
	end)
end

function M.swap_down()
	local row, col = cursor_pos()
	core.swap_down(vim.api.nvim_get_current_buf(), row, col)
end

function M.swap_up()
	local row, col = cursor_pos()
	core.swap_up(vim.api.nvim_get_current_buf(), row, col)
end

function M.remove_node()
	local row, col = cursor_pos()
	core.remove(vim.api.nvim_get_current_buf(), row, col)
end

function M.change_shape()
	local buf = vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)
	local pos = { cur[1] - 1, cur[2] }
	vim.ui.select(shapes.names(), { prompt = "Shape:" }, function(choice)
		if not choice then
			return
		end
		core.change_shape(buf, pos, choice)
	end)
end

function M.change_arrow()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = cursor_pos()
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

return M
