return function(use)
  use {
    'VonHeikemen/lsp-zero.nvim',
    requires = {
      -- LSP Support
      'neovim/nvim-lspconfig',
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',

      -- Autocompletion
      'hrsh7th/nvim-cmp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'saadparwaiz1/cmp_luasnip',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-nvim-lua',

      -- Snippets
      'L3MON4D3/LuaSnip',
      'rafamadriz/friendly-snippets',

      -- Languages
      'simrat39/rust-tools.nvim',
    },
    config = function()
      local lsp = require('lsp-zero')
      lsp.preset('recommended')

      local cmp = require('cmp')
      -- local luasnip = require('luasnip')
      local cmp_mappings = lsp.defaults.cmp_mappings({
        ['<C-Space>'] = cmp.mapping.complete(),
        ['<C-e>'] = cmp.mapping.abort(),

        -- ['<Tab>'] = cmp.mapping(function(fallback)
        --   if cmp.visible() then
        --     cmp.select_next_item()
        --   elseif luasnip.expand_or_jumpable() then
        --     luasnip.expand_or_jump()
        --   else
        --     fallback()
        --   end
        -- end, { 'i', 's' }),

        -- ['<S-Tab>'] = cmp.mapping(function(fallback)
        --   if cmp.visible() then
        --     cmp.select_prev_item()
        --   elseif luasnip.jumpable(-1) then
        --     luasnip.jump(-1)
        --   else
        --     fallback()
        --   end
        -- end, { 'i', 's' }),
      })

      lsp.setup_nvim_cmp({
        mapping = cmp_mappings,
        completion = { autocomplete = false }
      })

      local rust_tools = require('rust-tools')
      local rust_lsp = lsp.build_options('rust_analyzer', {
        on_attach = function(_, bufnr)
          vim.keymap.set("n", "<C-space>", rust_tools.hover_actions.hover_actions, { buffer = bufnr })
          vim.g.rust_hints_enabled = false
            function RustToggleInlayHints()
              if (vim.g.rust_hints_enabled) then
                rust_tools.inlay_hints.disable()
                vim.g.rust_hints_enabled = false
              else
                rust_tools.inlay_hints.enable()
                vim.g.rust_hints_enabled = true
              end
            end
            vim.api.nvim_create_user_command('RustToggleInlayHints', RustToggleInlayHints, { bang = true })
            vim.keymap.set({'n', 'v'}, '<leader>u', ':RustToggleInlayHints<CR>', { noremap = true })
        end,
      })

      lsp.nvim_workspace()

      lsp.setup()

      rust_tools.setup({
        server = rust_lsp,
        tools = {
          inlay_hints = {
            auto = false,
            parameter_hints_prefix = "<- ",
            other_hints_prefix = "--> ",
            max_len_align = true,
          }
        },
      })
    end,
  }
end
