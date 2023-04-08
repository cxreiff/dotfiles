
local lazy_config = require('setup/lazy_config')

require('lazy').setup({
  'tpope/vim-surround',
  'tpope/vim-vinegar',
  'tpope/vim-fugitive',
  'tpope/vim-commentary',
  'tpope/vim-sleuth',
  'fedepujol/move.nvim',
  'christoomey/vim-tmux-navigator',
  'famiu/bufdelete.nvim',

  'github/copilot.vim',

  { 'folke/which-key.nvim', config = require('setup/which_key') },
  { 'phaazon/hop.nvim', branch = 'v2', cmd = 'HopWord', config = true },
  { 'windwp/nvim-autopairs', config = true },
  { 'j-hui/fidget.nvim', config = true, event = 'VeryLazy' },
  { 'nvim-lualine/lualine.nvim', config = require('setup/lualine') },
  { 'akinsho/bufferline.nvim', version = 'v3.*', config = require('setup/bufferline') },
  { 'akinsho/toggleterm.nvim', version = "*", config = true },
  { 'aznhe21/actions-preview.nvim', config = require('setup/actions_preview') },
  { 'kevinhwang91/nvim-bqf', ft = 'qf', config = require('setup/nvim_bqf') },
  { 'Pocco81/true-zen.nvim', config = require('setup/true_zen') },
  { 'NvChad/nvim-colorizer.lua', event = 'BufEnter', config = true },
  { 'lewis6991/gitsigns.nvim', event = 'BufEnter', config = true },
  { 'nmac427/guess-indent.nvim', cmd = 'GuessIndent', config = true },
  {
    'nvim-treesitter/nvim-treesitter',
    event = 'VeryLazy',
    build = ':TSUpdate',
    config = require('setup/nvim_treesitter'),
  },
  {
    'nvim-telescope/telescope.nvim',
    version = '0.1.0',
    event = 'VeryLazy',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-ui-select.nvim',
      'tknightz/telescope-termfinder.nvim',
      { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
    },
    config = require('setup/telescope'),
  },
  {
    'VonHeikemen/lsp-zero.nvim',
    event = 'VeryLazy',
    dependencies = {
      -- lsp support
      'neovim/nvim-lspconfig',
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',

      -- autocompletion
      'hrsh7th/nvim-cmp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-nvim-lua',
      'saadparwaiz1/cmp_luasnip',

      -- snippets
      'L3MON4D3/LuaSnip',
      'rafamadriz/friendly-snippets',

      -- dap
      'mfussenegger/nvim-dap',
      'jay-babu/mason-nvim-dap.nvim',

      -- null_ls
      'jay-babu/mason-null-ls.nvim',
      'jose-elias-alvarez/null-ls.nvim',
    },
    config = require('setup/lsp_zero'),
  },

  -- languages
  { 'rust-lang/rust.vim', ft = 'rust' },

  -- color schemes
  'fenetikm/falcon',
  'sainnhe/everforest',
  'w0ng/vim-hybrid',
  'AlessandroYorba/Alduin',
  'AlessandroYorba/Sierra',
  'frenzyexists/aquarium-vim',
  'kvrohit/rasmus.nvim',
  'bcicen/vim-vice',
  'rafamadriz/neon',
  'sainnhe/sonokai',
  'savq/melange',
  'shaunsingh/nord.nvim',
  'kdheepak/monochrome.nvim',
  'rose-pine/neovim',
  'yazeed1s/oh-lucy.nvim',
  'EdenEast/nightfox.nvim',
  'catppuccin/nvim',
  { 'ramojus/mellifluous.nvim', dependencies = { 'rktjmp/lush.nvim' } },
}, lazy_config)

