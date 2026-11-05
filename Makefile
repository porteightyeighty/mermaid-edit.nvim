# The mermaid grammar revision nvim-treesitter pins. It has no external scanner.
GRAMMAR_REV := 90ae195b31933ceb9d079abfa8a3ad0a36fee4cc
PARSER_DIR ?= $(HOME)/.local/share/nvim/site/parser

.PHONY: test parser

test:
	nvim --headless -l tests/test_core.lua
	nvim --headless -l tests/test_er.lua

# Build the mermaid parser without nvim-treesitter (used by CI).
parser:
	rm -rf .grammar
	git clone --quiet https://github.com/monaqa/tree-sitter-mermaid .grammar
	git -C .grammar checkout --quiet $(GRAMMAR_REV)
	mkdir -p $(PARSER_DIR)
	cc -shared -fPIC -O2 -I.grammar/src .grammar/src/parser.c -o $(PARSER_DIR)/mermaid.so
	rm -rf .grammar
