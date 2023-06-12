return function()
  local lsp = require('lsp-zero').preset('recommended')
  local lspconfig = require('lspconfig')
  local cmp = require('cmp')
  local luasnip = require('luasnip')

  lsp.on_attach(function(_, bufnr)
    lsp.default_keymaps({ buffer = bufnr })
    local opts = { noremap = true, silent = true }
    vim.keymap.set('n', '<C-Space>', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gp', vim.diagnostic.setloclist, opts)
    vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', 'gl', function()
      vim.diagnostic.open_float(0, { alwaysSource = true })
    end, opts)
    vim.keymap.set('n', 'gr', function()
      vim.lsp.buf.references { includeDeclaration = false }
    end, opts)
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
  lspconfig.tsserver.setup {
    handlers = {
      ['textDocument/definition'] = function(err, result, method, ...)
        if vim.tbl_islist(result) and #result > 1 then
          local filtered_result = filter(result, filterReactDTS)
          return vim.lsp.handlers['textDocument/definition'](err, filtered_result, method, ...)
        end
        vim.lsp.handlers['textDocument/definition'](err, result, method, ...)
      end
    }
  }

  lspconfig.lua_ls.setup(lsp.nvim_lua_ls())

  lsp.setup()

  vim.diagnostic.config({
    virtual_text = false,
    float = {
      source = 'always',
      header = {},
      padding = true,
      pad_top = 1,
      pad_bottom = 1,
    },
  })

  -- require('copilot').setup({
  --   suggestion = {
  --     enabled = true,
  --     auto_trigger = false,
  --     keymap = {
  --       accept = '<C-Tab>',
  --       dismiss = '<C-Esc>',
  --     },
  --   },
  --   panel = { enabled = false },
  -- })
  -- require('copilot_cmp').setup()

  -- vim.keymap.set(
  --   'n',
  --   '<leader>l',
  --   function()
  --     if vim.b.copilot_suggestion_auto_trigger then
  --       print('Copilot disabled')
  --     else
  --       print('Copilot enabled')
  --     end
  --     require('copilot.suggestion').toggle_auto_trigger()
  --   end,
  --   { noremap = true }
  -- )

  cmp.setup {
    preselect = cmp.PreselectMode.Item,
    completion = {
      autocomplete = false,
      completeopt = 'menu,menuone,noinsert',
    },
    mapping = {
      ['<C-Tab>'] = cmp.mapping(function(fallback)
        if luasnip.expand_or_locally_jumpable() then
          luasnip.expand_or_jump()
        else
          fallback()
        end
      end, { 'i', 's' }),

      ['<CR>'] = cmp.mapping.confirm({
        behavior = cmp.ConfirmBehavior.Replace,
        select = false,
      }),

      ['<Esc>'] = cmp.mapping(
        function(fallback)
          if cmp.visible() then
            cmp.abort()
            cmp.core:reset()
          else
            fallback()
          end
        end,
        { 'i', 's' }
      ),

      ['<C-Space>'] = cmp.mapping.complete(),
    },
    sources = {
      { name = 'path',     group_index = 1 },
      { name = 'nvim_lsp', group_index = 1 },
      -- uncomment and disable copilot suggestions for copilot in cmp
      -- { name = 'copilot', group_index = 1 },
      { name = 'luasnip',  keyword_length = 2, group_index = 2 },
      { name = 'buffer',   keyword_length = 3, group_index = 3 },
    },
    experimental = {
      ghost_text = true,
    },
  }

  cmp.event:on('menu_opened', function()
    vim.g.copilot_suggestion_hidden = true
    require('copilot.suggestion').dismiss()
  end)

  cmp.event:on('menu_closed', function()
    vim.g.copilot_suggestion_hidden = false
  end)

  require('null-ls').setup()
  require('mason-null-ls').setup({
    handlers = {},
  })
  require('mason-nvim-dap').setup({
    handlers = {},
  })
end
