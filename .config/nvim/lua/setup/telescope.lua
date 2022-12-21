return function(use)
  use {
    'nvim-telescope/telescope.nvim', tag = '0.1.0',
    requires = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' },
      { 'nvim-telescope/telescope-ui-select.nvim' }
    },
    config = function()
      local telescope = require('telescope')
      require('telescope.themes').get_cursor()
      telescope.load_extension('fzf')
      telescope.load_extension('ui-select')
    end,
  }
end
