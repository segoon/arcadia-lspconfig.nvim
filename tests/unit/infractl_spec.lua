local helpers = require 'tests.helpers'

describe('infractl detection', function()
  local root
  local buffers
  local workflow
  ---@param name string
  ---@return integer
  local function buffer(name)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. '/' .. name)
    buffers[#buffers + 1] = bufnr
    return bufnr
  end

  before_each(function()
    root = helpers.tempdir()
    buffers = {}
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/.arcadia.root')
    helpers.write(root .. '/project/a.yaml')
    require('arcadia-lspconfig.root').clear_cache()
    workflow = require 'arcadia-lspconfig.servers.infractl'
  end)

  after_each(function()
    for _, bufnr in ipairs(buffers) do
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    require('arcadia-lspconfig.config').clear()
    require('arcadia-lspconfig.status').clear()
    helpers.cleanup(root)
  end)

  it('matches only infractl files and selects the nearest marker without ya.make', function()
    for _, name in ipairs { 'project/main.star', 'project/i.yaml', 'project/i.prod.yaml' } do
      assert.are.equal(root .. '/project', workflow.context(buffer(name)).lsp_root)
    end
    assert.are.equal(root, workflow.context(buffer 'other/main.star').lsp_root)
    for _, name in ipairs { 'project/other.yaml', 'project/i.yaml.bak', 'project/main.py' } do
      assert.is_nil(workflow.context(buffer(name)))
    end
  end)

  it('requires Arcadia and does not search beyond the checkout for markers', function()
    vim.fn.delete(root .. '/.arcadia.root')
    assert.is_nil(workflow.context(buffer 'other/main.star'))
    vim.fn.delete(root .. '/.arc/HEAD')
    require('arcadia-lspconfig.root').clear_cache()
    assert.is_nil(workflow.context(buffer 'project/main.star'))
  end)

  it('does not use a marker above a nested checkout', function()
    helpers.write(root .. '/nested/.arc/HEAD')
    assert.is_nil(workflow.context(buffer 'nested/main.star'))
  end)

  it('selects checkout-local ya for the native command', function()
    assert.are.same(
      { root .. '/ya', 'tool', 'infractl', 'lsp' },
      workflow.command(root .. '/project')
    )
  end)
end)
