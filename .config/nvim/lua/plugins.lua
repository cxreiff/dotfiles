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

  use 'nvim-lualine/lualine.nvim'
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
    }
  }
  
	-- lsp setup
  use 'neovim/nvim-lspconfig'
  use 'williamboman/mason.nvim'    
  use 'williamboman/mason-lspconfig.nvim'

  -- languages
  use 'rust-lang/rust.vim'
  use 'simrat39/rust-tools.nvim'
	
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

