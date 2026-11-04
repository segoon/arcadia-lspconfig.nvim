local helpers = require 'tests.helpers'

describe('infractl workflow', function()
  local root
  local buffers
  local workflow
  local starts
  local restarts
  local executable
  local warnings

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
    buffers, starts, restarts, warnings = {}, {}, {}, {}
    executable = true
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/.arcadia.root')
    helpers.write(root .. '/project/a.yaml')
    require('arcadia-lspconfig.root').clear_cache()
    require('arcadia-lspconfig.config').capture(
      'infractl',
      { cmd = { 'ya', 'tool', 'infractl', 'lsp' } }
    )
    workflow = require 'arcadia-lspconfig.servers.infractl' {
      root = require 'arcadia-lspconfig.root',
      config = require 'arcadia-lspconfig.config',
      status = require 'arcadia-lspconfig.status',
      notify = {
        warn_once = function(...)
          warnings[#warnings + 1] = { ... }
        end,
      },
      is_executable = function()
        return executable
      end,
      clients = {
        detach_wrong_root = function() end,
        start = function(...)
          starts[#starts + 1] = { ... }
          return 1
        end,
        restart = function(...)
          restarts[#restarts + 1] = { ... }
        end,
      },
    }
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

  it('configures each root once across activation, restart, and refresh', function()
    local first = buffer 'project/main.star'
    local second = buffer 'project/i.yaml'
    assert.is_true(workflow.activate(first))
    assert.is_true(workflow.activate(second))
    assert.is_true(workflow.restart(first))
    assert.is_true(workflow.refresh(second))
    assert.are.equal(
      1,
      require('arcadia-lspconfig.config').revision(root .. '/project', 'infractl')
    )
    assert.are.equal('idle', require('arcadia-lspconfig.status').get(first).servers.infractl.state)
  end)

  it(
    'starts immediately with checkout ya, publishes status, and supports restart and refresh',
    function()
      local bufnr = buffer 'project/main.star'
      assert.is_true(workflow.activate(bufnr))
      assert.are.same({ root .. '/project', 'infractl', { bufnr } }, starts[1])
      assert.are.same(
        { root .. '/ya', 'tool', 'infractl', 'lsp' },
        require('arcadia-lspconfig.config').resolve(root .. '/project', 'infractl').cmd
      )
      assert.are.equal(
        'ready',
        require('arcadia-lspconfig.status').get(bufnr).servers.infractl.state
      )
      assert.is_true(workflow.restart(bufnr))
      assert.is_true(workflow.refresh(bufnr))
      assert.are.equal(2, #restarts)
    end
  )
end)
