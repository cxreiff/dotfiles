return function()
  local lsp = require('lsp-zero')
  local lspconfig = require('lspconfig')
  lsp.preset('recommended')

  local cmp = require('cmp')
  local cmp_mappings = lsp.defaults.cmp_mappings({
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.abort(),
  })

  lsp.setup_nvim_cmp({
    mapping = cmp_mappings,
    completion = { autocomplete = false }
  })

  lsp.on_attach(function(_, bufnr)
    lsp.default_keymaps({buffer = bufnr})
    local opts = { noremap = true, silent = true }
    vim.keymap.set('n', '<C-Space>', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gl', vim.diagnostic.open_float, opts)
    vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', 'gp', vim.diagnostic.setloclist, opts)
  end)

  lspconfig.rust_analyzer.setup {
    settings = {
      ['rust-analyzer'] = {
        procMacro = {
          enable = true,
        },
        checkOnSave = {
          command = 'clippy',
        },
        diagnostics = {
          enabled = true,
          disabled = { "unresolved-proc-macro" },
          enableExperimental = true,
          warningsAsHint = {},
        },
      },
    },
  }

  -- filtering out *.d.ts files from jump-to-definition
  local function filter(arr, fn)
    if type(arr) ~= 'table' then
      return arr
    end
    local filtered = {}
    for k, v in pairs(arr) do
      if fn(v, k, arr) then
        table.insert(filtered, v)
      end
    end
    return filtered
  end
  local function filterReactDTS(value)
    return string.match(value.targetUri, '%.d.ts') == nil
  end
  lsp.configure('tsserver', {
    handlers = {
      ['textDocument/definition'] = function(err, result, method, ...)
        if vim.tbl_islist(result) and #result > 1 then
          local filtered_result = filter(result, filterReactDTS)
          return vim.lsp.handlers['textDocument/definition'](err, filtered_result, method, ...)
        end
        vim.lsp.handlers['textDocument/definition'](err, result, method, ...)
      end
    }
  })

  lsp.nvim_workspace()
  lsp.setup()

  require('null-ls').setup()
  require('mason-null-ls').setup({
    ensure_installed = nil,
    automatic_installation = false,
    automatic_setup = true,
  })
  require('mason-null-ls').setup_handlers()
  require('mason-nvim-dap').setup({
    automatic_setup = true,
  })
  require('mason-nvim-dap').setup_handlers()
end

