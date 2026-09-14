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

local function has_line(path, expected)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  for _, line in ipairs(vim.fn.readfile(path)) do
    if line == expected then
      return true
    end
  end
  return false
end

describe('clangd lifecycle', function()
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
      vim.lsp.config('clangd', {
        cmd = { 'arcadia-lspconfig-system-clangd-does-not-exist' },
        filetypes = { 'cpp' },
        root_markers = { '.git' },
      })
      require('arcadia-lspconfig').setup {
        jobs = { cancel_on_buff_exit = true, timeout_ms = 5000 },
        log = { level = 'off' },
      }
      vim.lsp.enable 'clangd'
      assert.are.equal('function', type(vim.lsp.config.clangd.cmd))
      setup_done = true
    end
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients { name = 'clangd', _uninitialized = true }) do
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

  local function checkout(name, compile_commands)
    local root = sandbox .. '/' .. name
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/.fake_compile_commands', compile_commands)
    helpers.write(root .. '/project/main.cpp', 'int main() { return 0; }')
    local fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.fn.writefile(vim.fn.readfile(fixture), root .. '/ya')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    return root
  end

  local function open_cpp(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = bufnr
    vim.bo[bufnr].filetype = 'cpp'
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })
    return bufnr
  end

  it('delegates root detection outside an applicable Arcadia target', function()
    local outside = sandbox .. '/outside'
    helpers.write(outside .. '/.git/HEAD')
    helpers.write(outside .. '/main.cpp', 'int main() { return 0; }')
    local bufnr = open_cpp(outside .. '/main.cpp')
    local detected

    vim.lsp.config.clangd.root_dir(bufnr, function(root)
      detected = root
    end)

    assert.are.equal(vim.fs.normalize(outside), detected)
    assert.is_nil(require('arcadia-lspconfig').status(bufnr))
  end)

  it('runs preparation in parallel and starts checkout-local clangd after the dump', function()
    local root = checkout('success', '[{"file":"main.cpp","command":"c++ main.cpp"}]')
    helpers.write(root .. '/project/.fake_ya_require_parallel')
    local bufnr = open_cpp(root .. '/project/main.cpp')
    local data_dir = paths.data(vim.fs.normalize(root .. '/project'), 'clangd')
    local database = data_dir .. '/compile_commands.json'

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'ready'
        and count_lines(log, 'make:') == 1
        and vim.fn.filereadable(database) == 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'clangd' } == 1
    end, 20))

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'clangd' })[1]
    assert.are.same({ root .. '/ya', 'tool', 'clangd' }, client.config.cmd)
    assert.are.equal(data_dir, client.config.init_options.compilationDatabasePath)
    assert.are.equal(1, count_lines(log, 'dump:'))
    assert.is_true(count_lines(log, 'clangd:') >= 1)
    assert.is_true(count_lines(log, 'clangd:') <= 2)
    assert.is_true(
      has_line(
        log,
        'dump:'
          .. vim.fs.normalize(root .. '/project')
          .. ':--cmd-build-root='
          .. data_dir
          .. '/build_root'
      )
    )
    assert.is_true(
      has_line(
        log,
        'make:'
          .. vim.fs.normalize(root .. '/project')
          .. ':--add-result=.hpp --add-result=.cpp --replace-result -o='
          .. data_dir
          .. '/build_root'
      )
    )
    helpers.cleanup(data_dir)
  end)

  it('reloads after dump and make for changed and unchanged refreshes', function()
    local root = checkout('refresh', '[]')
    local data_dir = paths.data(vim.fs.normalize(root .. '/project'), 'clangd')
    helpers.write(data_dir .. '/compile_commands.json', '[]')
    local bufnr = open_cpp(root .. '/project/main.cpp')

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'ready'
        and count_lines(log, 'make:') == 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'clangd' } == 1
    end, 20))
    helpers.write(
      root .. '/project/.fake_compile_commands',
      '[{"file":"main.cpp","command":"c++ main.cpp"}]'
    )
    assert.is_true(require('arcadia-lspconfig').refresh(bufnr))
    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'ready'
        and count_lines(log, 'dump:') == 2
        and count_lines(log, 'make:') == 2
    end, 20))

    assert.is_true(require('arcadia-lspconfig').refresh(bufnr))
    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'ready'
        and count_lines(log, 'dump:') == 3
        and count_lines(log, 'make:') == 3
    end, 20))
    helpers.cleanup(data_dir)
  end)

  it('keeps the post-dump clangd when make fails', function()
    local root = checkout('make-failure', '[]')
    helpers.write(root .. '/project/.fake_ya_make_fail')
    local bufnr = open_cpp(root .. '/project/main.cpp')
    local data_dir = paths.data(vim.fs.normalize(root .. '/project'), 'clangd')

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'error'
        and value.servers.clangd.stage == 'build'
        and count_lines(log, 'clangd:') == 1
        and #vim.lsp.get_clients { bufnr = bufnr, name = 'clangd' } == 1
    end, 20))
    assert.are.equal(1, count_lines(log, 'make:'))
    helpers.cleanup(data_dir)
  end)

  it('does not start any clangd when initial generation fails', function()
    local root = checkout('failure', '[]')
    helpers.write(root .. '/project/.fake_ya_fail')
    local bufnr = open_cpp(root .. '/project/main.cpp')
    local data_dir = paths.data(vim.fs.normalize(root .. '/project'), 'clangd')

    assert.is_true(vim.wait(5000, function()
      local value = require('arcadia-lspconfig').status(bufnr)
      return value
        and value.servers.clangd.state == 'error'
        and value.servers.clangd.stage == 'compile_commands'
        and count_lines(log, 'make:') == 1
    end, 20))
    assert.are.equal(0, count_lines(log, 'clangd:'))
    assert.are.equal(0, #vim.lsp.get_clients { bufnr = bufnr, name = 'clangd' })
    helpers.cleanup(data_dir)
  end)
end)
