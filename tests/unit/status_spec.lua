describe('status', function()
  local status

  before_each(function()
    status = require 'arcadia-lspconfig.status'
    status.clear()
  end)

  it('projects root and server state onto a buffer', function()
    status.associate(7, '/arcadia', '/arcadia/project', 'clangd')
    status.set('/arcadia/project', 'clangd', {
      state = 'waiting',
      stage = 'compile_commands',
      message = 'Generating compile commands',
      revision = 2,
    })

    assert.are.same({
      arcadia_root = '/arcadia',
      lsp_root = '/arcadia/project',
      servers = {
        clangd = {
          state = 'waiting',
          stage = 'compile_commands',
          message = 'Generating compile commands',
          revision = 2,
        },
      },
    }, status.get(7))
  end)

  it('renders one spinner only while waiting', function()
    status.associate(7, '/arcadia', '/arcadia/project', 'clangd')
    status.set('/arcadia/project', 'clangd', { state = 'waiting' })
    assert.matches('^lsp ', status.line(7, 0))

    status.set('/arcadia/project', 'clangd', { state = 'ready' })
    assert.are.equal('', status.line(7, 0))
    assert.is_nil(status.get(8))
  end)
end)
