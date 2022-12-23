
local packer_bootstrap = require('setup/packer_bootstrap')()

-- install plugins
local packer = require('packer')
packer.startup(function(use)
  use 'wbthomason/packer.nvim'
  use 'lewis6991/impatient.nvim'

  use { 'dstein64/vim-startuptime', cmd = 'StartupTime' }

  use 'tpope/vim-surround'
  use 'tpope/vim-fugitive'
  use 'tpope/vim-vinegar'
  use 'tpope/vim-commentary'
  use 'sickill/vim-pasta'

  require('setup/lualine')(use)
  require('setup/nvim_autopairs')(use)
  require('setup/lsp_zero')(use)
  require('setup/nvim_treesitter')(use)
  require('setup/telescope')(use)
  require('setup/trouble')(use)
  require('setup/todo_comments')(use)
  require('setup/zen_mode')(use)
  require('setup/fidget')(use)
  require('setup/toggleterm')(use)
  require('setup/neovim_session_manager')(use)
  require('setup/actions_preview')(use)

  -- languages
  use 'rust-lang/rust.vim'

  -- color schemes
  use 'sainnhe/everforest'
  use 'w0ng/vim-hybrid'
  use 'AlessandroYorba/Alduin'
  use 'AlessandroYorba/Sierra'
  use 'frenzyexists/aquarium-vim'
  use 'kvrohit/rasmus.nvim'
  use 'bcicen/vim-vice'
  use 'rafamadriz/neon'
  use 'sainnhe/sonokai'
  use 'savq/melange'
  use 'fenetikm/falcon'
  use 'shaunsingh/nord.nvim'
  use 'kdheepak/monochrome.nvim'
  use 'rose-pine/neovim'
  use 'yazeed1s/oh-lucy.nvim'
  use {
    'ramojus/mellifluous.nvim',
    requires = {'rktjmp/lush.nvim'}
  }

  -- packer setup
  if packer_bootstrap then
    packer.sync()
  end
end)

