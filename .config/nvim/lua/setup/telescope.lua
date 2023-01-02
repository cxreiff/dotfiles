return function(use)
  use {
    'nvim-telescope/telescope.nvim', tag = '0.1.0',
    requires = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-fzf-native.nvim', run = 'make' },
      { 'nvim-telescope/telescope-ui-select.nvim' },
      { 'tknightz/telescope-termfinder.nvim' },
    },
    config = function()
      local telescope = require('telescope')
      local actions = require('telescope.actions')
      telescope.setup {
        defaults = {
          mappings = {
            i = {
              ["<ESC>"] = actions.close,
            },
          },
        },
      }
      telescope.load_extension('fzf')
      telescope.load_extension('ui-select')
      telescope.load_extension('termfinder')
    end,
  }
end
