local root = require 'arcadia-lspconfig.root'

---@type ArcadiaLspServerDefinition
return {
  name = 'infractl',
  default_options = {},
  allowed_options = {},
  auto_enable = true,
  filetype = { extension = { star = 'starlark' } },
  config = { filetypes = { 'starlark', 'yaml' }, workspace_required = true },

  ---@param bufnr integer
  ---@return table?
  context = function(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    local name = vim.fs.basename(path)
    if not (name:match '%.star$' or name == 'i.yaml' or name:match '^i%..*%.yaml$') then
      return nil
    end
    local roots = root.find(path)
    if not roots.arcadia_root then
      return nil
    end
    local marker = vim.fs.find({ 'a.yaml', '.arcadia.root' }, {
      path = vim.fs.dirname(path),
      upward = true,
      stop = vim.fs.dirname(roots.arcadia_root),
    })[1]
    if marker then
      return {
        bufnr = bufnr,
        arcadia_root = roots.arcadia_root,
        lsp_root = vim.fs.dirname(marker),
      }
    end
  end,

  ---@param lsp_root string
  ---@return string[]
  command = function(lsp_root)
    local arcadia_root = assert(root.find(vim.fs.joinpath(lsp_root, 'a.yaml')).arcadia_root)
    return { vim.fs.joinpath(arcadia_root, 'ya'), 'tool', 'infractl', 'lsp' }
  end,
}
