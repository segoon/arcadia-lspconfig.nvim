describe('setup', function()
  it('validates options, supports disabling built-in servers, and rejects repetition', function()
    local plugin = require 'arcadia-lspconfig'

    assert.has_error(function()
      plugin.setup { jobs = { cancel_on_buf_exit = true } }
    end, 'arcadia-lspconfig: unknown jobs option: cancel_on_buf_exit')

    plugin.setup { servers = { clangd = false }, log = { level = 'off' } }
    assert.is_true(plugin._state().configured)
    assert.is_nil(plugin._state().workflows.clangd)
    assert.is_not_nil(plugin._state().workflows.pyright)
    assert.is_not_nil(plugin._state().workflows.basedpyright)
    assert.is_not_nil(plugin._state().workflows.ty)
    for _, command in ipairs {
      'LspArcadiaRefresh',
      'LspArcadiaStatus',
      'LspArcadiaRestart',
    } do
      assert.are.equal(2, vim.fn.exists(':' .. command))
    end
    for _, command in ipairs {
      'LspRefreshArcadia',
      'ArcadiaLspStatus',
      'ArcadiaLspRestart',
    } do
      assert.are.equal(0, vim.fn.exists(':' .. command))
    end
    assert.has_error(function()
      plugin.setup()
    end, 'arcadia-lspconfig.setup() may only be called once')
  end)
end)
