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

-- install plugins
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

  use {
    'windwp/nvim-autopairs',
    config = function()
      require('nvim-autopairs').setup {}
    end,
  }

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
        ensure_installed = { "rust", "toml" },
        auto_install = true,
        highlight = {
          disable = { "lua" },
        },
        rainbow = {
          enable = true,
          extended_mode = true,
          max_file_lines = nil,
        }
      }
    end,
  }
  
	-- lsp setup
  use {
    'VonHeikemen/lsp-zero.nvim',
    requires = {
      -- LSP Support
      {'neovim/nvim-lspconfig'},
      {'williamboman/mason.nvim'},
      {'williamboman/mason-lspconfig.nvim'},

      -- Autocompletion
      {'hrsh7th/nvim-cmp'},
      {'hrsh7th/cmp-buffer'},
      {'hrsh7th/cmp-path'},
      {'saadparwaiz1/cmp_luasnip'},
      {'hrsh7th/cmp-nvim-lsp'},
      {'hrsh7th/cmp-nvim-lua'},

      -- Snippets
      {'L3MON4D3/LuaSnip'},
      {'rafamadriz/friendly-snippets'},
    },
    config = function()
      local lsp = require('lsp-zero')
      lsp.preset('recommended')
      lsp.setup_nvim_cmp({
        completion = { autocomplete = false }
      })
      lsp.setup()
    end,
  }

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
  use 'bcicen/vim-vice'

  -- packer setup
  if packer_bootstrap then
    require('packer').sync()
  end
end)

