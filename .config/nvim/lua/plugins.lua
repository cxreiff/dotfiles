-- install packer if not yet installed
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
  if fn.empty(fn.glob(install_path)) > 0 then
    fn.system({'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path})
    vim.cmd [[packadd packer.nvim]]
    return true
  end
  return false
end
local packer_bootstrap = ensure_packer()

-- recompile when this file is changed
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerCompile
  augroup end
]])

return require('packer').startup(function(use)
	use 'wbthomason/packer.nvim'

  use 'lewis6991/impatient.nvim'

  use {
    'nvim-lualine/lualine.nvim',
    config = function()
      require('lualine').setup {
        options = {
          icons_enabled = false,
          component_separators = { left = '|', right = '|'},
          section_separators = { left = '', right = ''},
        }
      }
    end
  }

  use 'tpope/vim-surround'
  use 'tpope/vim-fugitive'
  use 'tpope/vim-vinegar'
  use 'tpope/vim-commentary'
  use 'numToStr/FTerm.nvim'

  -- zen mode
  use {
	  'Pocco81/true-zen.nvim',
	  config = function()
		  require('true-zen').setup {
        integrations = {
          lualine = true
        }
      }
    end
  }

  -- highlight todo comments
  use {
    'folke/todo-comments.nvim',
    requires = 'nvim-lua/plenary.nvim',
    config = function()
      require('todo-comments').setup {}
    end
  }
  
  -- fuzzy finder
  use {
    'nvim-telescope/telescope.nvim', tag = '0.1.0',
    requires = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' }
    },
    config = function()
      require('telescope').load_extension('fzf')
    end,
  }
  
  -- treesitter
  use {
    'nvim-treesitter/nvim-treesitter',
    run = function()
        local ts_update = require('nvim-treesitter.install').update({ with_sync = true })
        ts_update()
    end,
    config = function()
      require('nvim-treesitter.configs').setup {
        ensure_installed = { "lua", "rust", "toml" },
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting=false,
        },
        ident = { enable = true }, 
        rainbow = {
          enable = true,
          extended_mode = true,
          max_file_lines = nil,
        }
      }
    end,
  }
  
	-- lsp setup
  use 'neovim/nvim-lspconfig'
  
  use {
    'williamboman/mason.nvim',
    config = function()
      require('mason').setup {}
    end,
  }
  
  use {
    'williamboman/mason-lspconfig.nvim',
    config = function()
      require('mason-lspconfig').setup {
          ensure_installed = { 'rust_analyzer' }
      }
    end
  }
  
  use {
    'hrsh7th/nvim-cmp',
    config = function()
      local cmp = require('cmp')
      cmp.setup({
        completion = {
          autocomplete = false,
        },
        snippet = {
          expand = function(args)
              vim.fn["vsnip#anonymous"](args.body)
          end,
        },
        mapping = {
          ['<C-p>'] = cmp.mapping.select_prev_item(),
          ['<C-n>'] = cmp.mapping.select_next_item(),
          ['<S-Tab>'] = cmp.mapping.select_prev_item(),
          ['<Tab>'] = cmp.mapping.select_next_item(),
          ['<C-S-f>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-Space>'] = cmp.mapping.complete(),
          ['<C-e>'] = cmp.mapping.close(),
          ['<CR>'] = cmp.mapping.confirm({
            behavior = cmp.ConfirmBehavior.Insert,
            select = true,
          })
        },
        -- Installed sources:
        sources = {
          { name = 'path' },                              -- file paths
          { name = 'nvim_lsp', keyword_length = 3 },      -- from language server
          { name = 'nvim_lsp_signature_help'},            -- display function signatures with current parameter emphasized
          { name = 'nvim_lua', keyword_length = 2},       -- complete neovim's Lua runtime API such vim.lsp.*
          { name = 'buffer', keyword_length = 2 },        -- source current buffer
          { name = 'vsnip', keyword_length = 2 },         -- nvim-cmp source for vim-vsnip 
          { name = 'calc'},                               -- source for math calculation
        },
        window = {
            completion = cmp.config.window.bordered(),
            documentation = cmp.config.window.bordered(),
        },
        formatting = {
            fields = {'menu', 'abbr', 'kind'},
            format = function(entry, item)
                local menu_icon ={
                    nvim_lsp = 'λ',
                    vsnip = '⋗',
                    buffer = 'Ω',
                    path = '/',
                }
                item.menu = menu_icon[entry.source.name]
                return item
            end,
        },
      })
    end
  }
  use 'hrsh7th/cmp-nvim-lsp'
  use 'hrsh7th/cmp-nvim-lua'
  use 'hrsh7th/cmp-nvim-lsp-signature-help'
  use 'hrsh7th/cmp-vsnip'                             
  use 'hrsh7th/cmp-path'                              
  use 'hrsh7th/cmp-buffer'                            
  use 'hrsh7th/vim-vsnip'
  use {
    'folke/trouble.nvim',
    config = function()
      require('trouble').setup {
        icons = false,
        fold_open = "v",
        fold_closed = ">",
        indent_lines = false,
        use_diagnostic_signs = true,
      }
    end
  }

  -- languages
  use 'rust-lang/rust.vim'
  
  use {
    'simrat39/rust-tools.nvim',
    config = function()
      local rt = require('rust-tools')
      rt.setup {
        server = {
          on_attach = function(_, bufnr)
            vim.keymap.set("n", "<C-space>", rt.hover_actions.hover_actions, { buffer = bufnr })
            vim.g.rust_hints_enabled = false
            function RustToggleInlayHints()
              if (vim.g.rust_hints_enabled) then
                require('rust-tools').inlay_hints.disable()
                vim.g.rust_hints_enabled = false
              else
                require('rust-tools').inlay_hints.enable()
                vim.g.rust_hints_enabled = true
              end
            end
            vim.api.nvim_create_user_command('RustToggleInlayHints', RustToggleInlayHints, { bang = true })
            vim.keymap.set({'n', 'v'}, '<leader>u', ':RustToggleInlayHints<CR>', { noremap = true })
          end,
        },
        tools = {
          inlay_hints = {
            auto = false,
          }
        }
      }
    end
  }
	
	-- color schemes
	use 'sainnhe/everforest'
	use 'w0ng/vim-hybrid'
	use 'AlessandroYorba/Alduin'
	use 'AlessandroYorba/Sierra'
  use 'frenzyexists/aquarium-vim'
  use 'kvrohit/rasmus.nvim'

	-- packer setup
	if packer_bootstrap then
    require('packer').sync()
  end
end)

