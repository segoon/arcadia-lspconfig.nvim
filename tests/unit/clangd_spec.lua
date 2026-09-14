local helpers = require 'tests.helpers'

describe('clangd workflow', function()
  local root
  local source
  local bufnr
  local captured_job
  local patches
  local starts
  local restarts
  local warnings
  local has_client
  local api

  before_each(function()
    root = helpers.tempdir()
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/ya', '#!/bin/sh')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    helpers.write(root .. '/project/ya.make')
    source = root .. '/project/main.cpp'
    helpers.write(source)
    bufnr = vim.fn.bufadd(source)
    vim.fn.bufload(bufnr)
    require('arcadia-lspconfig.root').clear_cache()

    patches = {}
    starts = {}
    restarts = {}
    warnings = {}
    has_client = false
    local data_dir = root .. '/data'
    api = {
      root = require 'arcadia-lspconfig.root',
      paths = {
        data = function()
          return data_dir
        end,
        ensure = function(path)
          vim.fn.mkdir(path, 'p')
          return true
        end,
      },
      cache = require 'arcadia-lspconfig.cache',
      config = {
        extend = function(_, _, patch)
          patches[#patches + 1] = patch
        end,
      },
      jobs = {
        start = function(_, spec)
          captured_job = spec
          return {}
        end,
        add_interest = function()
          return true
        end,
        cancel = function() end,
      },
      clients = {
        start = function(_, _, buffers)
          starts[#starts + 1] = vim.deepcopy(buffers)
          has_client = true
        end,
        restart = function(_, _, buffers)
          restarts[#restarts + 1] = vim.deepcopy(buffers)
        end,
        get = function()
          return has_client and { {} } or {}
        end,
        detach_wrong_root = function() end,
      },
      status = {
        associate = function() end,
        set = function() end,
      },
      notify = {
        warn_once = function(_, _, code)
          warnings[#warnings + 1] = code
        end,
      },
    }
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    helpers.cleanup(root)
  end)

  it('runs checkout-local ya and starts with a generated database', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.same(root .. '/ya', captured_job.cmd[1])
    assert.are.same({ root .. '/ya', 'dump', 'compile-commands' }, {
      captured_job.cmd[1],
      captured_job.cmd[2],
      captured_job.cmd[3],
    })
    assert.are.same(vim.fs.normalize(root .. '/project'), captured_job.cwd)
    local temporary = captured_job.cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(temporary, '[{"file":"main.cpp"}]')
    captured_job.on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.same({ root .. '/ya', 'tool', 'clangd' }, patches[1].cmd)
    assert.are.same(root .. '/data', patches[2].init_options.compilationDatabasePath)
    assert.are.equal(1, #starts)
    assert.are.equal(0, #restarts)
  end)

  it('starts cached data immediately and restarts only for changed output', function()
    helpers.write(root .. '/data/compile_commands.json', '[]')
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(1, #starts)
    local temporary = captured_job.cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(temporary, '[{"file":"main.cpp"}]')
    captured_job.on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(1, #restarts)
  end)

  it('keeps one fallback start when initial generation fails', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    captured_job.on_exit { code = 1, signal = 0, stdout = '', stderr = 'failed' }

    assert.are.equal(1, #starts)
    assert.are.same({ 'ya_failed' }, warnings)
  end)
end)
