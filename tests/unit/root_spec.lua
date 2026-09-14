local helpers = require 'tests.helpers'

describe('root discovery', function()
  local root

  before_each(function()
    root = helpers.tempdir()
    require('arcadia-lspconfig.root').clear_cache()
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it('finds the nearest ya.make inside the Arcadia root', function()
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/nested/ya.make')
    helpers.write(root .. '/project/nested/source/main.cpp')

    local result = require('arcadia-lspconfig.root').find(root .. '/project/nested/source/main.cpp')

    assert.are.same(vim.fs.normalize(root), result.arcadia_root)
    assert.are.same(vim.fs.normalize(root .. '/project/nested'), result.lsp_root)
  end)

  it('does not search for ya.make above the Arcadia root', function()
    helpers.write(root .. '/ya.make')
    helpers.write(root .. '/checkout/.arc/HEAD')
    helpers.write(root .. '/checkout/source/main.cpp')

    local result = require('arcadia-lspconfig.root').find(root .. '/checkout/source/main.cpp')

    assert.are.same(vim.fs.normalize(root .. '/checkout'), result.arcadia_root)
    assert.is_nil(result.lsp_root)
  end)

  it('returns nil roots outside Arcadia', function()
    helpers.write(root .. '/source/main.cpp')

    assert.are.same({}, require('arcadia-lspconfig.root').find(root .. '/source/main.cpp'))
  end)

  it('caches negative results for the session', function()
    local source = root .. '/source/main.cpp'
    helpers.write(source)
    assert.are.same({}, require('arcadia-lspconfig.root').find(source))

    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/ya.make')
    assert.are.same({}, require('arcadia-lspconfig.root').find(source))

    require('arcadia-lspconfig.root').clear_cache()
    assert.are.same(vim.fs.normalize(root), require('arcadia-lspconfig.root').find(source).lsp_root)
  end)
end)
