local lazy_config = require('setup/lazy_config')

require('lazy').setup({
  'tpope/vim-surround',
  'tpope/vim-fugitive',
  'tpope/vim-commentary',
  'christoomey/vim-tmux-navigator',
  'famiu/bufdelete.nvim',

  { 'fedepujol/move.nvim', config = true },
  { 'folke/which-key.nvim', event = 'VeryLazy', config = require('setup/which_key') },
  { 'phaazon/hop.nvim', branch = 'v2', cmd = 'HopWord', config = true },
  { 'windwp/nvim-autopairs', config = true },
  { 'AckslD/nvim-trevJ.lua', config = true },
  { 'j-hui/fidget.nvim', tag = 'legacy', config = true, event = 'VeryLazy' },
  { 'nvim-lualine/lualine.nvim', config = require('setup/lualine') },
  { 'akinsho/bufferline.nvim', version = 'v3.*', config = require('setup/bufferline') },
  { 'akinsho/toggleterm.nvim', version = "*", config = true },
  { 'aznhe21/actions-preview.nvim', config = require('setup/actions_preview') },
  { 'kevinhwang91/nvim-bqf', ft = 'qf', config = require('setup/nvim_bqf') },
  { 'Pocco81/true-zen.nvim', config = require('setup/true_zen') },
  { 'NvChad/nvim-colorizer.lua', event = 'BufEnter', config = require('setup/nvim_colorizer') },
  { 'lewis6991/gitsigns.nvim', event = 'BufEnter', config = true },
  { 'nmac427/guess-indent.nvim', config = true },
  { 'petertriho/nvim-scrollbar', config = require('setup/nvim_scrollbar') },
  {
    'stevearc/oil.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = require('setup/oil')
  },
  {
    'nvim-treesitter/nvim-treesitter',
    event = 'VeryLazy',
    build = ':TSUpdate',
    config = require('setup/nvim_treesitter'),
  },
  {
    'nvim-telescope/telescope.nvim',
    version = '0.1.4',
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
    branch = 'v3.x',
    event = 'VeryLazy',
    dependencies = {
      -- lsp support
      'neovim/nvim-lspconfig',
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',

      -- autocompletion
      'hrsh7th/nvim-cmp',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-path',
      'saadparwaiz1/cmp_luasnip',

      -- snippets
      'L3MON4D3/LuaSnip',

      -- null_ls
      -- 'jay-babu/mason-null-ls.nvim',
      -- 'nvimtools/none-ls.nvim',

      -- copilot
      -- { 'zbirenbaum/copilot-cmp', cmd = 'Copilot' },
      -- { 'zbirenbaum/copilot.lua', cmd = 'Copilot' },
    },
    config = require('setup/lsp_zero'),
  },

  -- leetcode
  {
    "kawre/leetcode.nvim",
    build = ":TSUpdate html",
    lazy = "leet" ~= vim.fn.argv()[1],
    dependencies = {
      "nvim-telescope/telescope.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons",
    },
    opts = require('setup/leetcode'),
  },

  -- languages
  { 'rust-lang/rust.vim', ft = 'rust' },
  { 'kaarmu/typst.vim', ft = 'typst' },
  {
    'tikhomirov/vim-glsl',
    ft = {
      'glsl',
      'vert',
      'frag',
      'geom',
      'comp',
      'tesc',
      'tese',
    },
  },

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
