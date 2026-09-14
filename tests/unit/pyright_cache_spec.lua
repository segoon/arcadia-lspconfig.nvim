local helpers = require 'tests.helpers'

describe('Pyright cache', function()
  local root
  local cache

  before_each(function()
    root = helpers.tempdir()
    cache = require 'arcadia-lspconfig.pyright_cache'
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it('extracts extra paths from a generated workspace', function()
    local project = root .. '/project'
    helpers.write(
      project .. '/arcadia-pyright.code-workspace',
      vim.json.encode {
        settings = { ['python.analysis.extraPaths'] = { '/arcadia', project .. '/.links/module' } },
      }
    )

    local value =
      assert(cache.from_workspace(project .. '/arcadia-pyright.code-workspace', project))

    assert.are.same({ '/arcadia', project .. '/.links/module' }, value.extra_paths)
    assert.are.equal(project, value.project_dir)
  end)

  it('atomically installs and validates a manifest', function()
    local project = root .. '/project'
    vim.fn.mkdir(project, 'p')
    local manifest = root .. '/config.json'

    assert.is_true(cache.install(manifest, {
      project_dir = project,
      extra_paths = { '/arcadia' },
    }, 1))

    assert.are.same({
      project_dir = project,
      extra_paths = { '/arcadia' },
    }, cache.read(manifest))
  end)

  it('rejects invalid workspaces and missing project directories', function()
    helpers.write(root .. '/workspace.json', '{}')
    local value, message = cache.from_workspace(root .. '/workspace.json', root .. '/project')
    assert.is_nil(value)
    assert.matches('extraPaths', message)

    helpers.write(
      root .. '/config.json',
      vim.json.encode {
        project_dir = root .. '/missing',
        extra_paths = {},
      }
    )
    value, message = cache.read(root .. '/config.json')
    assert.is_nil(value)
    assert.matches('does not exist', message)
  end)
end)
