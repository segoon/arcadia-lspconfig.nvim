describe('definition-owned LSP configuration', function()
  it('installs the config and automatically enables an opted-in server', function()
    local original_create_command = vim.api.nvim_create_user_command
    local original_enable = vim.lsp.enable
    local enabled
    vim.api.nvim_create_user_command = function() end
    vim.lsp.enable = function(name)
      enabled = name
    end
    local definition = {
      name = 'owned_fixture',
      default_options = {},
      allowed_options = {},
      auto_enable = true,
      config = { cmd = { 'owned-server' }, filetypes = { 'owned' } },
      create = function()
        return {
          context = function()
            return nil
          end,
        }
      end,
    }

    local runtime = require('arcadia-lspconfig.runtime').new { definition }
    runtime.setup { log = { level = 'off' } }

    vim.api.nvim_create_user_command = original_create_command
    vim.lsp.enable = original_enable
    assert.are.equal('owned_fixture', enabled)
    assert.are.same(
      { 'owned-server' },
      require('arcadia-lspconfig.config').base('owned_fixture').cmd
    )
  end)
end)
