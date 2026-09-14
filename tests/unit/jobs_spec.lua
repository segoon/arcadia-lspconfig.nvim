describe('shared jobs', function()
  local jobs
  local callbacks
  local killed

  before_each(function()
    jobs = require 'arcadia-lspconfig.jobs'
    jobs._reset()
    callbacks = {}
    killed = 0
    jobs._set_system(function(_, _, callback)
      callbacks[#callbacks + 1] = callback
      return {
        kill = function()
          killed = killed + 1
        end,
      }
    end)
    jobs.setup { cancel_on_buff_exit = true, timeout_ms = nil }
  end)

  after_each(function()
    jobs._reset()
  end)

  it('shares a job and tracks all interested buffers', function()
    local first = jobs.start('root\0clangd', {
      cmd = { 'fake' },
      cwd = '/tmp',
      bufnr = 1,
      on_exit = function() end,
    })
    local second = jobs.start('root\0clangd', {
      cmd = { 'ignored' },
      cwd = '/tmp',
      bufnr = 2,
      on_exit = function() end,
    })

    assert.are.equal(first, second)
    assert.is_true(first.interested[1])
    assert.is_true(first.interested[2])
    assert.are.equal(1, #callbacks)
  end)

  it('cancels only after the last interested buffer exits', function()
    jobs.start('root\0clangd', {
      cmd = { 'fake' },
      cwd = '/tmp',
      bufnr = 1,
      on_exit = function() end,
    })
    jobs.add_interest('root\0clangd', 2)

    jobs.drop_buffer(1)
    assert.are.equal(0, killed)
    jobs.drop_buffer(2)
    assert.are.equal(1, killed)
    assert.is_nil(jobs.get 'root\0clangd')
  end)
end)
