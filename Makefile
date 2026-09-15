NVIM ?= nvim
PLENARY_DIR ?= .deps/plenary.nvim
NVIM_LSPCONFIG_DIR ?= .deps/nvim-lspconfig

.PHONY: deps test format lint

deps:
	@test -d "$(PLENARY_DIR)" || git clone --depth=1 https://github.com/nvim-lua/plenary.nvim "$(PLENARY_DIR)"
	@test -d "$(NVIM_LSPCONFIG_DIR)" || git clone --depth=1 https://github.com/neovim/nvim-lspconfig "$(NVIM_LSPCONFIG_DIR)"

test:
	PLENARY_DIR="$(abspath $(PLENARY_DIR))" NVIM_LSPCONFIG_DIR="$(abspath $(NVIM_LSPCONFIG_DIR))" \
		$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/unit { minimal_init = './tests/minimal_init.lua' }"
	PLENARY_DIR="$(abspath $(PLENARY_DIR))" NVIM_LSPCONFIG_DIR="$(abspath $(NVIM_LSPCONFIG_DIR))" \
		$(NVIM) --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/integration { minimal_init = './tests/minimal_init.lua' }"

format:
	stylua lua plugin tests

lint:
	stylua --check lua plugin tests
	luacheck lua plugin tests
