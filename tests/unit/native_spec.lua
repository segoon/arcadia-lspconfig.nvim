local helpers = require 'tests.helpers'

describe('native server definitions', function()
  it('delegates startup to Neovim and shares restart handling with refresh', function()
    local root = helpers.tempdir()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = 'native_fixture'
    local original_buffer = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(bufnr)
    local commands = {}
    local original_command = vim.api.nvim_create_user_command
    local original_enabled = vim.lsp.is_enabled
    local original_restart = require('arcadia-lspconfig.clients').restart
    local restarted = {}
    vim.api.nvim_create_user_command = function(name, callback)
      commands[name] = callback
    end
    vim.lsp.is_enabled = function()
      return true
    end
    require('arcadia-lspconfig.clients').restart = function(...)
      restarted[#restarted + 1] = { ... }
    end
    local definition = {
      name = 'native_fixture',
      default_options = {},
      allowed_options = {},
      config = { filetypes = { 'native_fixture' }, workspace_required = true },
      context = function(buffer)
        if buffer == bufnr then
          return { bufnr = buffer, lsp_root = root, arcadia_root = root }
        end
      end,
      command = function()
        return { vim.v.progpath, '--version' }
      end,
    }
    local ok, err = pcall(function()
      local runtime = require('arcadia-lspconfig.runtime').new { definition }
      runtime.setup { log = { level = 'off' } }
      local selected
      vim.lsp.config.native_fixture.root_dir(bufnr, function(directory)
        selected = directory
      end)
      assert.are.equal(root, selected)
      assert.are.equal(0, #vim.lsp.get_clients { name = 'native_fixture' })
      assert.is_true(runtime.refresh(bufnr))
      commands.LspArcadiaRestart()
      assert.are.same({ root, 'native_fixture', { bufnr } }, restarted[1])
      assert.are.same(restarted[1], restarted[2])
      assert.are.equal('idle', runtime.status(bufnr).servers.native_fixture.state)
      local workflow = runtime._workflow(bufnr)
      assert.are.equal('ok', workflow.health(workflow.context(bufnr))[1].level)
      vim.lsp.config.native_fixture.root_dir(999999, function()
        error 'unmatched buffers must not start'
      end)
    end)
    vim.api.nvim_create_user_command = original_command
    vim.lsp.is_enabled = original_enabled
    require('arcadia-lspconfig.clients').restart = original_restart
    vim.api.nvim_set_current_buf(original_buffer)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    helpers.cleanup(root)
    assert.is_true(ok, err)
  end)
  it('reports missing executables through status, health, and restart without starting', function()
    local status = require 'arcadia-lspconfig.status'
    local warnings = {}
    local workflow = require('arcadia-lspconfig.native').new({
      name = 'missing_fixture',
      context = function(bufnr)
        return { bufnr = bufnr, lsp_root = '/missing-project', arcadia_root = '/missing-project' }
      end,
      command = function()
        return { '/arcadia-lspconfig-missing-executable' }
      end,
    }, {
      status = status,
      notify = {
        warn_once = function(...)
          warnings[#warnings + 1] = { ... }
        end,
      },
      clients = {
        restart = function()
          error 'missing executable must not restart'
        end,
      },
    })
    workflow.root_dir(0, function()
      error 'missing executable must not start'
    end)
    local context = workflow.context(0)
    assert.are.equal('error', status.get(context.bufnr).servers.missing_fixture.state)
    assert.are.equal('warn', workflow.health(context)[1].level)
    local ok, err = workflow.restart(0)
    assert.is_nil(ok)
    assert.matches('requires executable', err)
    assert.are.equal(2, #warnings)
    status.clear()
  end)

  it('rejects incomplete native definitions and mixed startup modes', function()
    local definition = {
      name = 'invalid_fixture',
      default_options = {},
      allowed_options = {},
      context = function() end,
    }
    local Runtime = require 'arcadia-lspconfig.runtime'
    assert.has_error(function()
      Runtime.new { definition }
    end, 'native server command: expected function, got nil')
    definition.create = function() end
    assert.has_error(function()
      Runtime.new { definition }
    end, 'arcadia-lspconfig: server definitions must use either create or context and command')
  end)
end)
