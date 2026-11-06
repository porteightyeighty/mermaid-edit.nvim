-- Minimal config for recording the README demo: this checkout plus the user's mermaid parser.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.g.mapleader = " "
vim.opt.number = true
vim.opt.laststatus = 0
vim.opt.ruler = false
vim.opt.showmode = false
vim.opt.cmdheight = 1
vim.opt.shortmess:append("IF")
vim.opt.ttimeoutlen = 10
vim.cmd.colorscheme("default")
require("mermaid-edit").setup({})

-- Move to the first match of `pattern` and show `caption` in the command line.
function _G.Step(pattern, caption)
	vim.fn.cursor(1, 1)
	vim.fn.search(pattern, "c")
	vim.cmd("redraw!")
	vim.api.nvim_echo({ { caption, "Comment" } }, false, {})
end
