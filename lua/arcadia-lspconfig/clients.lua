local M = {}

---@param root_a string?
---@param root_b string?
---@return boolean
local function same_root(root_a, root_b)
  return root_a ~= nil and root_b ~= nil and vim.fs.normalize(root_a) == vim.fs.normalize(root_b)
end

---@param lsp_root string
---@param server string
---@return vim.lsp.Client[]
function M.get(lsp_root, server)
  return vim.tbl_filter(function(client)
    return same_root(client.root_dir, lsp_root)
  end, vim.lsp.get_clients { name = server, _uninitialized = true })
end

---@param bufnr integer
---@param server string
---@param expected_root string
function M.detach_wrong_root(bufnr, server, expected_root)
  for _, client in
    ipairs(vim.lsp.get_clients { bufnr = bufnr, name = server, _uninitialized = true })
  do
    if not same_root(client.root_dir, expected_root) then
      vim.lsp.buf_detach_client(bufnr, client.id)
    end
  end
end

---@param lsp_root string
---@param server string
---@param buffers integer[]
---@return integer?
function M.start(lsp_root, server, buffers)
  local config = require('arcadia-lspconfig.config').resolve(lsp_root, server)
  local client_id
  table.sort(buffers)
  for _, bufnr in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      client_id = vim.lsp.start(config, {
        bufnr = bufnr,
        reuse_client = function(client)
          return client.name == server
            and not client:is_stopped()
            and same_root(client.root_dir, lsp_root)
        end,
      }) or client_id
    end
  end
  return client_id
end

---@param lsp_root string
---@param server string
---@param extra_buffers? integer[]
function M.restart(lsp_root, server, extra_buffers)
  local buffers = {}
  for _, bufnr in ipairs(extra_buffers or {}) do
    buffers[bufnr] = true
  end

  local clients = M.get(lsp_root, server)
  for _, client in ipairs(clients) do
    for bufnr in pairs(client.attached_buffers) do
      buffers[bufnr] = true
    end
    client:stop(true)
  end

  vim.schedule(function()
    M.start(lsp_root, server, vim.tbl_keys(buffers))
  end)
end

return M
