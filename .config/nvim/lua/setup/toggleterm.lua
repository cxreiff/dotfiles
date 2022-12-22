return function(use)
  use {
    'akinsho/toggleterm.nvim',
    config = function()
      require('toggleterm').setup {
        open_mapping = [[<C-t>]],
        direction = 'float',
      }
    end,
  }
end
