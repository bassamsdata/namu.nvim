.PHONY: test test_file deps
all: format docs test

docs: deps/panvimdoc
	@echo Generating Docs...
	@pandoc \
		--metadata="project:namu" \
		--metadata="vimversion:NVIM v0.11" \
		--metadata="titledatepattern:%Y %B %d" \
		--metadata="toc:true" \
		--metadata="incrementheadinglevelby:0" \
		--metadata="treesitter:true" \
		--metadata="dedupsubheadings:true" \
		--metadata="ignorerawblocks:true" \
		--metadata="docmapping:false" \
		--metadata="docmappingproject:true" \
		--lua-filter deps/panvimdoc/scripts/include-files.lua \
		--lua-filter deps/panvimdoc/scripts/skip-blocks.lua \
		-t deps/panvimdoc/scripts/panvimdoc.lua \
		README.md \
		-o doc/namu.txt

format:
	@echo Formatting...
	@stylua tests/ lua/ -f ./stylua.toml

.PHONY: test test_file deps

test: deps
	@echo "Running all tests..."
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run()"

test_file: deps
	@echo "Testing specific file..."
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

deps: deps/nvim-treesitter deps/mini.nvim deps/panvimdoc
	@echo "Dependencies ready"

deps/nvim-treesitter:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter.git $@

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

deps/panvimdoc:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/kdheepak/panvimdoc $@

clean:
	@echo "Cleaning dependencies..."
	rm -rf deps
