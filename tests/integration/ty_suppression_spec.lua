local helpers = require 'tests.helpers'

local function count_lines(path, prefix)
  if vim.fn.filereadable(path) == 0 then
    return 0
  end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    if vim.startswith(line, prefix) then
      count = count + 1
    end
  end
  return count
end

describe('ty suppression', function()
  local sandbox
  local log
  local buffers

  before_each(function()
    sandbox = helpers.tempdir()
    log = sandbox .. '/events.log'
    buffers = {}
    vim.env.ARC_LSP_TEST_LOG = log
    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.lsp.config('ty', {
      cmd = { 'python3', fixture, 'fake-ty' },
      filetypes = { 'python' },
      root_markers = { '.git' },
    })
    require('arcadia-lspconfig').setup {
      servers = { clangd = false, pyright = false, basedpyright = false },
      log = { level = 'off' },
    }
    vim.lsp.enable 'ty'
  end)

  after_each(function()
    vim.lsp.enable('ty', false)
    for _, client in ipairs(vim.lsp.get_clients { name = 'ty', _uninitialized = true }) do
      client:stop(true)
    end
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.env.ARC_LSP_TEST_LOG = nil
    helpers.cleanup(sandbox)
  end)

  local function open_python(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = bufnr
    vim.bo[bufnr].filetype = 'python'
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })
    return bufnr
  end

  it('starts outside Arcadia but not inside it', function()
    helpers.write(sandbox .. '/external/.git/HEAD')
    helpers.write(sandbox .. '/external/main.py')
    local external = open_python(sandbox .. '/external/main.py')
    assert.is_true(vim.wait(5000, function()
      return count_lines(log, 'ty:') == 1
        and #vim.lsp.get_clients { bufnr = external, name = 'ty' } == 1
    end, 20))

    helpers.write(sandbox .. '/arcadia/.arc/HEAD')
    helpers.write(sandbox .. '/arcadia/main.py')
    local arcadia = open_python(sandbox .. '/arcadia/main.py')
    vim.wait(200, function()
      return false
    end, 20)

    assert.are.equal(1, count_lines(log, 'ty:'))
    assert.are.equal(0, #vim.lsp.get_clients { bufnr = arcadia, name = 'ty' })
  end)
end)
