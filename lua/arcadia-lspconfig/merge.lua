local M = {}

---@param value any
---@return boolean
local function is_list(value)
  return type(value) == 'table' and vim.islist(value) and next(value) ~= nil
end

---@param base any
---@param patch any
---@return any
local function merge(base, patch)
  if type(patch) ~= 'table' then
    return vim.deepcopy(patch)
  end
  if type(base) ~= 'table' or is_list(base) or is_list(patch) then
    return vim.deepcopy(patch)
  end

  local result = vim.deepcopy(base)
  for key, value in pairs(patch) do
    result[key] = merge(result[key], value)
  end
  return result
end

---@param base table
---@param patch table
---@return table
function M.apply(base, patch)
  return merge(base, patch)
end

return M
