return function()
  require('bufferline').setup {
    options = {
      mode = 'tabs',
      close_icon = 'x',
      buffer_close_icon = 'x',
      left_trunc_marker = '<..',
      right_trunc_marker = '..>',
      diagnostics = 'nvim_lsp',
      show_buffer_icons = false,
      always_show_bufferline = false,
    },
  }
end
