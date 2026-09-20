local helpers = require 'tests.helpers'

describe('Protols workflow', function()
  local cache = require 'arcadia-lspconfig.servers.protols_cache'
  local root
  local data_dir
  local buffers
  local jobs
  local patches
  local starts
  local restarts
  local statuses
  local warnings
  local api

  local function plan(files)
    local inputs = {}
    for _, file in ipairs(files) do
      inputs[#inputs + 1] = '$(SOURCE_ROOT)/' .. file
    end
    return vim.json.encode {
      graph = {
        {
          inputs = inputs,
          cmds = {
            {
              cwd = '$(SOURCE_ROOT)',
              cmd_args = {
                '$(BUILD_ROOT)/contrib/tools/protoc/protoc',
                '-I=$(SOURCE_ROOT)',
                '-I=./api/proto',
                '-I=$(BUILD_ROOT)',
              },
            },
          },
        },
      },
    }
  end

  local function add_buffer(relative)
    local path = root .. '/' .. relative
    helpers.write(path, 'syntax = "proto3";')
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = 'proto'
    buffers[#buffers + 1] = bufnr
    return bufnr
  end

  before_each(function()
    root = helpers.tempdir()
    data_dir = root .. '/data'
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/ya', '#!/bin/sh')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    helpers.write(root .. '/api/first/ya.make')
    helpers.write(root .. '/api/second/ya.make')
    buffers = {}
    jobs = {}
    patches = {}
    starts = {}
    restarts = {}
    statuses = {}
    warnings = {}
    require('arcadia-lspconfig.root').clear_cache()
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
      cache = cache,
      config = {
        extend = function(lsp_root, _, patch)
          patches[#patches + 1] = { lsp_root = lsp_root, patch = vim.deepcopy(patch) }
        end,
        resolve = function()
          return { cmd = function() end }
        end,
      },
      jobs = {
        start = function(key, spec)
          jobs[#jobs + 1] = { key = key, spec = spec }
          return {}
        end,
        add_interest = function()
          return true
        end,
        cancel = function() end,
      },
      clients = {
        start = function(lsp_root, _, selected)
          starts[#starts + 1] = { lsp_root = lsp_root, buffers = vim.deepcopy(selected) }
        end,
        restart = function(lsp_root, _, selected)
          restarts[#restarts + 1] = { lsp_root = lsp_root, buffers = vim.deepcopy(selected) }
        end,
        detach_wrong_root = function() end,
      },
      status = {
        associate = function() end,
        set = function(lsp_root, _, status)
          statuses[#statuses + 1] = { lsp_root = lsp_root, status = vim.deepcopy(status) }
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
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    helpers.cleanup(root)
  end)

  it('caches a build plan and configures Protols after the initial dump', function()
    local bufnr = add_buffer 'api/first/service.proto'
    local workflow = require 'arcadia-lspconfig.servers.protols'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(1, #jobs)
    assert.are.same(
      { root .. '/ya', 'dump', 'build-plan', '.', '--ignore-recurses' },
      jobs[1].spec.cmd
    )
    assert.are.equal(vim.fs.normalize(root .. '/api/first'), jobs[1].spec.cwd)
    helpers.write(jobs[1].spec.stdout_path, plan { 'api/first/service.proto' })
    jobs[1].spec.on_exit { code = 0, signal = 0, stderr = '' }

    assert.are.equal(1, #patches)
    assert.are.equal(vim.fs.normalize(root .. '/api/first'), patches[1].lsp_root)
    assert.are.same({ root, root .. '/api/proto' }, patches[1].patch.init_options.include_paths)
    assert.are.equal(root .. '/ya', patches[1].patch.cmd_env.ARCADIA_LSPCONFIG_YA)
    assert.are.equal(root, patches[1].patch.cmd_env.ARCADIA_LSPCONFIG_ROOT)
    assert.are.equal(1, #restarts)
    assert.are.equal('ready', statuses[#statuses].status.state)
    assert.are.same({}, warnings)
  end)

  it('reuses one cached target for every covered proto file', function()
    vim.fn.mkdir(data_dir, 'p')
    local raw = root .. '/cached-plan.json'
    helpers.write(
      raw,
      plan {
        'api/first/service.proto',
        'api/second/dependency.proto',
        'api/second/another.proto',
      }
    )
    local record = assert(cache.from_plan(raw, root, root .. '/api/first', 'unused', 10))
    assert(cache.install(data_dir, raw, record, 'cached'))
    local dependency = add_buffer 'api/second/dependency.proto'
    local another = add_buffer 'api/second/another.proto'
    local workflow = require 'arcadia-lspconfig.servers.protols'(api)

    assert.is_true(workflow.activate(dependency))
    assert.is_true(workflow.activate(another))

    assert.are.equal(2, #starts)
    assert.are.equal(1, #jobs)
    assert.are.equal(vim.fs.normalize(root .. '/api/first'), jobs[1].spec.cwd)
    assert.are.equal(vim.fs.normalize(root .. '/api/second'), patches[1].lsp_root)
  end)
end)
