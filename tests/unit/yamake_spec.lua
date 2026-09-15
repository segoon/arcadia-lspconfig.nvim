local helpers = require 'tests.helpers'

describe('ya-make-lsp workflow', function()
  local root
  local bufnr
  local jobs
  local patches
  local starts
  local restarts
  local warnings
  local statuses
  local data_dir
  local api

  before_each(function()
    root = helpers.tempdir()
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/project/ya.make')
    bufnr = vim.fn.bufadd(root .. '/project/ya.make')
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = 'yamake'
    require('arcadia-lspconfig.root').clear_cache()

    jobs = {}
    patches = {}
    starts = {}
    restarts = {}
    warnings = {}
    statuses = {}
    data_dir = root .. '/data/ya-make-lsp'
    api = {
      root = require 'arcadia-lspconfig.root',
      paths = {
        shared = function()
          return data_dir
        end,
      },
      cache = require 'arcadia-lspconfig.servers.yamake_cache',
      config = {
        extend = function(_, _, patch)
          patches[#patches + 1] = patch
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
      },
      clients = {
        start = function(lsp_root, _, buffers)
          starts[#starts + 1] = { lsp_root = lsp_root, buffers = vim.deepcopy(buffers) }
        end,
        restart = function(lsp_root, _, buffers)
          restarts[#restarts + 1] = { lsp_root = lsp_root, buffers = vim.deepcopy(buffers) }
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

  local function finish(index, result)
    jobs[index].spec.on_exit(vim.tbl_extend('force', {
      code = 0,
      signal = 0,
      stdout = '',
      stderr = '',
    }, result or {}))
  end

  it('exports trunk, builds in the managed directory, and starts the first client', function()
    local workflow = require 'arcadia-lspconfig.servers.yamake'(api)
    local revision = string.rep('a', 40)

    assert.is_true(workflow.activate(bufnr))
    assert.are.same({
      'arc',
      'log',
      '-n1',
      'trunk',
      '--oneline',
      'devtools/ide/vscode-yandex-arc/ya-make-lsp',
    }, jobs[1].spec.cmd)
    assert.are.equal(vim.fs.normalize(root), jobs[1].spec.cwd)

    finish(1, { stdout = revision .. ' first revision\n' })
    assert.are.same({
      'arc',
      'export',
      'trunk',
      'devtools/ide/vscode-yandex-arc/ya-make-lsp',
      '--to',
      data_dir,
    }, jobs[2].spec.cmd)
    assert.are.equal(vim.fs.normalize(root), jobs[2].spec.cwd)

    finish(2)
    assert.are.same({ 'npm', 'install' }, jobs[3].spec.cmd)
    assert.are.equal(data_dir, jobs[3].spec.cwd)
    finish(3)
    assert.are.same({ 'npm', 'run', 'build' }, jobs[4].spec.cmd)
    assert.are.equal(data_dir, jobs[4].spec.cwd)

    helpers.write(data_dir .. '/out/ya-make-lsp.js')
    finish(4)

    assert.are.equal(revision, api.cache.revision(data_dir))
    assert.are.equal(1, #starts)
    assert.are.equal(0, #restarts)
    assert.are.same({ 'node', data_dir .. '/out/ya-make-lsp.js', '--stdio' }, patches[1].cmd)
    assert.are.equal('ready', statuses[#statuses].state)
  end)

  it('starts a cached server immediately and skips an unchanged revision', function()
    local revision = string.rep('b', 40)
    helpers.write(data_dir .. '/out/ya-make-lsp.js')
    helpers.write(data_dir .. '/.arcadia-revision', revision)
    local workflow = require 'arcadia-lspconfig.servers.yamake'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(1, #starts)
    finish(1, { stdout = revision .. ' unchanged\n' })

    assert.are.equal(1, #jobs)
    assert.are.equal(0, #restarts)
    assert.are.equal('ready', statuses[#statuses].state)
  end)

  it('keeps a cached server when an update fails', function()
    local old_revision = string.rep('c', 40)
    helpers.write(data_dir .. '/out/ya-make-lsp.js', 'old')
    helpers.write(data_dir .. '/.arcadia-revision', old_revision)
    local workflow = require 'arcadia-lspconfig.servers.yamake'(api)

    assert.is_true(workflow.activate(bufnr))
    finish(1, { stdout = string.rep('d', 40) .. ' changed\n' })
    finish(2, { code = 1, stderr = 'export failed\n' })

    assert.are.equal(old_revision, api.cache.revision(data_dir))
    assert.are.equal('old', vim.fn.readfile(data_dir .. '/out/ya-make-lsp.js')[1])
    assert.are.same({ 'export_failed' }, warnings)
    assert.are.equal('warning', statuses[#statuses].state)
    assert.are.equal(0, #restarts)
  end)

  it('reinstalls and restarts after the revision changes', function()
    local old_revision = string.rep('e', 40)
    local new_revision = string.rep('f', 40)
    helpers.write(data_dir .. '/out/ya-make-lsp.js', 'old')
    helpers.write(data_dir .. '/.arcadia-revision', old_revision)
    local workflow = require 'arcadia-lspconfig.servers.yamake'(api)

    assert.is_true(workflow.activate(bufnr))
    finish(1, { stdout = new_revision .. ' changed\n' })
    finish(2)
    finish(3)
    helpers.write(data_dir .. '/out/ya-make-lsp.js', 'new')
    finish(4)

    assert.are.equal(new_revision, api.cache.revision(data_dir))
    assert.are.equal(1, #starts)
    assert.are.equal(1, #restarts)
  end)
  it('registers only the exact ya.make filename', function()
    require 'arcadia-lspconfig.servers.yamake'(api)

    assert.are.equal('yamake', vim.filetype.match { filename = root .. '/project/ya.make' })
    assert.is_not.equal('yamake', vim.filetype.match { filename = root .. '/project/ya.make.inc' })
  end)
end)
