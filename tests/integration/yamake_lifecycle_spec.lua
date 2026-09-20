local helpers = require 'tests.helpers'

local SOURCE = 'devtools/ide/vscode-yandex-arc/ya-make-lsp'

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

---@param executable string
---@return boolean
local function is_executable(executable)
  return vim.fn.executable(executable) == 1
end

describe('ya-make-lsp lifecycle', function()
  local sandbox
  local data_dir
  local install_dir
  local log
  local original_path
  local bufnr

  before_each(function()
    sandbox = helpers.tempdir()
    data_dir = sandbox .. '/data/ya-make-lsp'
    install_dir = vim.fs.joinpath(data_dir, SOURCE)
    log = sandbox .. '/events.log'
    original_path = vim.env.PATH
    vim.env.ARC_LSP_TEST_LOG = log
    vim.env.ARC_LSP_TEST_REVISION = string.rep('a', 40)
    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_yamake_tool.py')
    for _, tool in ipairs { 'arc', 'npm', 'node' } do
      local destination = sandbox .. '/bin/' .. tool
      vim.fn.mkdir(vim.fs.dirname(destination), 'p')
      vim.fn.writefile(vim.fn.readfile(fixture), destination)
      vim.fn.setfperm(destination, 'rwxr-xr-x')
    end
    vim.env.PATH = sandbox .. '/bin:' .. original_path

    helpers.write(sandbox .. '/arcadia/.arc/HEAD')
    helpers.write(sandbox .. '/arcadia/project/ya.make')
    require('arcadia-lspconfig.root').clear_cache()
    require('arcadia-lspconfig.jobs').setup { cancel_on_buff_exit = true, timeout_ms = 5000 }
    vim.lsp.config('ya-make-lsp', {
      cmd = { 'node', install_dir .. '/out/ya-make-lsp.js', '--stdio' },
      filetypes = { 'yamake' },
    })
    require('arcadia-lspconfig.config').capture('ya-make-lsp', vim.lsp.config['ya-make-lsp'])
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients { name = 'ya-make-lsp', _uninitialized = true }) do
      client:stop(true)
    end
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    require('arcadia-lspconfig.jobs')._reset()
    require('arcadia-lspconfig.config').clear()
    vim.env.PATH = original_path
    vim.env.ARC_LSP_TEST_LOG = nil
    vim.env.ARC_LSP_TEST_REVISION = nil
    helpers.cleanup(sandbox)
  end)

  it('exports, builds, starts, and updates from trunk', function()
    local api = {
      root = require 'arcadia-lspconfig.root',
      paths = {
        shared = function()
          return data_dir
        end,
      },
      cache = require 'arcadia-lspconfig.servers.yamake_cache',
      config = require 'arcadia-lspconfig.config',
      jobs = require 'arcadia-lspconfig.jobs',
      clients = require 'arcadia-lspconfig.clients',
      is_executable = is_executable,
      status = require 'arcadia-lspconfig.status',
      notify = require 'arcadia-lspconfig.notify',
    }
    local workflow = require 'arcadia-lspconfig.servers.yamake'(api)
    bufnr = vim.fn.bufadd(sandbox .. '/arcadia/project/ya.make')
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = 'yamake'

    assert.is_true(workflow.activate(bufnr))
    assert.is_true(vim.wait(5000, function()
      return count_lines(log, 'arc-export:') == 1
        and count_lines(log, 'npm-build:') == 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'ya-make-lsp' } == 1
    end, 20))

    assert.is_true(workflow.refresh(bufnr))
    assert.is_true(vim.wait(5000, function()
      return count_lines(log, 'arc-log:') == 2 and not workflow._state().running
    end, 20))
    assert.are.equal(1, count_lines(log, 'arc-export:'))

    vim.env.ARC_LSP_TEST_REVISION = string.rep('b', 40)
    assert.is_true(workflow.refresh(bufnr))
    assert.is_true(vim.wait(5000, function()
      return count_lines(log, 'arc-export:') == 2
        and count_lines(log, 'npm-build:') == 2
        and require('arcadia-lspconfig.servers.yamake_cache').revision(install_dir)
          == string.rep('b', 40)
    end, 20))
  end)
end)
