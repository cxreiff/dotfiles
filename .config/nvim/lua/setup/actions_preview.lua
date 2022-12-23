return function(use)
  use {
    'aznhe21/actions-preview.nvim',
    config = function()
      require('actions-preview').setup {
        telescope = {},
      }
      vim.keymap.set(
        {'n', 'v'},
        '<leader>a',
        require("actions-preview").code_actions,
        { noremap = true, silent = true }
      )
    end,
  }
end

