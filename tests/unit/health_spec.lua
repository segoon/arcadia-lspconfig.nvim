local helpers = require 'tests.helpers'

describe('health checks', function()
  local original_health
  local original_buffer
  local root
  local buffers
  local messages

  before_each(function()
    original_health = vim.health
    original_buffer = vim.api.nvim_get_current_buf()
    root = helpers.tempdir()
    buffers = {}
    messages = {}

    vim.health = {}
    for _, level in ipairs { 'start', 'ok', 'warn', 'error', 'info' } do
      vim.health[level] = function(message)
        messages[#messages + 1] = message
      end
    end
    package.loaded['arcadia-lspconfig.health'] = nil
    require('arcadia-lspconfig.root').clear_cache()
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.api.nvim_set_current_buf(original_buffer)
    end
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.health = original_health
    package.loaded['arcadia-lspconfig.health'] = nil
    helpers.cleanup(root)
  end)

  it('checks the originating file rather than the health result buffer', function()
    local source = root .. '/project/main.cpp'
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(source)

    local source_buffer = vim.api.nvim_create_buf(false, true)
    local health_buffer = vim.api.nvim_create_buf(false, true)
    buffers = { source_buffer, health_buffer }
    vim.api.nvim_buf_set_name(source_buffer, source)
    vim.api.nvim_buf_set_name(health_buffer, 'health://arcadia-lspconfig')
    vim.api.nvim_set_current_buf(source_buffer)
    vim.api.nvim_set_current_buf(health_buffer)

    require('arcadia-lspconfig.health').check()

    assert.is_true(vim.tbl_contains(messages, ('Arcadia root: %s'):format(vim.fs.normalize(root))))
    assert.is_true(
      vim.tbl_contains(messages, ('LSP root: %s'):format(vim.fs.normalize(root .. '/project')))
    )
    assert.is_false(vim.tbl_contains(messages, 'The current buffer is outside Arcadia'))
  end)

  it('reports ambiguous enabled integrations', function()
    local source = root .. '/project/main.py'
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(source)
    local bufnr = vim.api.nvim_create_buf(false, true)
    buffers = { bufnr }
    vim.api.nvim_buf_set_name(bufnr, source)
    vim.api.nvim_set_current_buf(bufnr)

    local plugin = require 'arcadia-lspconfig'
    local original_workflow = plugin._workflow
    plugin._workflow = function()
      return nil,
        nil,
        'multiple enabled Arcadia LSP integrations apply to this buffer: basedpyright, pyright'
    end
    require('arcadia-lspconfig.health').check()
    plugin._workflow = original_workflow

    assert.is_true(
      vim.tbl_contains(
        messages,
        'multiple enabled Arcadia LSP integrations apply to this buffer: basedpyright, pyright'
      )
    )
  end)
end)
