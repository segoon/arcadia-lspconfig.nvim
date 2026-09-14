local helpers = require 'tests.helpers'

describe('compile database cache', function()
  local root
  local cache

  before_each(function()
    root = helpers.tempdir()
    cache = require 'arcadia-lspconfig.cache'
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it('validates a JSON array', function()
    helpers.write(root .. '/database.json', '[{"file":"main.cpp"}]')
    assert.is_true(cache.is_valid(root .. '/database.json'))

    helpers.write(root .. '/object.json', '{"file":"main.cpp"}')
    assert.is_false(cache.is_valid(root .. '/object.json'))
  end)

  it('atomically installs changed valid output', function()
    helpers.write(root .. '/compile_commands.json', '[]')
    helpers.write(root .. '/temporary.json', '[{"file":"main.cpp"}]')

    local changed, err = cache.install(root .. '/temporary.json', root .. '/compile_commands.json')

    assert.is_nil(err)
    assert.is_true(changed)
    assert.are.same({ '[{"file":"main.cpp"}]' }, vim.fn.readfile(root .. '/compile_commands.json'))
    assert.are.equal(0, vim.fn.filereadable(root .. '/temporary.json'))
  end)

  it('keeps the old output when new JSON is invalid', function()
    helpers.write(root .. '/compile_commands.json', '[]')
    helpers.write(root .. '/temporary.json', 'not json')

    local changed, err = cache.install(root .. '/temporary.json', root .. '/compile_commands.json')

    assert.is_nil(changed)
    assert.matches('valid JSON array', err)
    assert.are.same({ '[]' }, vim.fn.readfile(root .. '/compile_commands.json'))
  end)

  it('does not replace identical output', function()
    helpers.write(root .. '/compile_commands.json', '[]')
    helpers.write(root .. '/temporary.json', '[]')

    local changed, err = cache.install(root .. '/temporary.json', root .. '/compile_commands.json')

    assert.is_nil(err)
    assert.is_false(changed)
    assert.are.equal(0, vim.fn.filereadable(root .. '/temporary.json'))
  end)
end)
