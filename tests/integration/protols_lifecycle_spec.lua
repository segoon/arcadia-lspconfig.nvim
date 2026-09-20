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

local function matching_line(path, prefix)
  for _, line in ipairs(vim.fn.readfile(path)) do
    if vim.startswith(line, prefix) then
      return line
    end
  end
end

describe('Protols lifecycle', function()
  local setup_done = false
  local sandbox
  local log
  local buffers
  local data_dir
  local fixture

  before_each(function()
    sandbox = helpers.tempdir()
    log = sandbox .. '/events.log'
    buffers = {}
    fixture = vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'fixtures', 'fake_ya.py')
    vim.env.ARC_LSP_TEST_LOG = log

    if not setup_done then
      vim.lsp.config('protols', {
        cmd = { fixture, 'fake-protols' },
        filetypes = { 'proto' },
        root_markers = { '.git' },
      })
      require('arcadia-lspconfig').setup {
        jobs = { cancel_on_buff_exit = true, timeout_ms = 5000 },
        log = { level = 'off' },
      }
      vim.lsp.enable 'protols'
      setup_done = true
    end
  end)

  after_each(function()
    for _, client in ipairs(vim.lsp.get_clients { name = 'protols', _uninitialized = true }) do
      client:stop(true)
    end
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.env.ARC_LSP_TEST_LOG = nil
    if data_dir then
      helpers.cleanup(data_dir)
    end
    helpers.cleanup(sandbox)
  end)

  local function open_proto(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    buffers[#buffers + 1] = bufnr
    vim.bo[bufnr].filetype = 'proto'
    vim.api.nvim_exec_autocmds('FileType', { buffer = bufnr, modeline = false })
    return bufnr
  end

  it('shares a cached build plan and routes tools through checkout-local ya', function()
    local root = sandbox .. '/arcadia'
    helpers.write(root .. '/.arc/HEAD')
    vim.fn.writefile(vim.fn.readfile(fixture), root .. '/ya')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    helpers.write(root .. '/api/first/ya.make')
    helpers.write(root .. '/api/second/ya.make')
    helpers.write(root .. '/api/first/service.proto', 'syntax = "proto3";')
    helpers.write(root .. '/api/second/dependency.proto', 'syntax = "proto3";')
    helpers.write(
      root .. '/api/first/.fake_build_plan',
      vim.json.encode {
        graph = {
          {
            inputs = {
              '$(SOURCE_ROOT)/api/first/service.proto',
              '$(SOURCE_ROOT)/api/second/dependency.proto',
            },
            cmds = {
              {
                cwd = '$(SOURCE_ROOT)',
                cmd_args = {
                  '$(BUILD_ROOT)/contrib/tools/protoc/protoc',
                  '-I=$(SOURCE_ROOT)',
                  '-I=./api',
                  '-I=$(BUILD_ROOT)',
                },
              },
            },
          },
        },
      }
    )
    data_dir = require('arcadia-lspconfig.paths').data(vim.fs.normalize(root), 'protols')

    local first = open_proto(root .. '/api/first/service.proto')
    assert.is_true(vim.wait(5000, function()
      local status = require('arcadia-lspconfig').status(first)
      return status
        and status.servers.protols.state == 'ready'
        and #vim.lsp.get_clients { bufnr = first, name = 'protols' } == 1
    end, 20))

    local second = open_proto(root .. '/api/second/dependency.proto')
    assert.is_true(vim.wait(5000, function()
      return #vim.lsp.get_clients { bufnr = second, name = 'protols' } == 1
    end, 20))
    assert.are.equal(1, count_lines(log, 'build-plan:'))
    local client = vim.lsp.get_clients({ bufnr = second, name = 'protols' })[1]
    assert.are.same({ root, root .. '/api' }, client.config.init_options.include_paths)

    local env = vim.tbl_extend('force', vim.fn.environ(), client.config.cmd_env)
    local protoc = vim
      .system(
        { data_dir .. '/bin/protoc', '--version' },
        { cwd = root .. '/api/second', env = env, text = true }
      )
      :wait()
    local clang_format = vim
      .system(
        { data_dir .. '/bin/clang-format', '--version' },
        { cwd = root .. '/api/second', env = env, text = true }
      )
      :wait()
    assert.are.equal(0, protoc.code)
    assert.are.equal(0, clang_format.code)
    assert.are.equal(
      'protoc:' .. root .. '/api/second:' .. root .. '/contrib/tools/protoc -- --version',
      matching_line(log, 'protoc:')
    )
    assert.are.equal(
      'clang-format:' .. root .. '/api/second:--version',
      matching_line(log, 'clang-format:')
    )
  end)
end)
