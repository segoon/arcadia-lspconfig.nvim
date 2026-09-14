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

describe('Pyright lifecycle', function()
  local setup_done = false
  local sandbox
  local log
  local buffers
  local paths

  before_each(function()
    sandbox = helpers.tempdir()
    log = sandbox .. '/events.log'
    buffers = {}
    paths = require 'arcadia-lspconfig.paths'
    vim.env.ARC_LSP_TEST_LOG = log

    if not setup_done then
      local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
      vim.lsp.config('pyright', {
        cmd = { 'python3', fixture, 'fake-pyright' },
        filetypes = { 'python' },
        root_markers = { '.git' },
      })
      require('arcadia-lspconfig').setup {
        servers = { clangd = false },
        jobs = { cancel_on_buff_exit = true, timeout_ms = 5000 },
        log = { level = 'off' },
      }
      vim.lsp.enable 'pyright'
      setup_done = true
    end
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients { name = 'pyright', _uninitialized = true }) do
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

  local function checkout(name)
    local root = sandbox .. '/' .. name
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/main.py', 'value = 1')
    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.fn.writefile(vim.fn.readfile(fixture), root .. '/ya')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    return root
  end

  local function open_python(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = bufnr
    vim.bo[bufnr].filetype = 'python'
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })
    return bufnr
  end

  it('generates cached import paths and starts Pyright', function()
    local root = checkout 'success'
    local bufnr = open_python(root .. '/project/main.py')
    local data_dir = paths.data(vim.fs.normalize(root .. '/project'), 'pyright')

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.pyright.state == 'ready'
        and count_lines(log, 'ide:') == 1
        and count_lines(log, 'pyright:') == 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'pyright' } == 1
    end, 20))

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'pyright' })[1]
    assert.are.same({
      vim.fs.normalize(root .. '/project'),
      client.config.settings.python.analysis.extraPaths[2],
    }, client.config.settings.python.analysis.extraPaths)
    assert.is_not_nil(
      require('arcadia-lspconfig.servers.pyright_cache').read(data_dir .. '/config.json')
    )
    assert.are.equal(0, vim.fn.filereadable(root .. '/project/pyrightconfig.json'))
    helpers.cleanup(data_dir)
  end)

  it('honors a project configuration without running ya ide', function()
    local root = checkout 'project-config'
    helpers.write(root .. '/project/pyrightconfig.json', '{"extraPaths":[]}')
    local bufnr = open_python(root .. '/project/main.py')

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.pyright.state == 'ready'
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'pyright' } == 1
    end, 20))
    assert.are.equal(0, count_lines(log, 'ide:'))
  end)
end)
