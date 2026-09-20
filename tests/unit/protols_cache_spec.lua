local helpers = require 'tests.helpers'

describe('Protols build-plan cache', function()
  local cache = require 'arcadia-lspconfig.servers.protols_cache'
  local root
  local data_dir

  before_each(function()
    root = helpers.tempdir()
    data_dir = root .. '/cache'
    vim.fn.mkdir(data_dir, 'p')
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  local function write_plan(path)
    helpers.write(
      path,
      vim.json.encode {
        graph = {
          {
            inputs = {
              '$(SOURCE_ROOT)/project/api/service.proto',
              '$(SOURCE_ROOT)/shared/types.proto',
              '$(BUILD_ROOT)/generated.proto',
            },
            cmds = {
              {
                cwd = '$(SOURCE_ROOT)',
                cmd_args = {
                  '$(BUILD_ROOT)/contrib/tools/protoc/protoc',
                  '-I=./project/api',
                  '-I=$(SOURCE_ROOT)/shared',
                  '-I=$(BUILD_ROOT)',
                  '--proto_path=$(SOURCE_ROOT)/shared',
                  '-I=$(TOOL_ROOT)/unknown',
                  '-I',
                  '$(SOURCE_ROOT)/separate',
                  '-I$(SOURCE_ROOT)/attached',
                  '--proto_path',
                  '$(SOURCE_ROOT)/long-separate',
                  '--',
                  '-I=$(SOURCE_ROOT)/ignored',
                },
              },
            },
          },
        },
      }
    )
  end

  it('extracts source roots and every covered source proto', function()
    local plan = root .. '/plan.json'
    write_plan(plan)

    local record = assert(cache.from_plan(plan, root, root .. '/project/api', 'raw.json', 10))

    assert.are.same({
      root .. '/project/api',
      root .. '/shared',
      root .. '/separate',
      root .. '/attached',
      root .. '/long-separate',
    }, record.include_paths)
    assert.are.same(
      { root .. '/project/api/service.proto', root .. '/shared/types.proto' },
      record.covered_files
    )
  end)

  it('rejects plans without usable protoc configuration', function()
    local plan = root .. '/plan.json'
    helpers.write(plan, '{"graph":[]}')

    local record, message = cache.from_plan(plan, root, root .. '/project', 'raw.json', 10)

    assert.is_nil(record)
    assert.are.equal('build plan contains no usable protoc source include paths', message)
  end)

  it('installs raw generations and selects exact then newest coverage', function()
    local first_plan = root .. '/first.json'
    write_plan(first_plan)
    local first =
      assert(cache.from_plan(first_plan, root, root .. '/project/api', 'unused.json', 10))
    local first_index = assert(cache.install(data_dir, first_plan, first, 'first'))
    assert.are.equal(1, #first_index.records)

    local second_plan = root .. '/second.json'
    write_plan(second_plan)
    local second = assert(cache.from_plan(second_plan, root, root .. '/other', 'unused.json', 20))
    local index = assert(cache.install(data_dir, second_plan, second, 'second'))
    local file = root .. '/shared/types.proto'

    assert.are.equal(
      root .. '/project/api',
      cache.select(index, file, root .. '/project/api').target_root
    )
    assert.are.equal(root .. '/other', cache.select(index, file, root .. '/unrelated').target_root)
    assert.are.equal(1, vim.fn.filereadable(data_dir .. '/' .. index.records[1].raw_plan))
    assert.are.equal(1, vim.fn.filereadable(data_dir .. '/' .. index.records[2].raw_plan))
  end)

  it('creates executable ya wrappers without changing directory', function()
    local bin_dir = assert(cache.ensure_wrappers(data_dir))
    local clang_format = table.concat(vim.fn.readfile(bin_dir .. '/clang-format'), '\n')
    local protoc = table.concat(vim.fn.readfile(bin_dir .. '/protoc'), '\n')
    local expected_protoc = '#!/bin/sh\nexec "$ARCADIA_LSPCONFIG_YA" run '
      .. '"$ARCADIA_LSPCONFIG_ROOT"/contrib/tools/protoc -- "$@"'

    assert.are.equal('#!/bin/sh\nexec "$ARCADIA_LSPCONFIG_YA" tool clang-format "$@"', clang_format)
    assert.are.equal(expected_protoc, protoc)
    assert.is_nil(protoc:match 'cd ')
    assert.are.equal('rwxr-xr-x', vim.fn.getfperm(bin_dir .. '/protoc'))
  end)
end)
