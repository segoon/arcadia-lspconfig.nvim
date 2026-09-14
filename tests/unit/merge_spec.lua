local merge = require 'arcadia-lspconfig.merge'

describe('configuration merge', function()
  it('deep merges maps and replaces lists', function()
    local result = merge.apply({
      cmd = { 'clangd', '--background-index' },
      init_options = { fallbackFlags = { '-Wall' }, keep = true },
    }, {
      cmd = { 'custom-clangd' },
      init_options = { fallbackFlags = { '-Wextra' }, added = true },
    })

    assert.are.same({
      cmd = { 'custom-clangd' },
      init_options = { fallbackFlags = { '-Wextra' }, keep = true, added = true },
    }, result)
  end)

  it('does not mutate either input', function()
    local base = { settings = { clangd = { enabled = true } } }
    local patch = { settings = { clangd = { mode = 'arcadia' } } }

    local result = merge.apply(base, patch)
    result.settings.clangd.enabled = false

    assert.is_true(base.settings.clangd.enabled)
    assert.is_nil(patch.settings.clangd.enabled)
  end)
end)
