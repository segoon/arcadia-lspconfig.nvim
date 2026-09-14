describe('injected server runtime', function()
  it('derives setup, construction, and routing from definitions', function()
    local original_runtime_file = vim.api.nvim_get_runtime_file
    local original_create_command = vim.api.nvim_create_user_command
    local created_with
    local refreshed
    local definition = {
      name = 'fixture_server',
      default_options = { feature = true },
      allowed_options = { feature = true },
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
    local workflow, selected = runtime._workflow(bufnr)
    assert.is_not_nil(workflow)
    assert.are.equal(definition, selected)
    assert.is_true(runtime.refresh(bufnr))
    assert.are.equal(bufnr, refreshed)
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

  it('rejects conflicting enabled server definitions', function()
    local function definition(name, conflict)
      return {
        name = name,
        default_options = {},
        allowed_options = {},
        conflicts = { conflict },
        create = function()
          return {}
        end,
      }
    end
    local runtime = require('arcadia-lspconfig.runtime').new {
      definition('first', 'second'),
      definition('second', 'first'),
    }

    assert.has_error(function()
      runtime.setup()
    end, 'arcadia-lspconfig: servers.first and servers.second cannot both be enabled')
  end)
end)
