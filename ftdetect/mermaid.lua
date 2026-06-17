-- Map *.mmd / *.mermaid to the `mermaid` filetype, but only if nothing else
-- already claims it (so we never clobber a user's existing detection).
vim.filetype.add({
	extension = {
		mmd = "mermaid",
		mermaid = "mermaid",
	},
})
