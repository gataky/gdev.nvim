# Neovim executable(s) used for tests. Override to check a version matrix:
#   make test NVIM_EXEC="nvim-0.11 nvim-nightly"
NVIM_EXEC ?= nvim

.PHONY: all test gendoc format lint clean-deps

all: test lint

# Run tests for all modules
test: deps/mini.nvim
	for nvim_exec in $(NVIM_EXEC); do \
		printf "\n======\n\n" ; \
		$$nvim_exec --version | head -n 1 && echo '' ; \
		$$nvim_exec --headless --noplugin -u ./scripts/minimal_init.lua \
			-c "lua MiniTest.run()" ; \
	done

# Run tests for a single module, e.g. `make test_lsp` for 'tests/test_lsp.lua'
test_%: deps/mini.nvim
	for nvim_exec in $(NVIM_EXEC); do \
		printf "\n======\n\n" ; \
		$$nvim_exec --version | head -n 1 && echo '' ; \
		$$nvim_exec --headless --noplugin -u ./scripts/minimal_init.lua \
			-c "lua MiniTest.run_file('tests/$@.lua')" ; \
	done

# Regenerate 'doc/gdev.txt' from module annotations. `setup()` has to run first:
# the `---@eval` blocks that render config defaults into help reference the
# global `MiniDoc`, which only exists once the module is set up. The output path
# is spelled out because mini.doc otherwise derives it from the name of the
# working directory, which is not 'gdev.nvim' inside a git worktree.
gendoc: deps/mini.nvim
	$(NVIM_EXEC) --headless --noplugin -u ./scripts/minimal_init.lua \
		-c "lua require('mini.doc').setup(); require('mini.doc').generate(nil, 'doc/gdev.txt')" -c "qa!"

format:
	stylua .

lint:
	stylua --check .

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim $@

clean-deps:
	rm -rf deps
