local repo = vim.fn.getcwd()
local plenary = vim.env.PLENARY_DIR or (repo .. '/.deps/plenary.nvim')
local lspconfig = vim.env.NVIM_LSPCONFIG_DIR or (repo .. '/.deps/nvim-lspconfig')

vim.opt.runtimepath:prepend(repo)
vim.opt.runtimepath:append(plenary)
vim.opt.runtimepath:append(lspconfig)
vim.o.swapfile = false
vim.o.writebackup = false
