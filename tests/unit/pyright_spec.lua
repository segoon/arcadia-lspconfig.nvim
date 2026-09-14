local helpers = require 'tests.helpers'

describe('Pyright workflow', function()
  local root
  local bufnr
  local api
  local jobs
  local patches
  local starts
  local restarts
  local statuses
  local warnings
  local cancelled

  before_each(function()
    root = helpers.tempdir()
    helpers.write(root .. '/.arc/HEAD')
    helpers.write(root .. '/ya')
    vim.fn.setfperm(root .. '/ya', 'rwxr-xr-x')
    helpers.write(root .. '/pyright-langserver')
    vim.fn.setfperm(root .. '/pyright-langserver', 'rwxr-xr-x')
    helpers.write(root .. '/basedpyright-langserver')
    vim.fn.setfperm(root .. '/basedpyright-langserver', 'rwxr-xr-x')
    helpers.write(root .. '/project/ya.make')
    helpers.write(root .. '/project/main.py')
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. '/project/main.py')

    jobs, patches, starts, restarts, statuses, warnings, cancelled = {}, {}, {}, {}, {}, {}, {}
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
      cache = require 'arcadia-lspconfig.servers.pyright_cache',
      config = {
        extend = function(_, _, patch)
          patches[#patches + 1] = vim.deepcopy(patch)
        end,
        resolve = function()
          return { cmd = { root .. '/pyright-langserver', '--stdio' } }
        end,
      },
      jobs = {
        start = function(_, spec)
          jobs[#jobs + 1] = spec
          return {}
        end,
        add_interest = function()
          return true
        end,
        cancel = function(key)
          cancelled[#cancelled + 1] = key
        end,
      },
      clients = {
        start = function(_, _, buffers)
          starts[#starts + 1] = vim.deepcopy(buffers)
        end,
        restart = function(_, _, buffers)
          restarts[#restarts + 1] = vim.deepcopy(buffers)
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
    require('arcadia-lspconfig.root').clear_cache()
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    helpers.cleanup(root)
  end)

  local function complete(job, extra_paths)
    local project = job.cmd[#job.cmd]:match '^%-P=(.+)$'
    helpers.write(
      project .. '/arcadia-pyright.code-workspace',
      vim.json.encode {
        settings = {
          ['python.analysis.extraPaths'] = extra_paths or { '/arcadia', project .. '/.links' },
        },
      }
    )
    job.on_exit { code = 0, signal = 0, stdout = '', stderr = '' }
    return project
  end

  it('generates automatically and starts only after success', function()
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)

    assert.is_true(workflow.activate(bufnr))
    assert.are.equal(0, #starts)
    assert.are.equal(1, #jobs)
    assert.are.same({
      root .. '/ya',
      'ide',
      'vscode',
      '--py3',
      '--no-pyright-config',
      '-W=arcadia-pyright',
    }, vim.list_slice(jobs[1].cmd, 1, 6))
    assert.are.equal(vim.fs.normalize(root .. '/project'), jobs[1].cwd)

    local project = complete(jobs[1], { '/arcadia', '/generated' })

    assert.are.same({ '/arcadia', '/generated' }, patches[1].settings.python.analysis.extraPaths)
    assert.are.equal(1, #restarts)
    assert.are.equal('ready', statuses[#statuses].state)
    assert.are.equal(project, assert(api.cache.read(root .. '/data/config.json')).project_dir)
  end)

  it('starts a valid cache immediately and refreshes in the background', function()
    local project = root .. '/data/old'
    vim.fn.mkdir(project, 'p')
    assert(api.cache.install(root .. '/data/config.json', {
      project_dir = project,
      extra_paths = { '/cached' },
    }, 1))
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)

    assert.is_true(workflow.activate(bufnr))

    assert.are.equal(1, #starts)
    assert.are.equal(1, #jobs)
    assert.are.same({ '/cached' }, patches[1].settings.python.analysis.extraPaths)
  end)

  it('uses the BasedPyright server and executable when selected', function()
    local configured_server
    local restarted_server
    api.config.resolve = function(_, server)
      configured_server = server
      return { cmd = { root .. '/basedpyright-langserver', '--stdio' } }
    end
    api.config.extend = function(_, server, patch)
      configured_server = server
      patches[#patches + 1] = vim.deepcopy(patch)
    end
    api.clients.restart = function(_, server, buffers)
      restarted_server = server
      restarts[#restarts + 1] = vim.deepcopy(buffers)
    end
    local workflow =
      require 'arcadia-lspconfig.servers.pyright'(api, 'basedpyright', 'BasedPyright')

    assert.is_true(workflow.activate(bufnr))
    complete(jobs[1], { '/based' })

    assert.are.equal('basedpyright', configured_server)
    assert.are.equal('basedpyright', restarted_server)
    assert.are.same({ '/based' }, patches[1].settings.basedpyright.analysis.extraPaths)
    assert.is_nil(patches[1].settings.python)
    assert.are.equal('ready', statuses[#statuses].state)
    assert.are.equal('basedpyright_config', statuses[#statuses].stage)
  end)

  it('honors a project pyrightconfig without generation', function()
    helpers.write(root .. '/project/pyrightconfig.json', '{"extraPaths":[]}')
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)

    assert.is_true(workflow.activate(bufnr))

    assert.are.equal(1, #starts)
    assert.are.equal(0, #jobs)
    assert.are.equal(0, #patches)
    assert.are.equal('ready', statuses[#statuses].state)
  end)

  it('keeps Pyright stopped after initial generation failure', function()
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)
    assert.is_true(workflow.activate(bufnr))

    jobs[1].on_exit { code = 1, signal = 0, stdout = '', stderr = 'requested failure\n' }

    assert.are.equal(0, #starts)
    assert.are.equal(0, #restarts)
    assert.are.same({ 'ya_ide_failed' }, warnings)
    assert.are.equal('ya ide vscode failed: requested failure', statuses[#statuses].message)
  end)

  it('cancels refresh and prevents stale results from replacing new output', function()
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)
    assert.is_true(workflow.activate(bufnr))
    local old_job = jobs[1]
    local old_project = old_job.cmd[#old_job.cmd]:match '^%-P=(.+)$'

    assert.is_true(workflow.refresh(bufnr))
    local new_job = jobs[2]
    local new_project = complete(new_job, { '/new' })
    old_job.on_exit { code = 0, signal = 15, stdout = '', stderr = '', cancelled = true }

    assert.are.equal(0, vim.fn.isdirectory(old_project))
    assert.are.equal(1, vim.fn.isdirectory(new_project))
    assert.are.equal(1, #cancelled)
    assert.are.same({ '/new' }, assert(api.cache.read(root .. '/data/config.json')).extra_paths)
  end)

  it('refuses restart without project or cached configuration', function()
    local workflow = require 'arcadia-lspconfig.servers.pyright'(api)

    local ok, message = workflow.restart(bufnr)

    assert.is_nil(ok)
    assert.matches('no valid Pyright configuration', message)
    assert.are.equal(0, #restarts)
  end)
end)
