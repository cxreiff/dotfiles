return function(use)
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
end
