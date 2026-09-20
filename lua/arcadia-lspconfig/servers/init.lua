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

---@param api table
---@return ArcadiaLspWorkflow
local function create_ty(api)
  return require 'arcadia-lspconfig.servers.ty'(api)
end

---@param api table
---@return ArcadiaLspWorkflow
local function create_protols(api)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.protols_cache',
  })
  return require 'arcadia-lspconfig.servers.protols'(dependencies)
end

---@param executable string
---@return boolean
local function is_executable(executable)
  return vim.fn.executable(executable) == 1
end

---@param api table
---@return ArcadiaLspWorkflow
local function create_yamake(api)
  local dependencies = vim.tbl_extend('force', {}, api, {
    cache = require 'arcadia-lspconfig.servers.yamake_cache',
    is_executable = is_executable,
  })
  return require 'arcadia-lspconfig.servers.yamake'(dependencies)
end

---@type ArcadiaLspServerDefinition[]
return {
  {
    name = 'clangd',
    default_options = { codegen = true },
    allowed_options = { codegen = 'boolean' },
    create = create_clangd,
  },
  {
    name = 'pyright',
    default_options = { codegen = true },
    allowed_options = { codegen = 'boolean' },
    create = create_pyright,
  },
  {
    name = 'basedpyright',
    default_options = { codegen = true },
    allowed_options = { codegen = 'boolean' },
    create = create_basedpyright,
  },
  {
    name = 'ty',
    default_options = {},
    allowed_options = {},
    route_commands = false,
    create = create_ty,
  },
  {
    name = 'protols',
    default_options = {},
    allowed_options = {},
    create = create_protols,
  },
  {
    name = 'ya-make-lsp',
    default_options = {},
    allowed_options = {},
    auto_enable = true,
    config = {
      cmd = { 'node', 'ya-make-lsp.js', '--stdio' },
      filetypes = { 'yamake' },
    },
    create = create_yamake,
  },
}
