local M = {}

local levels = { debug = 1, info = 2, warn = 3, error = 4, off = 5 }
local configured_level = levels.warn

---@param level string
function M.configure(level)
  configured_level = levels[level] or levels.warn
end

---@param level string
---@param message string
function M.write(level, message)
  if (levels[level] or levels.info) < configured_level then
    return
  end
  local path = vim.fs.joinpath(vim.fn.stdpath 'state', 'arcadia-lspconfig.log')
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local line = ('%s [%s] %s'):format(os.date '!%Y-%m-%dT%H:%M:%SZ', level:upper(), message)
  vim.fn.writefile({ line }, path, 'a')
end

---@param message string
function M.debug(message)
  M.write('debug', message)
end

---@param message string
function M.warn(message)
  M.write('warn', message)
end

return M
