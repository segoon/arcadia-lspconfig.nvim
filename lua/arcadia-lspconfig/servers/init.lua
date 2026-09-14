---@param api table
---@return ArcadiaLspWorkflow
local function create_clangd(api)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.clangd_cache',
  })
  return require 'arcadia-lspconfig.servers.clangd'(dependencies)
end

---@param api table
---@return ArcadiaLspWorkflow
local function create_pyright(api)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.pyright_cache',
  })
  return require 'arcadia-lspconfig.servers.pyright'(dependencies)
end

---@type ArcadiaLspServerDefinition[]
return {
  {
    name = 'clangd',
    default_options = {},
    allowed_options = {},
    create = create_clangd,
  },
  {
    name = 'pyright',
    default_options = {},
    allowed_options = {},
    create = create_pyright,
  },
}
