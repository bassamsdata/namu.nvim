.PHONY: test test_file deps

test: deps
	@echo "Running all tests..."
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run()"

test_file: deps
	@echo "Testing specific file..."
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: deps/nvim-treesitter deps/mini.nvim
	@echo "Dependencies ready"

deps/nvim-treesitter:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter.git $@

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

clean:
	@echo "Cleaning dependencies..."
	rm -rf deps
