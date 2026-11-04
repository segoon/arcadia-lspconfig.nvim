local helpers = require 'tests.helpers'

describe('infractl automatic activation', function()
  it(
    'attaches matching files, shares a project client, and ignores other YAML and external files',
    function()
      local sandbox = helpers.tempdir()
      local root = sandbox .. '/arcadia'
      local buffers = {}
      local fixture = vim.fn.getcwd() .. '/tests/fixtures/fake_ya.py'
      helpers.write(root .. '/.arc/HEAD')
      helpers.write(root .. '/project/a.yaml')
      vim.fn.writefile(vim.fn.readfile(fixture), root .. '/ya')
      vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
      vim.env.ARC_LSP_TEST_LOG = sandbox .. '/events.log'
      require('arcadia-lspconfig').setup {
        servers = {
          clangd = false,
          pyright = false,
          basedpyright = false,
          ty = false,
          protols = false,
          ['ya-make-lsp'] = false,
        },
        log = { level = 'off' },
      }

      ---@param path string
      ---@return integer
      local function open(path)
        vim.cmd.edit(vim.fn.fnameescape(path))
        local bufnr = vim.api.nvim_get_current_buf()
        buffers[#buffers + 1] = bufnr
        return bufnr
      end

      local ok, err = pcall(function()
        local star = open(root .. '/project/main.star')
        assert.is_true(vim.wait(5000, function()
          return #vim.lsp.get_clients { bufnr = star, name = 'infractl' } == 1
        end, 20))
        local id = vim.lsp.get_clients({ bufnr = star, name = 'infractl' })[1].id
        for _, name in ipairs { 'i.yaml', 'i.prod.yaml' } do
          local bufnr = open(root .. '/project/' .. name)
          assert.is_true(vim.wait(5000, function()
            return vim.lsp.buf_is_attached(bufnr, id)
          end, 20))
        end
        for _, restart in ipairs {
          function()
            assert.is_true(require('arcadia-lspconfig').refresh(star))
          end,
          function()
            vim.api.nvim_set_current_buf(star)
            vim.cmd.LspArcadiaRestart()
          end,
        } do
          restart()
          local previous = id
          assert.is_true(vim.wait(5000, function()
            local clients = vim.lsp.get_clients { bufnr = star, name = 'infractl' }
            if #clients == 1 and clients[1].id ~= previous then
              id = clients[1].id
              return true
            end
            return false
          end, 20))
          for _, bufnr in ipairs(buffers) do
            assert.is_true(vim.lsp.buf_is_attached(bufnr, id))
          end
        end
        assert.are.equal('ready', require('arcadia-lspconfig').status(star).servers.infractl.state)
        local other = open(root .. '/project/other.yaml')
        local external = open(sandbox .. '/external/main.star')
        vim.wait(100, function()
          return false
        end)
        assert.are.equal(0, #vim.lsp.get_clients { bufnr = other, name = 'infractl' })
        assert.are.equal(0, #vim.lsp.get_clients { bufnr = external, name = 'infractl' })
        assert.are.equal(1, #vim.lsp.get_clients { name = 'infractl' })
      end)

      vim.lsp.enable('infractl', false)
      for _, client in ipairs(vim.lsp.get_clients { name = 'infractl', _uninitialized = true }) do
        client:stop(true)
      end
      for _, bufnr in ipairs(buffers) do
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      vim.env.ARC_LSP_TEST_LOG = nil
      helpers.cleanup(sandbox)
      assert.is_true(ok, err)
    end
  )
end)
