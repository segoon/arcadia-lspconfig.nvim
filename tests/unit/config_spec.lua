describe('root-specific configuration', function()
  local config

  before_each(function()
    config = require 'arcadia-lspconfig.config'
    config.clear()
    config.capture('clangd', {
      name = 'clangd',
      cmd = { 'clangd' },
      root_markers = { '.git' },
      init_options = { fallbackFlags = { '-Wall' } },
    })
  end)

  it('layers patches without leaking between roots', function()
    config.extend('/arcadia/a', 'clangd', {
      cmd = { '/arcadia/ya', 'tool', 'clangd' },
      init_options = { compilationDatabasePath = '/data/a' },
    })

    assert.are.same({
      name = 'clangd',
      cmd = { '/arcadia/ya', 'tool', 'clangd' },
      root_dir = '/arcadia/a',
      init_options = {
        fallbackFlags = { '-Wall' },
        compilationDatabasePath = '/data/a',
      },
    }, config.resolve('/arcadia/a', 'clangd'))
    assert.are.same({ 'clangd' }, config.resolve('/arcadia/b', 'clangd').cmd)
    assert.is_nil(config.resolve('/arcadia/b', 'clangd').init_options.compilationDatabasePath)
  end)
end)
