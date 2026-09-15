describe('injected server runtime', function()
  it('derives setup, construction, and routing from definitions', function()
    local original_runtime_file = vim.api.nvim_get_runtime_file
    local original_create_command = vim.api.nvim_create_user_command
    local created_with
    local refreshed
    local definition = {
      name = 'fixture_server',
      default_options = { feature = true },
      allowed_options = { feature = 'boolean' },
      create = function(api)
        created_with = api
        return {
          context = function(bufnr)
            return { bufnr = bufnr }
          end,
          activate = function()
            return true
          end,
          refresh = function(bufnr)
            refreshed = bufnr
            return true
          end,
          restart = function()
            return true
          end,
          health = function()
            return {}
          end,
        }
      end,
    }
    vim.api.nvim_create_user_command = function() end
    vim.lsp.config('fixture_server', {
      cmd = { 'true' },
      filetypes = { 'fixture' },
    })
    local runtime_config = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'return {}' }, runtime_config)
    vim.api.nvim_get_runtime_file = function()
      return { runtime_config }
    end
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'fixture'
    local runtime = require('arcadia-lspconfig.runtime').new { definition }
    local ok, err = pcall(function()
      runtime.setup {
        servers = { fixture_server = { feature = false } },
        log = { level = 'off' },
      }
    end)
    vim.api.nvim_get_runtime_file = original_runtime_file
    vim.api.nvim_create_user_command = original_create_command
    vim.fn.delete(runtime_config)
    assert.is_true(ok, err)
    assert.is_not_nil(created_with)
    assert.is_nil(created_with.cache)
    assert.is_false(created_with.options.servers.fixture_server.feature)
    vim.lsp.enable 'fixture_server'
    local workflow, selected = runtime._workflow(bufnr)
    assert.is_not_nil(workflow)
    assert.are.equal(definition, selected)
    assert.is_true(runtime.refresh(bufnr))
    assert.are.equal(bufnr, refreshed)
    vim.lsp.enable('fixture_server', false)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  it('rejects duplicate definitions and options not declared by a definition', function()
    local Runtime = require 'arcadia-lspconfig.runtime'
    local definition = {
      name = 'fixture_server',
      default_options = {},
      allowed_options = {},
      create = function()
        return {}
      end,
    }
    assert.has_error(function()
      Runtime.new { definition, definition }
    end, 'arcadia-lspconfig: duplicate server definition: fixture_server')
    local runtime = Runtime.new { definition }
    assert.has_error(function()
      runtime.setup { servers = { unknown_server = false } }
    end, 'arcadia-lspconfig: unknown server option: unknown_server')
  end)

  it('validates declared server option types', function()
    local definition = {
      name = 'fixture_server',
      default_options = { feature = true },
      allowed_options = { feature = 'boolean' },
      create = function()
        return {}
      end,
    }
    local runtime = require('arcadia-lspconfig.runtime').new { definition }
    assert.has_error(function()
      runtime.setup { servers = { fixture_server = { feature = 'yes' } } }
    end, 'servers.fixture_server.feature: expected boolean, got string')
  end)

  it('routes overlapping filetypes by enabled server and reports ambiguity', function()
    local original_runtime_file = vim.api.nvim_get_runtime_file
    local original_create_command = vim.api.nvim_create_user_command
    local original_is_enabled = vim.lsp.is_enabled
    local refreshed
    local enabled = { second = true, suppressed = true }
    local function definition(name, route_commands)
      return {
        name = name,
        default_options = {},
        allowed_options = {},
        route_commands = route_commands,
        create = function()
          return {
            context = function(bufnr)
              return { bufnr = bufnr }
            end,
            activate = function()
              return true
            end,
            refresh = function()
              refreshed = name
              return true
            end,
            restart = function()
              return true
            end,
            health = function()
              return {}
            end,
          }
        end,
      }
    end
    vim.api.nvim_create_user_command = function() end
    local runtime_config = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'return {}' }, runtime_config)
    vim.api.nvim_get_runtime_file = function()
      return { runtime_config }
    end
    vim.lsp.is_enabled = function(name)
      return enabled[name] == true
    end
    for _, name in ipairs { 'first', 'second', 'suppressed' } do
      vim.lsp.config(name, { cmd = { 'true' }, filetypes = { 'fixture' } })
    end
    local runtime = require('arcadia-lspconfig.runtime').new {
      definition 'first',
      definition 'second',
      definition('suppressed', false),
    }
    runtime.setup { log = { level = 'off' } }
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'fixture'

    local workflow, selected = runtime._workflow(bufnr)
    assert.is_not_nil(workflow)
    assert.are.equal('second', selected.name)
    assert.is_true(runtime.refresh(bufnr))
    assert.are.equal('second', refreshed)

    enabled = {}
    local ok, message = runtime.refresh(bufnr)
    assert.is_nil(ok)
    assert.are.equal('no enabled Arcadia LSP integration applies to the current buffer', message)

    enabled = { first = true, second = true, suppressed = true }
    workflow, selected, message = runtime._workflow(bufnr)
    assert.is_nil(workflow)
    assert.is_nil(selected)
    assert.are.equal(
      'multiple enabled Arcadia LSP integrations apply to this buffer: first, second',
      message
    )

    vim.api.nvim_get_runtime_file = original_runtime_file
    vim.api.nvim_create_user_command = original_create_command
    vim.lsp.is_enabled = original_is_enabled
    vim.fn.delete(runtime_config)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
