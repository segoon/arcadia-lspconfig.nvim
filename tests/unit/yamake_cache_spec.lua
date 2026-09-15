local helpers = require 'tests.helpers'

describe('ya-make-lsp cache', function()
  local root
  local cache

  before_each(function()
    root = helpers.tempdir()
    cache = require 'arcadia-lspconfig.servers.yamake_cache'
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it('validates installed scripts and full revisions', function()
    assert.is_false(cache.is_valid(root))
    assert.is_nil(cache.revision(root))
    helpers.write(root .. '/out/ya-make-lsp.js')
    helpers.write(root .. '/.arcadia-revision', string.rep('a', 40))
    assert.is_true(cache.is_valid(root))
    assert.are.equal(string.rep('a', 40), cache.revision(root))

    helpers.write(root .. '/.arcadia-revision', 'short')
    assert.is_false(cache.is_valid(root))
    assert.is_nil(cache.revision(root))
    assert.is_nil(cache.revision(root))
  end)

  it('parses the bounded arc log output', function()
    local revision = string.rep('b', 40)
    assert.are.equal(revision, cache.parse_revision(revision .. ' change title\n'))
    assert.is_nil(cache.parse_revision 'short change title\n')
    assert.is_nil(cache.parse_revision '')
  end)

  it('publishes a prepared export and rolls back failed replacements', function()
    local destination = root .. '/ya-make-lsp'
    helpers.write(destination .. '/out/ya-make-lsp.js', 'old')
    helpers.write(destination .. '/.arcadia-revision', string.rep('c', 40))

    local transaction = assert(cache.prepare(destination, 1))
    assert.is_nil(vim.uv.fs_stat(destination))
    helpers.write(destination .. '/out/ya-make-lsp.js', 'new')
    assert.is_true(cache.commit(transaction, string.rep('d', 40)))
    assert.are.equal('new', vim.fn.readfile(destination .. '/out/ya-make-lsp.js')[1])
    assert.are.equal(string.rep('d', 40), cache.revision(destination))
    assert.is_nil(vim.uv.fs_stat(transaction.backup))

    transaction = assert(cache.prepare(destination, 2))
    helpers.write(destination .. '/partial', 'broken')
    assert.is_true(cache.rollback(transaction))
    assert.are.equal('new', vim.fn.readfile(destination .. '/out/ya-make-lsp.js')[1])
    assert.are.equal(string.rep('d', 40), cache.revision(destination))
  end)

  it('refuses to publish an export without the server script', function()
    local destination = root .. '/ya-make-lsp'
    local transaction = assert(cache.prepare(destination, 1))
    helpers.write(destination .. '/package.json', '{}')

    local ok, message = cache.commit(transaction, string.rep('e', 40))

    assert.is_nil(ok)
    assert.matches('ya%-make%-lsp.js', message)
    assert.is_true(cache.rollback(transaction))
  end)
end)
