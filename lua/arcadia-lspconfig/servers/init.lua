---@param api table
---@return ArcadiaLspWorkflow
local function create_clangd(api)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.clangd_cache',
  })
  return require 'arcadia-lspconfig.servers.clangd'(dependencies)
end

---@param api table
---@param server string
---@param display_name string
---@return ArcadiaLspWorkflow
local function create_python_server(api, server, display_name)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.pyright_cache',
  })
  return require 'arcadia-lspconfig.servers.pyright'(dependencies, server, display_name)
end

---@param api table
---@return ArcadiaLspWorkflow
local function create_pyright(api)
  return create_python_server(api, 'pyright', 'Pyright')
end

---@param api table
---@return ArcadiaLspWorkflow
local function create_basedpyright(api)
  return create_python_server(api, 'basedpyright', 'BasedPyright')
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
    conflicts = { 'basedpyright' },
    create = create_pyright,
  },
  {
    name = 'basedpyright',
    default_options = false,
    allowed_options = {},
    conflicts = { 'pyright' },
    create = create_basedpyright,
  },
}
