local helpers = require 'tests.helpers'

describe('Pyright health checks', function()
  local original_health
  local original_buffer
  local root
  local bufnr
  local messages

  before_each(function()
    original_health = vim.health
    original_buffer = vim.api.nvim_get_current_buf()
    root = helpers.tempdir()
    messages = {}
    vim.health = {}
    for _, level in ipairs { 'start', 'ok', 'warn', 'error', 'info' } do
      vim.health[level] = function(message)
        messages[#messages + 1] = message
      end
    end
    package.loaded['arcadia-lspconfig.health'] = nil
    require('arcadia-lspconfig.root').clear_cache()

    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/main.py')
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. '/project/main.py')
    vim.bo[bufnr].filetype = 'python'
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.api.nvim_set_current_buf(original_buffer)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.health = original_health
    package.loaded['arcadia-lspconfig.health'] = nil
    helpers.cleanup(root)
  end)

  it('reports Pyright cache state for Python buffers', function()
    require('arcadia-lspconfig.health').check()

    local data_dir =
      require('arcadia-lspconfig.paths').data(vim.fs.normalize(root .. '/project'), 'pyright')
    assert.is_true(vim.tbl_contains(messages, ('pyright data directory: %s'):format(data_dir)))
    assert.is_true(vim.tbl_contains(messages, 'No cached Pyright configuration exists yet'))
  end)
end)
