local M = {}

---@type table<string, boolean>
local emitted = {}

---@param lsp_root string
---@param server string
---@param code string
---@param message string
function M.warn_once(lsp_root, server, code, message)
  local key = table.concat({ lsp_root, server, code }, '\0')
  if emitted[key] then
    return
  end
  emitted[key] = true
  require('arcadia-lspconfig.log').warn(('%s [%s/%s]'):format(message, server, lsp_root))
  vim.schedule(function()
    vim.notify(message, vim.log.levels.WARN, { title = 'arcadia-lspconfig.nvim' })
  end)
end

function M.clear()
  emitted = {}
end

return M
