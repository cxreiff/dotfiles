return function()
  require('bufferline').setup {
    options = {
      diagnostics = 'nvim_lsp',
      always_show_bufferline = false,
      show_close_icon = false,
      show_buffer_close_icons = false,
      custom_filter = function(buf)
        if vim.bo[buf].filetype == 'qf' then return false end
        if vim.bo[buf].filetype == 'oil' then return false end
        return true
      end,
    },
  }
end
