local helpers = require 'tests.helpers'

describe('clangd workflow', function()
  local root
  local source
  local bufnr
  local captured_jobs
  local captured_keys
  local cancelled_keys
  local patches
  local starts
  local restarts
  local warnings
  local statuses
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

    captured_jobs = {}
    captured_keys = {}
    cancelled_keys = {}
    patches = {}
    starts = {}
    restarts = {}
    warnings = {}
    statuses = {}
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
      cache = require 'arcadia-lspconfig.servers.clangd_cache',
      config = {
        extend = function(_, _, patch)
          patches[#patches + 1] = patch
        end,
      },
      jobs = {
        start = function(key, spec)
          captured_keys[#captured_keys + 1] = key
          captured_jobs[#captured_jobs + 1] = spec
          return {}
        end,
        add_interest = function()
          return true
        end,
        cancel = function(key)
          cancelled_keys[#cancelled_keys + 1] = key
        end,
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
        set = function(_, _, value)
          statuses[#statuses + 1] = vim.deepcopy(value)
        end,
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

  it('runs dump and make in parallel and reloads for both successes', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(2, #captured_jobs)
    local key = vim.fs.normalize(root .. '/project') .. '\0clangd\0'
    assert.are.same({ key .. 'compile_commands', key .. 'build' }, captured_keys)
    local dump_job = captured_jobs[1]
    local build_job = captured_jobs[2]
    assert.are.same(root .. '/ya', dump_job.cmd[1])
    assert.are.same({ root .. '/ya', 'dump', 'compile-commands' }, {
      dump_job.cmd[1],
      dump_job.cmd[2],
      dump_job.cmd[3],
    })
    assert.are.same(vim.fs.normalize(root .. '/project'), dump_job.cwd)
    local temporary = dump_job.cmd[4]:match '^%-%-output%-file=(.+)$'
    assert.are.equal('--cmd-build-root=' .. root .. '/data/build_root', dump_job.cmd[5])
    assert.are.same({
      root .. '/ya',
      'make',
      '--add-result=.hpp',
      '--add-result=.cpp',
      '--replace-result',
      '-o=' .. root .. '/data/build_root',
    }, build_job.cmd)
    assert.are.same(vim.fs.normalize(root .. '/project'), build_job.cwd)
    helpers.write(temporary, '[{"file":"main.cpp"}]')
    dump_job.on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.same({ root .. '/ya', 'tool', 'clangd' }, patches[1].cmd)
    assert.are.same(root .. '/data', patches[2].init_options.compilationDatabasePath)
    assert.are.equal(0, #starts)
    assert.are.equal(1, #restarts)
    assert.are.equal('build', statuses[#statuses].stage)

    build_job.on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(2, #restarts)
    assert.are.equal('ready', statuses[#statuses].state)
    assert.are.equal('prepare', statuses[#statuses].stage)
  end)

  it('starts cached data immediately and reloads twice after an unchanged dump', function()
    helpers.write(root .. '/data/compile_commands.json', '[]')
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(1, #starts)
    local temporary = captured_jobs[1].cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(temporary, '[]')
    captured_jobs[1].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }
    assert.are.equal(1, #restarts)
    captured_jobs[2].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(2, #restarts)
  end)

  it('waits for dump when make finishes before the first database exists', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    captured_jobs[2].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(0, #starts)
    assert.are.equal(0, #restarts)
    assert.are.equal('waiting', statuses[#statuses].state)
    assert.are.equal('compile_commands', statuses[#statuses].stage)

    local temporary = captured_jobs[1].cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(temporary, '[]')
    captured_jobs[1].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(1, #restarts)
    assert.are.equal('ready', statuses[#statuses].state)
    assert.are.equal('prepare', statuses[#statuses].stage)
  end)

  it('does not start clangd when initial generation fails', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    captured_jobs[1].on_exit { code = 1, signal = 0, stdout = '', stderr = 'failed' }
    captured_jobs[2].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }

    assert.are.equal(0, #starts)
    assert.are.equal(0, #restarts)
    assert.are.same({ 'ya_failed' }, warnings)
    assert.are.equal(2, #captured_jobs)
    assert.are.equal('error', statuses[#statuses].state)
    assert.are.equal('compile_commands', statuses[#statuses].stage)
  end)

  it('keeps the post-dump client when ya make fails', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    local temporary = captured_jobs[1].cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(temporary, '[]')
    captured_jobs[1].on_exit { code = 0, signal = 0, stdout = '', stderr = '' }
    captured_jobs[2].on_exit { code = 1, signal = 0, stdout = '', stderr = 'build failed\n' }

    assert.are.equal(1, #restarts)
    assert.are.same({ 'ya_make_failed' }, warnings)
    assert.are.equal('error', statuses[#statuses].state)
    assert.are.equal('build', statuses[#statuses].stage)
    assert.are.equal('ya make failed: build failed', statuses[#statuses].message)
  end)

  it('prioritizes a dump error regardless of parallel completion order', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    captured_jobs[2].on_exit { code = 1, signal = 0, stdout = '', stderr = 'build failed' }
    assert.are.equal('waiting', statuses[#statuses].state)
    assert.are.equal('compile_commands', statuses[#statuses].stage)

    captured_jobs[1].on_exit { code = 1, signal = 0, stdout = '', stderr = 'dump failed' }

    assert.are.equal('error', statuses[#statuses].state)
    assert.are.equal('compile_commands', statuses[#statuses].stage)
    assert.are.equal('ya dump compile-commands failed: dump failed', statuses[#statuses].message)
    assert.are.same({ 'ya_make_failed', 'ya_failed' }, warnings)
  end)

  it('does not start clangd from an invalid cached database', function()
    helpers.write(root .. '/data/compile_commands.json', '{}')
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))

    assert.are.equal(0, #starts)
    assert.are.equal(2, #captured_jobs)
  end)

  it('does not let stale completion delete a newer temporary database', function()
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    assert.is_true(workflow.activate(bufnr))
    local old_job = captured_jobs[1]
    local old_temporary = old_job.cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(old_temporary, '[]')

    assert.is_true(workflow.refresh(bufnr))
    local new_job = captured_jobs[3]
    local new_temporary = new_job.cmd[4]:match '^%-%-output%-file=(.+)$'
    helpers.write(new_temporary, '[{"file":"main.cpp"}]')

    old_job.on_exit { code = 0, signal = 15, stdout = '', stderr = '', cancelled = true }

    assert.are.equal(0, vim.fn.filereadable(old_temporary))
    assert.are.equal(1, vim.fn.filereadable(new_temporary))
    assert.are.equal(4, #captured_jobs)
    local key = vim.fs.normalize(root .. '/project') .. '\0clangd\0'
    assert.are.same({ key .. 'compile_commands', key .. 'build' }, cancelled_keys)
  end)

  it('refuses a manual restart without a valid database', function()
    helpers.write(root .. '/data/compile_commands.json', 'not json')
    local workflow = require 'arcadia-lspconfig.servers.clangd'(api)

    local ok, message = workflow.restart(bufnr)

    assert.is_nil(ok)
    assert.matches('valid compilation database', message)
    assert.are.equal(0, #starts)
    assert.are.equal(0, #restarts)
  end)
end)
