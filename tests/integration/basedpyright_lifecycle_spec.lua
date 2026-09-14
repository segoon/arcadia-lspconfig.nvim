local helpers = require 'tests.helpers'

local function count_lines(path, prefix)
  if vim.fn.filereadable(path) == 0 then
    return 0
  end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    if vim.startswith(line, prefix) then
      count = count + 1
    end
  end
  return count
end

describe('BasedPyright lifecycle', function()
  local sandbox
  local log
  local bufnr

  before_each(function()
    sandbox = helpers.tempdir()
    log = sandbox .. '/events.log'
    vim.env.ARC_LSP_TEST_LOG = log

    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.lsp.config('basedpyright', {
      cmd = { 'python3', fixture, 'fake-basedpyright' },
      filetypes = { 'python' },
      root_markers = { '.git' },
    })
    require('arcadia-lspconfig').setup {
      servers = { clangd = false },
      jobs = { cancel_on_buff_exit = true, timeout_ms = 5000 },
      log = { level = 'off' },
    }
    vim.lsp.enable 'basedpyright'
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients { name = 'basedpyright', _uninitialized = true }) do
      client:stop(true)
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.env.ARC_LSP_TEST_LOG = nil
    helpers.cleanup(sandbox)
  end)

  it('generates import paths and starts BasedPyright', function()
    local root = sandbox .. '/checkout'
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/main.py', 'value = 1')
    helpers.write(root .. '/project/.fake_ya_require_parallel')
    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.fn.writefile(vim.fn.readfile(fixture), root .. '/ya')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')

    vim.cmd.edit(vim.fn.fnameescape(root .. '/project/main.py'))
    bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = 'python'
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.basedpyright.state == 'ready'
        and count_lines(log, 'ide:') == 1
        and count_lines(log, 'make:') == 1
        and count_lines(log, 'basedpyright:') >= 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'basedpyright' } == 1
    end, 20))

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'basedpyright' })[1]
    assert.are.same({
      vim.fs.normalize(root .. '/project'),
      client.config.settings.basedpyright.analysis.extraPaths[2],
    }, client.config.settings.basedpyright.analysis.extraPaths)
    local data_dir =
      require('arcadia-lspconfig.paths').data(vim.fs.normalize(root .. '/project'), 'basedpyright')
    assert.is_not_nil(
      require('arcadia-lspconfig.servers.pyright_cache').read(data_dir .. '/config.json')
    )
    helpers.cleanup(data_dir)
  end)
end)
