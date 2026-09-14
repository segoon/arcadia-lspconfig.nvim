local helpers = require 'tests.helpers'

describe('ty suppression', function()
  local root
  local bufnr
  local original_get_clients
  local original_detach_client

  before_each(function()
    root = helpers.tempdir()
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/main.py')
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. '/project/main.py')
    require('arcadia-lspconfig.root').clear_cache()
    original_get_clients = vim.lsp.get_clients
    original_detach_client = vim.lsp.buf_detach_client
  end)

  after_each(function()
    vim.lsp.get_clients = original_get_clients
    vim.lsp.buf_detach_client = original_detach_client
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    helpers.cleanup(root)
  end)

  it('applies throughout Arcadia and detaches an existing client', function()
    local detached
    vim.lsp.get_clients = function(filter)
      assert.are.same({ bufnr = bufnr, name = 'ty', _uninitialized = true }, filter)
      return { { id = 42 } }
    end
    vim.lsp.buf_detach_client = function(buffer, client)
      detached = { buffer, client }
    end
    local workflow = require 'arcadia-lspconfig.servers.ty' {
      root = require 'arcadia-lspconfig.root',
    }

    local context = workflow.context(bufnr)
    assert.are.equal(vim.fs.normalize(root), context.arcadia_root)
    assert.is_nil(context.lsp_root)
    assert.is_true(workflow.activate(bufnr, context))
    assert.are.same({ bufnr, 42 }, detached)
  end)
end)
