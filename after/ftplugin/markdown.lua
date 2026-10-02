-- Keep source delimiters visible; MarkdownView owns the rendered presentation.
vim.opt_local.conceallevel = 0
vim.b.undo_ftplugin = (vim.b.undo_ftplugin or "") .. "|setlocal conceallevel<"

-- Review hunks need conceallevel for omitted lines, but source markers must
-- stay visible there too. Disable only Tree-sitter's inline conceal captures.
local ok, highlights = pcall(vim.treesitter.query.get, "markdown_inline", "highlights")
if ok and highlights then
	highlights.query:disable_capture("conceal")
end
