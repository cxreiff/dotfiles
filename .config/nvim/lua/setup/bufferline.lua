return function(use)
  use {
    'akinsho/bufferline.nvim',
    tag = 'v3.*',
    config = function()
      require('bufferline').setup {
        options = {
          close_icon = 'x',
          buffer_close_icon = 'x',
          diagnostics = 'nvim_lsp',
          show_buffer_icons = false,
          always_show_bufferline = false,
        },
      }
    end,
  }
end
